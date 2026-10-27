#!/usr/bin/env python3
"""Day-1 Turkish check for small local controller models (llama.cpp llama-server).

For each model this script:
  1. starts llama-server on a local port (Metal, all layers on GPU, one slot),
  2. runs the 20 controller items from items.json twice: once constrained by
     action_schema.json (response_format json_schema) and once unconstrained
     (free text; the first JSON object in the reply is parsed),
     for each system-prompt variant (v1 = original; v2/v3 = post-hoc variants),
     plus a "forced" diagnostic pass (reply constrained to the expected action's
     schema branch, so only the query / ids are scored),
  3. runs the 5 free-text Turkish comprehension probes,
  4. records latency, llama-server timings, load time and peak RSS,
  5. stops the server.

Stdlib only. Run with:
    /opt/homebrew/bin/python3 -I benchmarks/agent/tr_check/run_tr_check.py
    /opt/homebrew/bin/python3 -I benchmarks/agent/tr_check/run_tr_check.py --models qwen35_2b

Models must already be in the Hugging Face cache, e.g.:
    hf download unsloth/Qwen3.5-2B-GGUF Qwen3.5-2B-Q8_0.gguf
    hf download ggml-org/gemma-3-1b-it-GGUF gemma-3-1b-it-Q8_0.gguf

Raw outputs go to benchmarks/agent/work/tr_check/ (git-ignored).
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DEFAULT_OUT = os.path.join(REPO, "benchmarks", "agent", "work", "tr_check")
HF_HUB = os.path.expanduser(os.environ.get("HF_HUB_CACHE", "~/.cache/huggingface/hub"))

MODELS = {
    "qwen35_2b": {
        "label": "Qwen3.5-2B Q8_0",
        "repo": "unsloth/Qwen3.5-2B-GGUF",
        "file": "Qwen3.5-2B-Q8_0.gguf",
        # Qwen3.5-2B is non-thinking by default; we also force it off explicitly.
        # The template then renders an empty <think>\n\n</think> block.
        "chat_template_kwargs": {"enable_thinking": False},
    },
    "gemma3_1b": {
        "label": "Gemma-3-1B-it Q8_0",
        "repo": "ggml-org/gemma-3-1b-it-GGUF",
        "file": "gemma-3-1b-it-Q8_0.gguf",
        "chat_template_kwargs": {},
    },
}

SYSTEM_PROMPT = """You are the controller of a memory-research agent. The agent searches a user's past chat messages (mostly Turkish, sometimes mixed with English) to collect the evidence needed to answer the user's question.

Each turn you receive: the user's question, the evidence retrieved so far (messages with id, date and text), the searches already made, and the remaining step budget. You output exactly ONE action as ONE JSON object, nothing else:
{"action":"search","query":"<text>"}      search past messages; write the query in the language of the messages and name the key entity
{"action":"expand","source":"<message id>"}   fetch the neighbouring messages of that message (use when a message is cut off or depends on context)
{"action":"select","ids":["<message id>", ...]}   put exactly these messages into the evidence pack
{"action":"stop"}   finish

Rules:
1. Evidence is empty -> search for the key entity of the question.
2. The evidence answers only part of the question (for example it names a person but not where that person lives) -> search for the missing fact, naming the newly learned entity.
3. The evidence answers the question but also contains unrelated or outdated messages -> select only the ids of the messages that answer it. When a fact changed over time, choose the most recent message.
4. Every evidence message is relevant and together they fully answer the question -> stop (they are kept automatically).
Never invent message ids. Output only the JSON object."""

# v2 was written AFTER seeing v1 results (Qwen3.5-2B chose `expand` for every
# non-empty evidence list). Same contract and rules; it only restricts `expand`
# and states that the first matching rule wins. Treat v2 numbers as post-hoc.
SYSTEM_PROMPT_V2 = SYSTEM_PROMPT.replace(
    "Rules:\n",
    "Rules (apply the FIRST rule that matches):\n",
).replace(
    "Never invent message ids.",
    "5. Use expand ONLY when a message is visibly cut off (for example it ends with \"...\") "
    "or cannot be understood without its neighbours. A complete, self-contained message is never expanded.\n"
    "Never invent message ids.",
)

# v3 (also post-hoc): v2 with the action menu re-ordered so expand is listed last,
# to test whether Qwen's expand preference is a menu-position artifact.
_MENU = [l for l in SYSTEM_PROMPT_V2.splitlines() if l.startswith('{"action"')]
SYSTEM_PROMPT_V3 = SYSTEM_PROMPT_V2.replace("\n".join(_MENU), "\n".join([_MENU[2], _MENU[3], _MENU[0], _MENU[1]]))
assert SYSTEM_PROMPT_V3 != SYSTEM_PROMPT_V2

PROMPTS = {"v1": SYSTEM_PROMPT, "v2": SYSTEM_PROMPT_V2, "v3": SYSTEM_PROMPT_V3}


# ----------------------------------------------------------------------------
# Turkish-aware folding and checks
# ----------------------------------------------------------------------------

_FOLD = str.maketrans({"ı": "i", "ğ": "g", "ü": "u", "ş": "s", "ö": "o", "ç": "c", "â": "a", "î": "i", "û": "u"})


def tr_fold(text: str) -> str:
    """Lowercase with Turkish dotted/dotless I rules, then strip diacritics."""
    text = text.replace("İ", "i").replace("I", "ı").lower()
    text = text.translate(_FOLD)
    text = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in text if not unicodedata.combining(ch))


def first_json_object(text: str):
    """Return the first JSON object embedded in text, or None."""
    dec = json.JSONDecoder()
    for m in re.finditer(r"\{", text):
        try:
            obj, _ = dec.raw_decode(text, m.start())
        except ValueError:
            continue
        if isinstance(obj, dict):
            return obj
    return None


def validate_action(obj) -> str | None:
    """Validate against action_schema.json by hand (stdlib only). Returns error or None."""
    if not isinstance(obj, dict):
        return "not an object"
    act = obj.get("action")
    allowed = {"search": {"action", "query"}, "expand": {"action", "source"},
               "select": {"action", "ids"}, "stop": {"action"}}
    if act not in allowed:
        return f"unknown action {act!r}"
    if set(obj) != allowed[act]:
        return f"keys {sorted(obj)} != {sorted(allowed[act])}"
    if act == "search" and not (isinstance(obj["query"], str) and 1 <= len(obj["query"]) <= 200):
        return "bad query"
    if act == "expand" and not (isinstance(obj["source"], str) and 1 <= len(obj["source"]) <= 64):
        return "bad source"
    if act == "select":
        ids = obj["ids"]
        if not (isinstance(ids, list) and 1 <= len(ids) <= 8 and all(isinstance(i, str) and i for i in ids)):
            return "bad ids"
    return None


def score_action(item: dict, obj) -> dict:
    """Programmatic check of one controller action. Returns dict with correct / lenient flags."""
    exp = item["expect"]
    res = {"correct": False, "lenient": False, "why": ""}
    if obj is None or validate_action(obj) is not None:
        res["why"] = "invalid"
        return res
    act = obj["action"]
    if exp["action"] == "search":
        if act != "search":
            res["why"] = f"expected search, got {act}"
            return res
        q = tr_fold(obj["query"])
        hit = any(tr_fold(k) in q for k in exp["query_contains_any"])
        res["correct"] = res["lenient"] = hit
        res["why"] = "" if hit else "query lacks key entity"
        return res
    if exp["action"] == "select":
        if act != "select":
            res["why"] = f"expected select, got {act}"
            return res
        got, gold = set(obj["ids"]), set(exp["ids"])
        stale = set(exp.get("stale_ids", []))
        res["correct"] = got == gold
        # Lenient: all gold ids present and no stale (superseded) value selected.
        res["lenient"] = gold <= got and not (got & stale)
        if not res["correct"]:
            res["why"] = f"ids {sorted(got)} vs gold {sorted(gold)}"
        return res
    if exp["action"] == "stop":
        # Strict: stop. Lenient: stop, or select of exactly the gold ids (a
        # select-then-stop controller would end with the right pack).
        res["correct"] = act == "stop"
        res["lenient"] = act == "stop" or (act == "select" and set(obj["ids"]) == set(exp["ids"]))
        if not res["correct"]:
            res["why"] = f"expected stop, got {act}"
        return res
    raise ValueError(exp)


def target_hits_gold(item: dict, obj) -> bool | None:
    """Diagnostic for select items: did the model point at a gold id (via select OR expand)
    without pointing at the stale value? Shows whether it found the right message even
    when it picked the wrong verb. None for other item types / no id-bearing action."""
    if item["type"] != "select" or not isinstance(obj, dict):
        return None
    if obj.get("action") == "select" and isinstance(obj.get("ids"), list):
        ids = set(map(str, obj["ids"]))
    elif obj.get("action") == "expand":
        ids = {str(obj.get("source"))}
    else:
        return None
    gold, stale = set(item["expect"]["ids"]), set(item["expect"].get("stale_ids", []))
    return bool(ids & gold) and not (ids & stale)


def score_probe(probe: dict, text: str) -> bool:
    t = tr_fold(text)
    ok = all(any(tr_fold(alt) in t for alt in group) for group in probe["must_all"])
    return ok and not any(tr_fold(bad) in t for bad in probe["must_not"])


def render_state(item: dict) -> str:
    ev = item["evidence"]
    ev_lines = "\n".join(f'- id={e["id"]} date={e["date"]} text="{e["text"]}"' for e in ev) or "(none)"
    ps = "\n".join(f"- {s}" for s in item["previous_searches"]) or "(none)"
    return (f"Question: {item['question']}\n\n"
            f"Evidence so far:\n{ev_lines}\n\n"
            f"Previous searches:\n{ps}\n\n"
            f"Remaining budget: {item['budget']} steps\n\n"
            "Next action (one JSON object):")


# ----------------------------------------------------------------------------
# llama-server process handling
# ----------------------------------------------------------------------------

def resolve_model(spec: dict) -> str:
    org, name = spec["repo"].split("/")
    pat = os.path.join(HF_HUB, f"models--{org}--{name}", "snapshots", "*", spec["file"])
    hits = sorted(glob.glob(pat))
    if not hits:
        sys.exit(f"model not in HF cache: {spec['repo']} {spec['file']}\n"
                 f"  run: hf download {spec['repo']} {spec['file']}")
    return hits[-1]


class RssSampler(threading.Thread):
    def __init__(self, pid: int, every: float = 0.2):
        super().__init__(daemon=True)
        self.pid, self.every, self.peak_kb, self._stop = pid, every, 0, threading.Event()

    def run(self):
        while not self._stop.is_set():
            try:
                out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.pid)],
                                     capture_output=True, text=True, timeout=5).stdout.strip()
                if out:
                    self.peak_kb = max(self.peak_kb, int(out))
            except (subprocess.SubprocessError, ValueError):
                pass
            self._stop.wait(self.every)

    def stop(self):
        self._stop.set()


def phys_footprint_mb(pid: int) -> float | None:
    """macOS `footprint` (dirty memory; excludes clean mmapped weights). Best effort."""
    try:
        out = subprocess.run(["/usr/bin/footprint", "-p", str(pid)], capture_output=True,
                             text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", out)
    if not m:
        return None
    return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]


def http_json(url: str, payload: dict | None = None, timeout: float = 300):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def start_server(args, model_path: str, log_path: str):
    cmd = [args.server_bin, "-m", model_path, "--host", "127.0.0.1", "--port", str(args.port),
           "-ngl", "99", "-c", str(args.ctx), "-np", "1", "--jinja", "--reasoning", "off",
           "--seed", "0", "--no-webui"]
    log = open(log_path, "w")
    t0 = time.monotonic()
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{args.port}"
    while True:
        if proc.poll() is not None:
            sys.exit(f"llama-server exited early (code {proc.returncode}); see {log_path}")
        try:
            if http_json(base + "/health", timeout=2).get("status") == "ok":
                break
        except (urllib.error.URLError, ConnectionError, TimeoutError, json.JSONDecodeError):
            pass
        if time.monotonic() - t0 > 300:
            proc.kill()
            sys.exit("llama-server did not become healthy in 300 s")
        time.sleep(0.1)
    return proc, base, time.monotonic() - t0, cmd


def stop_server(proc):
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def chat(base: str, spec: dict, messages: list, max_tokens: int, schema: dict | None):
    payload = {"messages": messages, "temperature": 0, "top_k": 1, "seed": 0,
               "max_tokens": max_tokens, "cache_prompt": False}
    if spec["chat_template_kwargs"]:
        payload["chat_template_kwargs"] = spec["chat_template_kwargs"]
    if schema is not None:
        payload["response_format"] = {"type": "json_schema",
                                      "json_schema": {"name": "controller_action", "schema": schema}}
    t0 = time.monotonic()
    try:
        resp = http_json(base + "/v1/chat/completions", payload)
        err = None
    except urllib.error.HTTPError as e:
        resp, err = {}, f"HTTP {e.code}: {e.read().decode()[:300]}"
    latency = time.monotonic() - t0
    msg = (resp.get("choices") or [{}])[0].get("message", {})
    return {"content": msg.get("content") or "", "reasoning": msg.get("reasoning_content"),
            "finish": (resp.get("choices") or [{}])[0].get("finish_reason"),
            "timings": resp.get("timings", {}), "latency_s": latency, "error": err}


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

def forced_branch(schema: dict, action: str) -> dict:
    for br in schema["oneOf"]:
        if br["properties"]["action"]["const"] == action:
            return br
    raise KeyError(action)


def run_model(key: str, args, items: dict, schema: dict) -> dict:
    spec = MODELS[key]
    path = resolve_model(spec)
    os.makedirs(args.out, exist_ok=True)
    proc, base, load_s, cmd = start_server(args, path, os.path.join(args.out, f"{key}.server.log"))
    sampler = RssSampler(proc.pid)
    sampler.start()
    rows = []
    try:
        # Warm-up (not timed / scored).
        chat(base, spec, [{"role": "user", "content": "Merhaba!"}], 8, None)
        runs = [(v, c) for v in args.prompts for c in ("schema", "free")]
        # Diagnostic: "forced" constrains the reply to the schema branch of the EXPECTED
        # action, so only the argument (query / ids) is up to the model. It separates verb
        # policy (cheap to fine-tune) from Turkish understanding of the evidence.
        runs.append((args.prompts[0], "forced"))
        for variant, constraint in runs:
            mode = f"{variant}/{constraint}"
            for it in items["action_items"]:
                if constraint == "forced" and it["type"] == "stop":
                    continue  # forcing {"action":"stop"} is trivially correct
                msgs = [{"role": "system", "content": PROMPTS[variant]},
                        {"role": "user", "content": render_state(it)}]
                sch = {"schema": schema, "free": None,
                       "forced": forced_branch(schema, it["expect"]["action"])}[constraint]
                r = chat(base, spec, msgs, args.max_tokens, sch)
                try:
                    whole = json.loads(r["content"])
                except ValueError:
                    whole = None
                # "clean": the entire reply is one schema-valid JSON object (no prose, no fences).
                clean = isinstance(whole, dict) and validate_action(whole) is None
                obj = whole if isinstance(whole, dict) else first_json_object(r["content"])
                verr = validate_action(obj) if obj is not None else "no JSON object"
                sc = score_action(it, obj)
                rows.append({"model": key, "kind": "action", "mode": mode, "id": it["id"],
                             "type": it["type"], "output": r["content"], "parsed": obj,
                             "valid": verr is None, "clean": clean, "validation_error": verr, **sc,
                             "target_gold": target_hits_gold(it, obj),
                             "latency_s": r["latency_s"], "timings": r["timings"],
                             "finish": r["finish"], "error": r["error"],
                             "reasoning": r["reasoning"]})
                print(f"[{key}] {mode:9s} {it['id']:10s} valid={verr is None!s:5s} "
                      f"ok={sc['correct']!s:5s} {r['content'][:90]!r}", flush=True)
        for pr in items["probes"]:
            r = chat(base, spec, [{"role": "user", "content": pr["prompt"]}], 80, None)
            ok = score_probe(pr, r["content"])
            rows.append({"model": key, "kind": "probe", "mode": "free", "id": pr["id"],
                         "type": "probe", "output": r["content"], "correct": ok,
                         "latency_s": r["latency_s"], "timings": r["timings"],
                         "finish": r["finish"], "error": r["error"]})
            print(f"[{key}] probe  {pr['id']:10s} ok={ok!s:5s} {r['content'][:90]!r}", flush=True)
        footprint = phys_footprint_mb(proc.pid)
    finally:
        sampler.stop()
        stop_server(proc)
    return {"model": key, "label": spec["label"], "repo": spec["repo"], "file": spec["file"],
            "path": path, "size_bytes": os.path.getsize(path), "server_cmd": cmd,
            "load_s": load_s, "peak_rss_mb": sampler.peak_kb / 1024,
            "footprint_end_mb": footprint, "rows": rows}


def summarize(res: dict) -> dict:
    out = {"model": res["model"], "label": res["label"], "load_s": round(res["load_s"], 2),
           "peak_rss_mb": round(res["peak_rss_mb"]),
           "footprint_end_mb": None if res["footprint_end_mb"] is None else round(res["footprint_end_mb"]),
           "modes": {}}
    modes = list(dict.fromkeys(r["mode"] for r in res["rows"] if r["kind"] == "action"))
    for mode in modes:
        rs = [r for r in res["rows"] if r["kind"] == "action" and r["mode"] == mode]
        by_type = {}
        for t in ("first_step", "select", "second_hop", "stop"):
            tr = [r for r in rs if r["type"] == t]
            by_type[t] = {"n": len(tr), "correct": sum(r["correct"] for r in tr),
                          "lenient": sum(r["lenient"] for r in tr)}
        pn = sum(r["timings"].get("predicted_n", 0) for r in rs)
        pms = sum(r["timings"].get("predicted_ms", 0) for r in rs)
        en = sum(r["timings"].get("prompt_n", 0) for r in rs)
        ems = sum(r["timings"].get("prompt_ms", 0) for r in rs)
        out["modes"][mode] = {
            "n": len(rs), "valid": sum(r["valid"] for r in rs), "clean": sum(r["clean"] for r in rs),
            "select_target_gold": sum(bool(r["target_gold"]) for r in rs if r["type"] == "select"),
            "correct": sum(r["correct"] for r in rs), "lenient": sum(r["lenient"] for r in rs),
            "by_type": by_type,
            "mean_latency_s": round(sum(r["latency_s"] for r in rs) / max(len(rs), 1), 3),
            "gen_tok_s": round(pn / pms * 1000, 1) if pms else None,
            "prompt_tok_s": round(en / ems * 1000, 1) if ems else None,
            "mean_gen_tokens": round(pn / max(len(rs), 1), 1),
            "mean_prompt_tokens": round(en / max(len(rs), 1), 1),
        }
    pr = [r for r in res["rows"] if r["kind"] == "probe"]
    out["probes"] = {"n": len(pr), "correct": sum(r["correct"] for r in pr)}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", nargs="+", default=list(MODELS), choices=list(MODELS))
    ap.add_argument("--server-bin", default="/opt/homebrew/bin/llama-server")
    ap.add_argument("--port", type=int, default=8931)
    ap.add_argument("--ctx", type=int, default=4096)
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--prompts", nargs="+", default=list(PROMPTS), choices=list(PROMPTS))
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    with open(os.path.join(HERE, "items.json"), encoding="utf-8") as f:
        items = json.load(f)
    with open(os.path.join(HERE, "action_schema.json"), encoding="utf-8") as f:
        schema = json.load(f)

    summaries = []
    for key in args.models:
        res = run_model(key, args, items, schema)
        with open(os.path.join(args.out, f"{key}.raw.json"), "w", encoding="utf-8") as f:
            json.dump(res, f, ensure_ascii=False, indent=1)
        summaries.append(summarize(res))
    with open(os.path.join(args.out, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summaries, f, ensure_ascii=False, indent=1)

    print("\n| model | prompt/constraint | valid | clean | strict | lenient | first | select | hop | stop | sel. target=gold | probes | lat s | gen tok/s | load s | peak RSS MB |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in summaries:
        for mode, m in s["modes"].items():
            bt = m["by_type"]
            cell = lambda t: f"{bt[t]['correct']}/{bt[t]['n']}"
            print(f"| {s['label']} | {mode} | {m['valid']}/{m['n']} | {m['clean']}/{m['n']} | "
                  f"{m['correct']}/{m['n']} | {m['lenient']}/{m['n']} | {cell('first_step')} | {cell('select')} | "
                  f"{cell('second_hop')} | {cell('stop')} | {m['select_target_gold']}/{bt['select']['n']} | "
                  f"{s['probes']['correct']}/{s['probes']['n']} | "
                  f"{m['mean_latency_s']} | {m['gen_tok_s']} | {s['load_s']} | {s['peak_rss_mb']} |")


if __name__ == "__main__":
    main()
