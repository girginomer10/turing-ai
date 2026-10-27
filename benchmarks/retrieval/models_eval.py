#!/usr/bin/env python3
"""Leaderboard of embedding models and fusions on XQuAD (work/results.models.json from RetrievalBench).

DEV half = even paragraphs (selection), TEST half = odd paragraphs (reported). Paragraph-cluster bootstrap, B = 10,000.
Output: work/models.md
"""
import json, os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
RNG = np.random.default_rng(20261028)
B = 10_000
res = json.load(open(os.path.join(WORK, "results.models.json")))
gold = np.array([q["gold"] for q in json.load(open(os.path.join(WORK, "dataset.json")))["questions"]])
settings = list(res["settings"])
configs = list(res["settings"][settings[0]]["ranks"])
singles = res["models"]
dev, test = gold % 2 == 0, gold % 2 == 1
rr = lambda r: np.where(np.asarray(r) > 0, 1.0 / np.maximum(np.asarray(r), 1), 0.0)
mrr = lambda c, s, mask: rr(res["settings"][s]["ranks"][c])[mask].mean()
macro = lambda c, mask: float(np.mean([mrr(c, s, mask) for s in settings]))
cross = lambda c, mask: float(np.mean([mrr(c, s, mask) for s in ("tr->en", "en->tr")]))


def pooled(c, mask):  # per-query mean over settings, clustered by gold paragraph
    return np.mean([rr(res["settings"][s]["ranks"][c]) for s in settings], axis=0)[mask]


def ci(values, clusters):
    ids, inv = np.unique(clusters, return_inverse=True)
    sums = np.bincount(inv, weights=values); cnt = np.bincount(inv).astype(float)
    idx = RNG.integers(0, len(ids), size=(B, len(ids)))
    return np.percentile(sums[idx].sum(1) / cnt[idx].sum(1), [2.5, 97.5])


def paired(a, b, clusters):
    d = a - b
    ids, inv = np.unique(clusters, return_inverse=True)
    sums = np.bincount(inv, weights=d); cnt = np.bincount(inv).astype(float)
    idx = RNG.integers(0, len(ids), size=(B, len(ids)))
    m = sums[idx].sum(1) / cnt[idx].sum(1)
    signs = RNG.choice([-1.0, 1.0], size=(B, len(ids)))
    p = (np.sum(np.abs((signs * sums).sum(1) / cnt.sum()) >= abs(d.mean()) - 1e-15) + 1) / (B + 1)
    return d.mean(), np.percentile(m, [2.5, 97.5]), p


L = ["# XQuAD: embedding models and fusions (real retriever)\n",
     f"{len(gold)} questions x {len(settings)} settings (tr/en monolingual, cross-lingual, bilingual store). TEST = odd paragraphs "
     f"({int(test.sum())} questions per setting); selection on DEV only. Paragraph-cluster bootstrap.\n",
     "| config | macro-MRR@10 TEST [95% CI] | cross-lingual MRR (tr→en, en→tr) | worst setting |\n|---|---|---|---|"]
order = sorted(configs, key=lambda c: -macro(c, test))
for c in order:
    lo, hi = ci(pooled(c, test), gold[test])
    worst = min(mrr(c, s, test) for s in settings)
    L.append(f"| {c} | {macro(c, test):.3f} [{lo:.3f}, {hi:.3f}] | {cross(c, test):.3f} | {worst:.3f} |")
fus = [c for c in configs if c not in singles and c != "local-only"]
bs = max(singles, key=lambda c: macro(c, dev)); bf = max(fus, key=lambda c: macro(c, dev)) if fus else None
L.append(f"\nSelected on DEV: best single **{bs}**" + (f", best fusion **{bf}**." if bf else "."))
if bf:
    d, c2, p = paired(pooled(bf, test), pooled(bs, test), gold[test])
    L.append(f"TEST, fusion minus best single: ΔMRR@10 {d:+.3f} [{c2[0]:+.3f}, {c2[1]:+.3f}], p = {p:.4f}.")
open(os.path.join(WORK, "models.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
