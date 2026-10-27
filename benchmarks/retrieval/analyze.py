#!/usr/bin/env python3
"""Turn work/results.json (per-query first-relevant ranks) into metrics, CIs and paired tests.

Metrics (one relevant paragraph per query): MRR@10, Recall@k (hit rate), nDCG@10.
Questions that share a gold paragraph are correlated, so every interval and test resamples
*paragraph clusters* (10,000 bootstrap resamples; sign-flip permutation per cluster for p-values).

Protocol: configuration selection uses a DEV half (queries whose gold paragraph index is even);
all headline numbers are reported on the held-out TEST half (odd paragraphs), so choosing the best
configuration cannot inflate the reported score.
Output: work/results.md and work/summary.json
"""
import json, os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
RNG = np.random.default_rng(20261023)
B = 10_000

res = json.load(open(os.path.join(WORK, "results.json")))
gold = np.array([q["gold"] for q in json.load(open(os.path.join(WORK, "dataset.json")))["questions"]])
models = res["models"]
n = res["n_queries"]
settings = list(res["settings"].keys())
configs = list(res["settings"][settings[0]]["ranks"].keys())
EQUAL_ALL = "+".join(models)
LOCAL = "local-only"


def rr(r):
    r = np.asarray(r, dtype=float)
    return np.where(r > 0, 1.0 / np.maximum(r, 1), 0.0)


def ndcg(r):
    r = np.asarray(r, dtype=float)
    return np.where(r > 0, 1.0 / np.log2(np.maximum(r, 1) + 1), 0.0)


def hit(r, k):
    r = np.asarray(r)
    return ((r > 0) & (r <= k)).astype(float)


def cluster_stats(values, clusters):
    """Per-cluster (sum, count) arrays so a cluster bootstrap is a cheap weighted resample."""
    ids, inverse = np.unique(clusters, return_inverse=True)
    sums = np.bincount(inverse, weights=values, minlength=len(ids))
    counts = np.bincount(inverse, minlength=len(ids)).astype(float)
    return sums, counts


def boot_ci(values, clusters):
    sums, counts = cluster_stats(values, clusters)
    k = len(sums)
    idx = RNG.integers(0, k, size=(B, k))
    means = sums[idx].sum(axis=1) / counts[idx].sum(axis=1)
    return np.percentile(means, [2.5, 97.5])


def paired(a, b, clusters):
    """Mean(a-b), 95% cluster-bootstrap CI, two-sided cluster sign-flip permutation p."""
    d = a - b
    sums, counts = cluster_stats(d, clusters)
    k = len(sums)
    idx = RNG.integers(0, k, size=(B, k))
    ci = np.percentile(sums[idx].sum(axis=1) / counts[idx].sum(axis=1), [2.5, 97.5])
    signs = RNG.choice([-1.0, 1.0], size=(B, k))
    perm = np.abs((signs * sums).sum(axis=1) / counts.sum())
    p = (np.sum(perm >= abs(d.mean()) - 1e-15) + 1) / (B + 1)
    return d.mean(), ci, p


dev = gold % 2 == 0
test = ~dev
fmt = lambda x: f"{x:.3f}"
summary = {"n_queries": n, "models": models, "dev_queries": int(dev.sum()), "test_queries": int(test.sum())}
L = []
L.append("# Retrieval benchmark results\n")
L.append(f"XQuAD, {n} parallel Turkish/English questions over 240 Wikipedia paragraphs per language. "
         f"Retriever = the app's real `HybridMemoryRetriever` (local BM25 + hash + concept scoring, "
         f"reciprocal-rank fusion with k = 60, per-profile weights, relevance gates). "
         f"Cluster bootstrap B = {B} over gold paragraphs.\n")


def mrr_of(cfg, s, mask):
    return rr(res["settings"][s]["ranks"][cfg])[mask].mean()


# ---------- 1. Selection on DEV ----------
macro_dev = {c: float(np.mean([mrr_of(c, s, dev) for s in settings])) for c in configs}
singles = list(models)
sel_single = max(singles, key=lambda c: macro_dev[c])
fusions = [c for c in configs if c not in singles and c != LOCAL]
sel_fusion = max(fusions, key=lambda c: macro_dev[c])
summary["selection"] = {"macro_mrr_dev": macro_dev, "best_single": sel_single, "best_fusion": sel_fusion}
L.append("## 1. Configuration selection (DEV half: even-indexed paragraphs)\n")
L.append("| config | macro-MRR@10 (DEV) |\n|---|---|")
for c in sorted(configs, key=lambda c: -macro_dev[c]):
    tag = " ← best single" if c == sel_single else (" ← best fusion" if c == sel_fusion else "")
    L.append(f"| {c} | {fmt(macro_dev[c])}{tag} |")

# ---------- 2. Held-out TEST per setting ----------
L.append(f"\n## 2. Held-out TEST half ({int(test.sum())} questions per setting)\n")
shown = [LOCAL, sel_single, EQUAL_ALL, sel_fusion]
shown = list(dict.fromkeys(shown))
summary["test"] = {}
for s in settings:
    ranks = res["settings"][s]["ranks"]
    L.append(f"\n### {s}  ({res['settings'][s]['documents']} candidates)\n")
    L.append("| config | MRR@10 [95% CI] | R@1 | R@5 | R@10 | nDCG@10 |\n|---|---|---|---|---|---|")
    summary["test"][s] = {}
    for c in shown:
        r = np.asarray(ranks[c])[test]
        x = rr(r)
        lo, hi = boot_ci(x, gold[test])
        row = dict(mrr=x.mean(), ci=[lo, hi], r1=hit(r, 1).mean(), r5=hit(r, 5).mean(), r10=hit(r, 10).mean(), ndcg10=ndcg(r).mean())
        summary["test"][s][c] = row
        L.append(f"| {c} | {fmt(row['mrr'])} [{fmt(lo)}, {fmt(hi)}] | {fmt(row['r1'])} | {fmt(row['r5'])} | {fmt(row['r10'])} | {fmt(row['ndcg10'])} |")
    comp = {}
    L.append("\n| paired comparison (ΔMRR@10) | Δ [95% CI] | p |\n|---|---|---|")
    for a_cfg, b_cfg in [(sel_fusion, sel_single), (sel_fusion, LOCAL), (EQUAL_ALL, sel_single), (EQUAL_ALL, sel_fusion)]:
        if a_cfg == b_cfg:
            continue
        d, ci, p = paired(rr(ranks[a_cfg])[test], rr(ranks[b_cfg])[test], gold[test])
        comp[f"{a_cfg} vs {b_cfg}"] = dict(delta=d, ci=list(ci), p=p)
        L.append(f"| {a_cfg} vs {b_cfg} | {d:+.3f} [{ci[0]:+.3f}, {ci[1]:+.3f}] | {p:.4f} |")
    summary["test"][s]["_comparisons"] = comp

# ---------- 3. Aggregate on TEST ----------
L.append("\n## 3. Aggregate over the six settings (TEST)\n")
L.append("| config | macro-MRR@10 | worst-setting MRR@10 | macro-R@1 |\n|---|---|---|---|")
agg = {}
for c in configs:
    per = [mrr_of(c, s, test) for s in settings]
    r1 = [hit(np.asarray(res["settings"][s]["ranks"][c])[test], 1).mean() for s in settings]
    agg[c] = dict(macro_mrr=float(np.mean(per)), worst_mrr=float(np.min(per)), macro_r1=float(np.mean(r1)))
for c in sorted(configs, key=lambda c: -agg[c]["macro_mrr"]):
    mark = " ◀ selected on DEV" if c in (sel_single, sel_fusion) else ""
    L.append(f"| {c}{mark} | {fmt(agg[c]['macro_mrr'])} | {fmt(agg[c]['worst_mrr'])} | {fmt(agg[c]['macro_r1'])} |")
summary["test_aggregate"] = agg

stack = lambda cfg: np.concatenate([rr(res["settings"][s]["ranks"][cfg])[test] for s in settings])
clusters = np.concatenate([gold[test] for _ in settings])
L.append(f"\nPooled over {len(settings)} settings ({len(clusters)} query-setting pairs, {len(np.unique(clusters))} paragraph clusters):\n")
L.append("| comparison | ΔMRR@10 [95% CI] | p |\n|---|---|---|")
summary["pooled"] = {}
for a_cfg, b_cfg in [(sel_fusion, sel_single), (sel_fusion, LOCAL), (sel_single, LOCAL), (EQUAL_ALL, sel_single), (EQUAL_ALL, LOCAL)]:
    d, ci, p = paired(stack(a_cfg), stack(b_cfg), clusters)
    summary["pooled"][f"{a_cfg} vs {b_cfg}"] = dict(delta=d, ci=list(ci), p=p)
    L.append(f"| {a_cfg} vs {b_cfg} | {d:+.3f} [{ci[0]:+.3f}, {ci[1]:+.3f}] | {p:.4f} |")

# Relative error reduction in MRR terms: (1-MRR_a)/(1-MRR_b)
def rel_err_red(a, b):
    return 1 - (1 - agg[a]["macro_mrr"]) / (1 - agg[b]["macro_mrr"])
L.append(f"\nRelative reduction of macro-MRR shortfall (1 - MRR): {sel_fusion} vs {sel_single}: "
         f"{rel_err_red(sel_fusion, sel_single):+.1%}; vs {LOCAL}: {rel_err_red(sel_fusion, LOCAL):+.1%}.")
json.dump(summary, open(os.path.join(WORK, "summary.json"), "w"), indent=1)
open(os.path.join(WORK, "results.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
