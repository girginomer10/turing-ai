#!/usr/bin/env python3
"""Baseline (d): the untrained small model as the controller, prompted, driving the same environment (env.py).

The model (Qwen3.5-2B Q8_0 through llama-server, thinking off, temperature 0) sees the same guidance as the strong
prompted agents (agent_prompt.md), but acts through JSON actions constrained by a schema instead of shell commands.
Each action goes through env.py, so budget rules, logging and cost counting are identical. One harness guard: the
first `stop` with an empty pack is answered with a reminder to select instead of being executed. After 16 model calls
without `stop` the question is stopped with whatever is in the pack.

Run from benchmarks/agent with `retrieval.py serve` running:  python3 -I small_agent.py [--run qwen35_2b_prompted]
"""
import argparse, glob, json, os, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from baselines import RUNS, load_questions  # noqa: E402

PORT = 8093
MODEL_GLOB = os.path.expanduser("~/.cache/huggingface/hub/models--unsloth--Qwen3.5-2B-GGUF/snapshots/*/Qwen3.5-2B-Q8_0.gguf")
ENV = ["/opt/homebrew/bin/python3", "-I", os.path.join(HERE, "env.py")]
MAX_CALLS = 16

SCHEMA = {"oneOf": [
    {"type": "object", "properties": {"action": {"const": "search"}, "query": {"type": "string", "minLength": 1, "maxLength": 200}},
     "required": ["action", "query"], "additionalProperties": False},
    {"type": "object", "properties": {"action": {"const": "expand"}, "source": {"type": "string", "maxLength": 16}},
     "required": ["action", "source"], "additionalProperties": False},
    {"type": "object", "properties": {"action": {"const": "select"},
                                      "ids": {"type": "array", "items": {"type": "string", "maxLength": 16}, "minItems": 1, "maxItems": 8}},
     "required": ["action", "ids"], "additionalProperties": False},
    {"type": "object", "properties": {"action": {"const": "stop"}, "answer": {"type": "string", "maxLength": 200}},
     "required": ["action", "answer"], "additionalProperties": False}]}

SYSTEM = """You are a research assistant working over one person's long chat archive with their AI assistant (Turkish, English
and mixed messages, January 2024 to today, 2026-09-30). For each question, build a small evidence pack: the user
messages another model will need to answer the question correctly. Then give your own short answer.

Reply with exactly one JSON action per turn:
{"action": "search", "query": "<query>"}        top 5 matching user messages: [id] date: text
{"action": "expand", "source": "<message id>"}  the messages around one you have seen (same session)
{"action": "select", "ids": ["<id>", ...]}      add messages you have seen to the pack
{"action": "stop", "answer": "<short answer>"}  final

Budget per question: at most 8 search/expand actions in total, and a pack of at most 8 messages. Selecting is free.
Stop is final.

How to work:
- Queries can be in Turkish or English, whichever fits. Search for names, projects and places rather than whole
  questions, and rephrase when results miss.
- Facts change over time. Messages carry dates, and "now" means today. For a current value, the pack must contain
  the most recent statement, plus anything that shows an older value no longer holds.
- If the question goes through another person or project that it does not name, find that one first, then search
  for it.
- For counts, find every instance (and every message that adds or removes one) before answering.
- Select only messages that are needed. A smaller pack that is complete beats a full pack of near-misses."""


def post(path, payload, timeout=300):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def start_server():
    path = sorted(glob.glob(MODEL_GLOB))[-1]
    proc = subprocess.Popen(["llama-server", "-m", path, "--port", str(PORT), "-c", "16384", "-ngl", "99", "--jinja",
                             "--reasoning", "off", "--parallel", "1", "--log-disable"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(180):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2)
            return proc
        except OSError:
            time.sleep(1)
    proc.terminate()
    sys.exit("llama-server did not start")


def env(run, *args):
    r = subprocess.run(ENV + ["--run", run, *args], capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()


def state_file(run, qid):
    return os.path.join(RUNS, run, "state", f"{qid}.json")


def act(messages):
    d = post("/v1/chat/completions", {"messages": messages, "temperature": 0, "max_tokens": 300,
                                      "chat_template_kwargs": {"enable_thinking": False},
                                      "response_format": {"type": "json_schema", "json_schema": {"name": "action", "schema": SCHEMA}}})
    text = d["choices"][0]["message"]["content"]
    return text, json.loads(text), d.get("usage", {})


def run_question(run, qid):
    obs = env(run, "start", qid)
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": obs}]
    tokens, warned = 0, False
    for _ in range(MAX_CALLS):
        text, a, usage = act(messages)
        tokens += usage.get("prompt_tokens", 0) + usage.get("completion_tokens", 0)
        messages.append({"role": "assistant", "content": text})
        kind = a["action"]
        if kind == "search":
            obs = env(run, "search", qid, a["query"])
        elif kind == "expand":
            obs = env(run, "expand", qid, a["source"])
        elif kind == "select":
            obs = env(run, "select", qid, *a["ids"])
        else:
            if not warned and not json.load(open(state_file(run, qid)))["pack"]:
                # One reminder per question: stopping with an empty pack wastes the research (harness guard).
                warned = True
                obs = "Your evidence pack is empty. Select the messages the answer needs, then stop."
            else:
                env(run, "stop", qid, "--answer", a.get("answer", ""))
                return tokens, False
        messages.append({"role": "user", "content": obs})
    env(run, "stop", qid, "--answer", "")
    return tokens, True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="qwen35_2b_prompted")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    proc = start_server()
    try:
        qs = load_questions()[: args.limit or None]
        t0, cut, tok = time.time(), 0, 0
        for i, q in enumerate(qs):
            st = state_file(args.run, q["id"])
            if os.path.exists(st) and json.load(open(st))["done"]:
                continue
            t, c = run_question(args.run, q["id"])
            tok += t
            cut += c
            if i % 25 == 0:
                print(f"{i + 1}/{len(qs)} {round(time.time() - t0)} s", flush=True)
        print(env(args.run, "finalize"))
        print(f"{len(qs)} questions in {round(time.time() - t0)} s; {cut} hit the call cap; {tok} model tokens")
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
