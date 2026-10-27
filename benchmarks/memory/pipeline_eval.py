#!/usr/bin/env python3
"""Evaluate reranked pipelines run through the real retriever (HybridMemoryRetriever.select) with a score threshold.

Input: work/results.pipeline.json (MemoryBench with MB_PIPELINES). DEV personas choose the threshold tau that maximises
U = P(gold injected | answerable) - P(anything injected | unanswerable); TEST personas confirm.
Output: work/pipeline.md, work/pipeline.json
"""
import json, os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
RNG = np.random.default_rng(20261029)
B = 4000
ds = json.load(open(os.path.join(WORK, "dataset.json")))
queries, personas = ds["queries"], ds["personas"]
persona = np.array([q["persona"] for q in queries]); ans = np.array([q["type"] != "unanswerable" for q in queries])
qtype = np.array([q["type"] for q in queries])
DEV = np.isin(persona, personas[0::2]); TEST = ~DEV
st = json.load(open(os.path.join(WORK, "results.pipeline.json")))["stores"]["per-persona"]
rr = lambda c: np.where(np.array(st[c]["rank"]) > 0, 1 / np.maximum(np.array(st[c]["rank"]), 1), 0.0)
inj = lambda c: np.array(st[c]["injected"], dtype=float)
ret = lambda c: np.array(st[c]["returned"], dtype=float)
FS = "embeddinggemma-300m+arctic-embed-l-v2"


def groups(mask):
    return [np.where(mask & (persona == p))[0] for p in personas if (mask & (persona == p)).any()]


def draws(gs):
    out = []
    for _ in range(B):
        pick = RNG.integers(0, len(gs), size=len(gs))
        out.append(np.concatenate([RNG.choice(gs[k], size=len(gs[k]), replace=True) for k in pick]))
    return out


def ci(v, dr): return np.percentile([v[d].mean() for d in dr], [2.5, 97.5])


A_ALL = groups(ans); A_D = draws(A_ALL); A_I = np.concatenate(A_ALL)
T_ANS = groups(ans & TEST); T_D = draws(T_ANS); T_I = np.concatenate(T_ANS)
U_G = groups(~ans & TEST); U_D = draws(U_G); U_I = np.concatenate(U_G)
cfgs = [c for c in st if ">>" in c]
L = ["# Reranked pipelines through the real retriever\n",
     "First stage: embeddinggemma-300m + arctic-embed-l-v2 (reciprocal-rank fusion), top 20. The reranker's probability picks the "
     "injected items (`HybridMemoryRetriever.select`, default limits: 6 items, 2 per container); candidates below tau are dropped. "
     "`blend:` feeds the reranker through the blended semantic term instead.\n",
     "| pipeline | MRR@10 | R@1 | gold injected (answerable) | anything injected (unanswerable) | mean items (unanswerable) | utility |\n|---|---|---|---|---|---|---|"]
rows = {}
for c in [FS, "local-only"] + sorted(cfgs):
    if c not in st: continue
    u = inj(c)[ans].mean() - (ret(c)[~ans] > 0).mean()
    rows[c] = dict(mrr=rr(c)[A_I].mean(), r1=(np.array(st[c]["rank"]) == 1)[A_I].mean(), inj=inj(c)[A_I].mean(),
                   false=(ret(c)[~ans] > 0).mean(), items=ret(c)[~ans].mean(), u=u)
    r = rows[c]
    L.append(f"| {c} | {r['mrr']:.3f} | {r['r1']:.3f} | {r['inj']:.3f} | {r['false']:.0%} | {r['items']:.1f} | {r['u']:+.3f} |")

L.append("\n## Threshold chosen on DEV personas, confirmed on TEST personas\n")
L.append("| reranker | tau (DEV) | TEST: gold injected, tau = 0 | TEST: gold injected, tau* | TEST: unanswerable injected, tau = 0 | TEST: unanswerable injected, tau* | TEST MRR@10 tau* |\n|---|---|---|---|---|---|---|")
summary = {}
for name in sorted({c.split(">>")[1].split("~")[0] for c in cfgs if not c.startswith("blend:")}):
    family = [c for c in cfgs if not c.startswith("blend:") and c.split(">>")[1].split("~")[0] == name]
    def dev_u(c): return inj(c)[ans & DEV].mean() - (ret(c)[~ans & DEV] > 0).mean()
    best = max(family, key=dev_u)
    base = [c for c in family if c.endswith("~0")][0]
    tau = best.split("~")[1]
    t = lambda c, m, f: f(c)[m].mean()
    L.append(f"| {name.split('@')[0]} | {tau} | {inj(base)[ans & TEST].mean():.3f} | {inj(best)[ans & TEST].mean():.3f} | "
             f"{(ret(base)[~ans & TEST] > 0).mean():.0%} | {(ret(best)[~ans & TEST] > 0).mean():.0%} | {rr(best)[ans & TEST].mean():.3f} |")
    summary[name] = dict(tau=float(tau), best=best)
json.dump(dict(rows=rows, tau=summary), open(os.path.join(WORK, "pipeline.json"), "w"), indent=1, default=float)
open(os.path.join(WORK, "pipeline.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
