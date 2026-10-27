#!/usr/bin/env python3
"""Single-shot retrieval baselines: the raw question goes to the search engine once; the pack is filled to the budget.

  (a) hybrid + rerank top-K: retrieval.Engine (BM25 + EmbeddingGemma, RRF, bge-reranker-v2-m3 on the top 30)
  (b) (a) + neighbour expansion: each hit in rank order brings its same-session user turns within +/-2 turns,
      until the pack holds K messages
Diagnostics (not baselines of record): BM25 only, dense only, hybrid without the reranker, and (a) at depth 20 so
recall-at-depth curves can be drawn. Output: work/runs/<method>/packs.jsonl, one {"qid", "pack", "ranked"} per line.

Run from benchmarks/agent with `retrieval.py serve` running:  python3 -I baselines.py [--budget 8]
"""
import argparse, glob, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import retrieval  # noqa: E402

RUNS = retrieval.work_path("runs")


def load_questions():
    qs = []
    for p in sorted(glob.glob(os.path.join(retrieval.WORLDS, "w*", "questions.jsonl"))):
        qs += [json.loads(l) for l in open(p)]
    return qs


def neighbour_pack(engine, ranked, budget):
    pack = []
    for mid in ranked:
        for x in [mid] + [n["id"] for n in engine.session_neighbours(mid) if n["role"] == "user" and n["id"] != mid]:
            if x not in pack and len(pack) < budget:
                pack.append(x)
        if len(pack) >= budget:
            break
    return pack


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=int, default=8)
    ap.add_argument("--depth", type=int, default=20)
    args = ap.parse_args()
    retrieval.check_servers()
    qs = load_questions()
    engines, engines_nr = {}, {}
    out = {m: [] for m in ("a_hybrid_rerank", "b_neighbours", "diag_bm25", "diag_dense", "diag_hybrid_norerank")}
    t0 = time.time()
    for q in qs:
        w = q["world"]
        if w not in engines:
            engines[w] = retrieval.Engine(w)
            engines_nr[w] = retrieval.Engine(w, use_rerank=False)
        e = engines[w]
        ranked = e.search(q["question"], k=max(args.depth, 40))
        out["a_hybrid_rerank"].append({"qid": q["id"], "pack": ranked[:args.budget], "ranked": ranked[:args.depth]})
        out["b_neighbours"].append({"qid": q["id"], "pack": neighbour_pack(e, ranked, args.budget)})
        lex = e.bm25(q["question"])
        den = e.dense(q["question"])
        for name, sc in (("diag_bm25", lex), ("diag_dense", den)):
            order = [e.ids[i] for i in sorted(range(len(sc)), key=lambda i: -sc[i])[:args.depth]]
            out[name].append({"qid": q["id"], "pack": order[:args.budget], "ranked": order})
        nr = engines_nr[w].search(q["question"], k=args.depth)
        out["diag_hybrid_norerank"].append({"qid": q["id"], "pack": nr[:args.budget], "ranked": nr})
    for m, rows in out.items():
        d = os.path.join(RUNS, m)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "packs.jsonl"), "w") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")
    print(len(qs), "questions,", round(time.time() - t0, 1), "s")


if __name__ == "__main__":
    main()
