#!/usr/bin/env python3
"""Day 3: a downstream answer model reads each method's evidence pack and answers; answers are checked against the
computed answers (score.answer_ok).

The answer model is ChatGPT through `codex exec` (subscription; read-only sandbox in an empty directory, structured
output). Several questions share one call to keep the number of calls down, but never two whose questions or packs
name the same person or project (in any world), so one item's pack cannot answer another. Each call shuffles items
from all methods, so the model cannot tell which method produced a pack.

Packs evaluated: every method in work/runs/<name>/packs.jsonl listed in --methods, plus two references:
`gold_pack` (exactly the gold messages: what the answer model can do with perfect evidence) and `no_pack` (the
question alone: guessing). Messages are shown as "[date] text" without ids.

  python3 -I answer.py build [--methods ...] [--batch 10]   -> work/answers/<model>/batches/*.json
  python3 -I answer.py run [--jobs 5]                       -> work/answers/<model>/out/*.json
  python3 -I answer.py score                                 -> work/answers/<model>/scores.json
"""
import argparse, glob, json, os, random, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from baselines import RUNS, load_questions  # noqa: E402
from env import NOW  # noqa: E402
from retrieval import WORLDS, fold, work_path  # noqa: E402
from score import CLASSES, answer_ok, boot  # noqa: E402

METHODS = ["a_hybrid_rerank", "b_neighbours", "app_hybrid_rerank", "gpt_codex_isolated", "qwen35_2b_prompted_v2"]

PROMPT = f"""You answer questions about one person's life using ONLY the chat messages given with each question. The
messages are things the person wrote to their AI assistant (Turkish, English or mixed), each with its date. Today is
{NOW}; "now" means today. Facts change over time: use the most recent information in the messages.

Each item below is independent: use only that item's own messages, never another item's. If an item's messages do
not contain enough to answer, answer "unknown". Keep answers short: a name, a city, a company, a date, or a number
for "how many" questions. Answer in the language of the question. Do not run commands or read files.

Items (JSON lines):
"""

SCHEMA = {"type": "object", "additionalProperties": False, "required": ["items"],
          "properties": {"items": {"type": "array", "items": {
              "type": "object", "additionalProperties": False, "required": ["id", "answer"],
              "properties": {"id": {"type": "string"}, "answer": {"type": "string"}}}}}}


def out_dir(model):
    return work_path("answers", model)


def entities(world, texts):
    """Person and project names that appear in the texts (full names, first names, project names)."""
    names = set()
    blob = fold(" ".join(texts))
    for p in world["people"]:
        for n in (f"{p['first']} {p['last']}", p["first"]):
            if fold(n) in blob:
                names.add(fold(n))
    for j in world["projects"]:
        if fold(j["name"]) in blob:
            names.add(fold(j["name"]))
    return names


def cmd_build(args):
    qs = {q["id"]: q for q in load_questions()}
    worlds = {w: json.load(open(os.path.join(WORLDS, w, "world.json"))) for w in {q["world"] for q in qs.values()}}
    texts = {}
    for w in worlds:
        for line in open(os.path.join(WORLDS, w, "messages.jsonl")):
            m = json.loads(line)
            texts[(w, m["id"])] = (m["ts"][:10], m["text"])
    packs = {"gold_pack": {q: qs[q]["gold_messages"] for q in qs}, "no_pack": {q: [] for q in qs}}
    for m in args.methods:
        packs[m] = {r["qid"]: r["pack"] for r in map(json.loads, open(os.path.join(RUNS, m, "packs.jsonl")))}
    items = []
    for method, pk in packs.items():
        for qid, pack in pk.items():
            q = qs[qid]
            msgs = [texts[(q["world"], mid)] for mid in sorted(pack, key=lambda m: texts[(q["world"], m)][0])]
            items.append({"id": f"{method}|{qid}", "question": q["question"],
                          "messages": [f"[{d}] {t}" for d, t in msgs],
                          "_ents": sorted(entities(worlds[q["world"]], [q["question"]] + [t for _, t in msgs]))})
    random.Random(7).shuffle(items)
    batches = []
    for it in items:  # first batch with room and no shared entity
        for b in batches:
            if len(b["items"]) < args.batch and not (set(it["_ents"]) & b["ents"]):
                b["items"].append(it)
                b["ents"] |= set(it["_ents"])
                break
        else:
            batches.append({"items": [it], "ents": set(it["_ents"])})
    d = os.path.join(out_dir(args.model), "batches")
    os.makedirs(d, exist_ok=True)
    for i, b in enumerate(batches):
        json.dump([{k: v for k, v in it.items() if k != "_ents"} for it in b["items"]],
                  open(os.path.join(d, f"b{i:04d}.json"), "w"), ensure_ascii=False, indent=1)
    print(len(items), "items in", len(batches), "batches;", sum(len(b["items"]) for b in batches) / len(batches), "per batch")


def run_batch(model, path):
    out = os.path.join(out_dir(model), "out", os.path.basename(path))
    if os.path.exists(out):
        return "skip"
    sandbox = os.path.join(out_dir(model), "sandbox")
    batch = json.load(open(path))
    prompt = PROMPT + "\n".join(json.dumps({"id": b["id"].split("|")[1] + "#" + str(i), "question": b["question"],
                                             "messages": b["messages"]}, ensure_ascii=False) for i, b in enumerate(batch))
    raw = out + ".raw"
    r = subprocess.run(["codex", "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-C", sandbox,
                        "--output-schema", os.path.join(sandbox, "schema.json"), "-o", raw, "-"],
                       input=prompt, text=True, capture_output=True, timeout=1800)
    if r.returncode != 0 or not os.path.exists(raw):
        return f"fail {r.returncode}"
    got = {x["id"]: x["answer"] for x in json.load(open(raw))["items"]}
    # Item ids sent to the model hide the method; map them back by position.
    res = [{"id": b["id"], "answer": got.get(b["id"].split("|")[1] + "#" + str(i))} for i, b in enumerate(batch)]
    json.dump(res, open(out, "w"), ensure_ascii=False, indent=1)
    os.remove(raw)
    return "ok"


def cmd_run(args):
    d = out_dir(args.model)
    os.makedirs(os.path.join(d, "out"), exist_ok=True)
    os.makedirs(os.path.join(d, "sandbox"), exist_ok=True)
    json.dump(SCHEMA, open(os.path.join(d, "sandbox", "schema.json"), "w"))
    paths = sorted(glob.glob(os.path.join(d, "batches", "*.json")))
    with ThreadPoolExecutor(args.jobs) as ex:
        for i, (p, r) in enumerate(zip(paths, ex.map(lambda p: run_batch(args.model, p), paths))):
            if r not in ("ok", "skip"):
                print(os.path.basename(p), r, flush=True)
            if i % 20 == 0:
                print(f"{i + 1}/{len(paths)}", flush=True)


def cmd_score(args):
    qs = {q["id"]: q for q in load_questions()}
    rows = [x for p in glob.glob(os.path.join(out_dir(args.model), "out", "*.json")) for x in json.load(open(p))]
    by = {}
    for x in rows:
        method, qid = x["id"].split("|")
        by.setdefault(method, {})[qid] = answer_ok(qs[qid], x["answer"] or "")
    rng = random.Random(0)
    out = {}
    order = ["no_pack", "gold_pack"] + [m for m in by if m not in ("no_pack", "gold_pack")]
    print(f"answer accuracy ({args.model}); diff vs {args.ref} with 95% bootstrap CI")
    for m in order:
        if m not in by:
            continue
        res = {}
        for cls in CLASSES:
            ids = [q for q in by[m] if qs[q]["class"] == cls]
            acc = [float(by[m][q]) for q in ids]
            r = {"n": len(ids), "acc": round(sum(acc) / len(acc), 3), "ci": boot(acc, rng)}
            if m != args.ref and args.ref in by:
                diffs = [float(by[m][q]) - float(by[args.ref][q]) for q in ids if q in by[args.ref]]
                r["diff"] = round(sum(diffs) / len(diffs), 3)
                r["diff_ci"] = boot(diffs, rng)
            res[cls] = r
        out[m] = res
        print(f"{m:24s} " + "  ".join(f"{c}: {res[c]['acc']:.2f}" + (f" ({res[c]['diff']:+.2f})" if "diff" in res[c] else "")
                                      for c in CLASSES) + f"  [n={sum(res[c]['n'] for c in CLASSES)}]")
    json.dump(out, open(os.path.join(out_dir(args.model), "scores.json"), "w"), indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="chatgpt_codex")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--methods", nargs="*", default=METHODS)
    b.add_argument("--batch", type=int, default=10)
    r = sub.add_parser("run")
    r.add_argument("--jobs", type=int, default=5)
    s = sub.add_parser("score")
    s.add_argument("--ref", default="a_hybrid_rerank")
    args = ap.parse_args()
    {"build": cmd_build, "run": cmd_run, "score": cmd_score}[args.cmd](args)


if __name__ == "__main__":
    main()
