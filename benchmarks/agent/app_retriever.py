#!/usr/bin/env python3
"""Baseline through the app's own HybridMemoryRetriever (Swift, benchmarks/memory/Bench) over the user turns.

Same harness as the personal-memory benchmark: user turns become "message" items (age from their timestamp, one
container per session, one store per world), EmbeddingGemma cosines are the semantic profile, and bge-reranker-v2-m3
rescores the retriever's top 20 (MB_PIPELINES). Writes work/runs/app_hybrid/ and work/runs/app_hybrid_rerank/
packs.jsonl in the format score.py reads.

Run from benchmarks/agent with `retrieval.py serve` running and the harness built
(swift build -c release --package-path ../memory/Bench):  python3 -I app_retriever.py [--budget 8]
"""
import argparse, array, datetime as dt, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import retrieval  # noqa: E402
from baselines import RUNS, load_questions  # noqa: E402
from env import NOW  # noqa: E402

WORK = retrieval.work_path("app_bench")
BENCH = os.path.join(HERE, "..", "memory", "Bench", ".build", "release", "MemoryBench")
EMB, RR = "embeddinggemma-300m", "bge-reranker-v2-m3"


def run_bench(label, env):
    subprocess.run([BENCH, WORK, label], check=True, env={**os.environ, "MB_STORES": "per-persona", "MB_FUSIONS": "",
                                                          "MB_MODELS": EMB, **env})
    return json.load(open(os.path.join(WORK, f"results.{label}.json")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=int, default=8)
    args = ap.parse_args()
    retrieval.check_servers()
    os.makedirs(os.path.join(WORK, "scores"), exist_ok=True)
    os.makedirs(os.path.join(WORK, "rerank"), exist_ok=True)
    now = dt.date.fromisoformat(NOW)
    qs = load_questions()
    worlds = sorted({q["world"] for q in qs})

    items, vecs = [], []
    for w in worlds:
        idx = json.load(open(os.path.join(retrieval.INDEX, f"{w}.json")))
        by_id = {m["id"]: m for m in retrieval.user_turns(w)}
        for mid, v in zip(idx["ids"], idx["vectors"]):
            m = by_id[mid]
            items.append({"id": f"{w}/{mid}", "persona": w, "kind": "message", "text": m["text"],
                          "age_days": (now - dt.date.fromisoformat(m["ts"][:10])).days + 0.5,
                          "container": f"{w}/{m['session']}"})
            vecs.append(v)
    queries = [{"id": q["id"], "persona": q["world"], "type": q["class"], "lang": q["lang"], "text": q["question"],
                "gold": [f"{q['world']}/{g}" for g in q["gold_messages"]]} for q in qs]
    json.dump({"personas": worlds, "items": items, "queries": queries}, open(os.path.join(WORK, "dataset.json"), "w"),
              ensure_ascii=False)

    qv = retrieval.embed([q["question"] for q in qs], retrieval.Q_PREFIX)
    mat = array.array("f")
    for q, v in zip(qs, qv):
        for it, d in zip(items, vecs):
            mat.append(sum(a * b for a, b in zip(v, d)) if it["persona"] == q["world"] else 0.0)
    with open(os.path.join(WORK, "scores", f"{EMB}.f32"), "wb") as fh:
        mat.tofile(fh)
    rr_path = os.path.join(WORK, "rerank", f"{RR}.f32")
    if os.path.exists(rr_path):
        os.remove(rr_path)

    first = run_bench("first", {})["stores"]["per-persona"][EMB]["candidates"]
    # Rerank exactly the retriever's top 20 per query; everything else stays NaN (outside the pipeline).
    nan = float("nan")
    rr = array.array("f", [nan]) * (len(qs) * len(items))
    for qi, (q, cands) in enumerate(zip(qs, first)):
        scores = retrieval.rerank(q["question"], [items[c]["text"] for c in cands])
        for c, s in zip(cands, scores):
            rr[qi * len(items) + c] = s
    with open(rr_path, "wb") as fh:
        rr.tofile(fh)
    second = run_bench("rerank", {"MB_PIPELINES": f"{EMB}>>{RR}~0"})["stores"]["per-persona"][f"{EMB}>>{RR}~0"]["candidates"]

    for name, cand in (("app_hybrid", first), ("app_hybrid_rerank", second)):
        d = os.path.join(RUNS, name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "packs.jsonl"), "w") as fh:
            for q, c in zip(qs, cand):
                ranked = [items[i]["id"].split("/")[1] for i in c]
                fh.write(json.dumps({"qid": q["id"], "pack": ranked[:args.budget], "ranked": ranked}) + "\n")
    print("wrote app_hybrid and app_hybrid_rerank for", len(qs), "questions")


if __name__ == "__main__":
    main()
