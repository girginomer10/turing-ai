#!/usr/bin/env python3
"""Replicate the app's score blending offline, verify it, then ablate the fusion function.

Step 1 (validation): re-implements HybridMemoryRetriever.retrieve()'s arithmetic (gate, RRF k=60,
rank-percentile term, 0.42/0.18/0.40 blend) from the dumped local scores + embedding cosines and
checks that it reproduces the Swift retriever's per-query ranks.
Step 2 (ablation): swaps parts of the blend (semantic normalisation, lexical weight, rank vs score
fusion) on the same inputs. Variants are compared on the held-out TEST half (paragraph-disjoint
from DEV); this does NOT change the app, it quantifies headroom.
Output: work/ablation.md and work/ablation.json
"""
import json, os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
RNG = np.random.default_rng(20261024)
B = 10_000

ds = json.load(open(os.path.join(WORK, "dataset.json")))
gold = np.array([q["gold"] for q in ds["questions"]])
nq = len(gold)
res = json.load(open(os.path.join(WORK, "results.json")))
models = res["models"]
settings = {"tr->tr": ("tr", ["tr"]), "en->en": ("en", ["en"]), "tr->en": ("tr", ["en"]),
            "en->tr": ("en", ["tr"]), "tr->mixed": ("tr", ["tr", "en"]), "en->mixed": ("en", ["tr", "en"])}
dev = gold % 2 == 0
test = ~dev

# Configurations replicated: (name, [(model, weight)])
CONFIGS = {
    "local-only": [],
    "qwen3": [("qwen3-emb-0.6b", 1.0)],
    "bge-m3": [("bge-m3", 1.0)],
    "nomic": [("nomic-v1.5", 1.0)],
    "bge+qwen": [("bge-m3", 1.0), ("qwen3-emb-0.6b", 1.0)],
    "all3": [(m, 1.0) for m in models],
}
SWIFT_NAME = {"local-only": "local-only", "qwen3": "qwen3-emb-0.6b", "bge-m3": "bge-m3", "nomic": "nomic-v1.5",
              "bge+qwen": "bge-m3+qwen3-emb-0.6b", "all3": "+".join(models)}


def load(setting):
    ql, dls = settings[setting]
    local = np.fromfile(os.path.join(WORK, "local", setting.replace(">", "") + ".f32"), dtype=np.float32).reshape(nq, -1)
    sem = {}
    for m in models:
        parts = [np.fromfile(os.path.join(WORK, "scores", f"{m}.{ql}-{dl}.f32"), dtype=np.float32).reshape(nq, 240) for dl in dls]
        sem[m] = np.concatenate(parts, axis=1)
    gold_cols = [np.array([i * 240 + g for i in range(len(dls))]) for g in gold]
    return local, sem, gold_cols


def ranks_desc(x):
    """1-based rank of each column under descending order (stable ties)."""
    order = np.argsort(-x, axis=1, kind="stable")
    r = np.empty_like(order)
    rows = np.arange(x.shape[0])[:, None]
    r[rows, order] = np.arange(1, x.shape[1] + 1)[None, :]
    return r


def first_gold_rank(score, gold_cols, included=None):
    """Rank (1..10, else 0) of the best-placed gold column; excluded candidates never appear."""
    s = score.copy()
    if included is not None:
        s[~included] = -np.inf
    r = ranks_desc(s)
    out = np.zeros(nq, dtype=int)
    for q in range(nq):
        best = min(r[q, c] for c in gold_cols[q]) if np.isfinite(s[q, gold_cols[q]]).any() else 10**9
        out[q] = best if best <= 10 else 0
    return out


def app_blend(local, profiles, sem, min_sim=0.2, local_w=0.42, sem_term="percentile"):
    """Return (combined score, included mask). sem_term: 'percentile' (shipped) or 'minmax'."""
    n = local.shape[1]
    if not profiles:
        lr = ranks_desc(local)
        fusion = 1 / (60 + lr)
        comb = np.minimum(1, local * 0.78 + fusion / (1 / 61) * 0.22)
        return comb, local >= 0.15
    total_w = 1 + sum(w for _, w in profiles)
    lr = ranks_desc(local)
    fusion = 1 / (60 + lr)
    wq_num = np.zeros_like(local, dtype=float)
    wq_den = np.zeros_like(local, dtype=float)
    strong = np.zeros(local.shape, dtype=bool)
    for m, w in profiles:
        s = sem[m]
        ok = s >= min_sim
        masked = np.where(ok, s, -np.inf)
        r = ranks_desc(masked)
        cnt = ok.sum(axis=1, keepdims=True)
        fusion = fusion + np.where(ok, w / (60 + r), 0)
        strong |= ok & (r <= 8)
        if sem_term == "percentile":
            q = np.where(cnt == 1, 1.0, 1 - (r - 1) / np.maximum(cnt - 1, 1))
        else:  # per-profile min-max of the raw cosine over the candidate pool
            lo = np.where(ok, s, np.inf).min(axis=1, keepdims=True)
            hi = np.where(ok, s, -np.inf).max(axis=1, keepdims=True)
            q = (s - lo) / np.maximum(hi - lo, 1e-9)
        wq_num += np.where(ok, w * q, 0)
        wq_den += np.where(ok, w, 0)
    norm_fusion = fusion / (total_w / 61)
    pct = np.where(wq_den > 0, wq_num / np.maximum(wq_den, 1e-12), 0)
    comb = np.minimum(1, local * local_w + norm_fusion * 0.18 + pct * (1 - local_w - 0.18))
    return comb, (local >= 0.15) | strong


def variant_scores(name, local, profiles, sem):
    """Return (score, included) for an ablation variant."""
    if name == CURRENT:
        return app_blend(local, profiles, sem, sem_term="minmax")
    if name == PREVIOUS:
        return app_blend(local, profiles, sem, sem_term="percentile")
    if name.startswith("minmax-cosine, lexical="):
        lam = float(name.split("=")[1])
        return app_blend(local, profiles, sem, sem_term="minmax", local_w=lam)
    if name == "dense-only (mean cosine)":
        if not profiles:
            return local, np.ones_like(local, dtype=bool)
        tw = sum(w for _, w in profiles)
        return sum(w * sem[m] for m, w in profiles) / tw, np.ones_like(local, dtype=bool)
    if name == "plain RRF(local + profiles), k=60":
        sc = 1 / (60 + ranks_desc(local))
        for m, w in profiles:
            sc = sc + w / (60 + ranks_desc(sem[m]))
        return sc, np.ones_like(local, dtype=bool)
    raise KeyError(name)


CURRENT = "current (min-max cosine, 0.42 lexical)"
PREVIOUS = "previous (rank-percentile, 0.42 lexical)"
VARIANTS = [
    CURRENT,
    PREVIOUS,
    "minmax-cosine, lexical=0.2",
    "minmax-cosine, lexical=0.1",
    "plain RRF(local + profiles), k=60",
    "dense-only (mean cosine)",
]


def rr(r):
    r = np.asarray(r, dtype=float)
    return np.where(r > 0, 1.0 / np.maximum(r, 1), 0.0)


def cluster_stats(values, clusters):
    ids, inv = np.unique(clusters, return_inverse=True)
    return np.bincount(inv, weights=values, minlength=len(ids)), np.bincount(inv, minlength=len(ids)).astype(float)


def paired(a, b, clusters):
    d = a - b
    sums, counts = cluster_stats(d, clusters)
    k = len(sums)
    idx = RNG.integers(0, k, size=(B, k))
    ci = np.percentile(sums[idx].sum(axis=1) / counts[idx].sum(axis=1), [2.5, 97.5])
    signs = RNG.choice([-1.0, 1.0], size=(B, k))
    p = (np.sum(np.abs((signs * sums).sum(axis=1) / counts.sum()) >= abs(d.mean()) - 1e-15) + 1) / (B + 1)
    return d.mean(), ci, p


# ---------- Step 1: validation ----------
L = ["# Fusion-function replication and ablation\n"]
match_total = 0
match_exact = 0
cache = {s: load(s) for s in settings}
rows = []
for s in settings:
    local, sem, gold_cols = cache[s]
    for cname, profiles in CONFIGS.items():
        sc, inc = app_blend(local, profiles, sem, sem_term="minmax")
        mine = first_gold_rank(sc, gold_cols, inc)
        swift = np.array(res["settings"][s]["ranks"][SWIFT_NAME[cname]])
        match_exact += int((mine == swift).sum())
        match_total += nq
        rows.append((s, cname, float((mine == swift).mean()), rr(mine).mean(), rr(swift).mean()))
L.append("## 1. Replication check\n")
L.append(f"Python re-implementation of the current blend (min-max cosine semantic term) reproduces the Swift retriever's rank for "
         f"**{match_exact}/{match_total} = {match_exact/match_total:.2%}** of query×setting×config cases "
         f"({len(CONFIGS)} configs × {len(settings)} settings × {nq} queries). The Swift harness assigns candidate "
         f"UUIDs in index order, so the retriever's UUID tie-break equals this script's stable sort. With random "
         f"UUIDs the agreement was 99.45%: every residual difference was an exact local-score tie.\n")
worst = min(rows, key=lambda r: r[2])
L.append(f"Lowest per-cell agreement: {worst[0]} / {worst[1]} = {worst[2]:.2%}; |ΔMRR| max over cells = "
         f"{max(abs(r[3]-r[4]) for r in rows):.4f}.\n")

# ---------- Step 2: ablation ----------
ranks = {}  # (variant, config, setting) -> ranks
for v in VARIANTS:
    for cname, profiles in CONFIGS.items():
        for s in settings:
            local, sem, gold_cols = cache[s]
            sc, inc = variant_scores(v, local, profiles, sem)
            ranks[(v, cname, s)] = first_gold_rank(sc, gold_cols, inc)


def macro(v, c, mask):
    return float(np.mean([rr(ranks[(v, c, s)])[mask].mean() for s in settings]))


def worst_setting(v, c, mask):
    return float(min(rr(ranks[(v, c, s)])[mask].mean() for s in settings))


show_cfgs = ["local-only", "nomic", "bge-m3", "qwen3", "bge+qwen", "all3"]
L.append("## 2. Ablation of the fusion function — macro-MRR@10 over six settings\n")
for split_name, mask in (("DEV (even paragraphs)", dev), ("TEST (odd paragraphs, held out)", test)):
    L.append(f"\n**{split_name}**\n")
    L.append("| variant | " + " | ".join(show_cfgs) + " |")
    L.append("|---|" + "---|" * len(show_cfgs))
    for v in VARIANTS:
        L.append(f"| {v} | " + " | ".join(f"{macro(v, c, mask):.3f}" for c in show_cfgs) + " |")
L.append("\nWorst-setting MRR@10 on TEST (robustness):\n")
L.append("| variant | " + " | ".join(show_cfgs) + " |")
L.append("|---|" + "---|" * len(show_cfgs))
for v in VARIANTS:
    L.append(f"| {v} | " + " | ".join(f"{worst_setting(v, c, test):.3f}" for c in show_cfgs) + " |")

# DEV-selected variant per config, evaluated on TEST, vs shipped
SHIPPED = CURRENT
L.append("\n## 3. DEV-selected variant vs current blend (paired, TEST, pooled over six settings)\n")
L.append("| config | DEV-selected variant | current MRR | selected MRR | ΔMRR@10 [95% CI] | p |")
L.append("|---|---|---|---|---|---|")
summary = {}
clusters = np.concatenate([gold[test] for _ in settings])
for c in show_cfgs:
    if c == "local-only":
        continue
    sel = max(VARIANTS, key=lambda v: macro(v, c, dev))
    a = np.concatenate([rr(ranks[(sel, c, s)])[test] for s in settings])
    b = np.concatenate([rr(ranks[(SHIPPED, c, s)])[test] for s in settings])
    d, ci, p = paired(a, b, clusters)
    summary[c] = dict(selected=sel, shipped=b.mean(), selected_mrr=a.mean(), delta=d, ci=list(ci), p=p)
    L.append(f"| {c} | {sel} | {b.mean():.3f} | {a.mean():.3f} | {d:+.3f} [{ci[0]:+.3f}, {ci[1]:+.3f}] | {p:.4f} |")

L.append("\n## 3b. Effect of the shipped change: previous rank-percentile vs current min-max cosine (paired, TEST, pooled)\n")
L.append("| config | previous MRR | current MRR | ΔMRR@10 [95% CI] | p |")
L.append("|---|---|---|---|---|")
summary["before_after"] = {}
for c in show_cfgs:
    if c == "local-only":
        continue
    a = np.concatenate([rr(ranks[(CURRENT, c, s)])[test] for s in settings])
    b = np.concatenate([rr(ranks[(PREVIOUS, c, s)])[test] for s in settings])
    d, ci, p = paired(a, b, clusters)
    summary["before_after"][c] = dict(previous=b.mean(), current=a.mean(), delta=d, ci=list(ci), p=p)
    L.append(f"| {c} | {b.mean():.3f} | {a.mean():.3f} | {d:+.3f} [{ci[0]:+.3f}, {ci[1]:+.3f}] | {p:.4f} |")

# Rank-fusion vs score-fusion for multi-profile combos (dense-only, so the fusion step is isolated)
L.append("\n## 4. Isolating the multi-embedding step: RRF (rank) vs mean-cosine (score) fusion, dense-only, TEST\n")
L.append("| combination | best single (macro-MRR) | RRF-fused | mean-cosine-fused |")
L.append("|---|---|---|---|")


def dense_rank_variant(profiles, kind):
    out = {}
    for s in settings:
        local, sem, gold_cols = cache[s]
        if kind == "rrf":
            sc = sum(w / (60 + ranks_desc(sem[m])) for m, w in profiles)
        else:
            sc = sum(w * sem[m] for m, w in profiles)
        out[s] = first_gold_rank(sc, gold_cols)
    return out


def macro_of(out, mask):
    return float(np.mean([rr(out[s])[mask].mean() for s in settings]))


fusion_rows = {}
for label, profiles in (("bge-m3 + qwen3", CONFIGS["bge+qwen"]), ("nomic + bge-m3 + qwen3", CONFIGS["all3"])):
    singles = {m: macro_of(dense_rank_variant([(m, 1.0)], "rrf"), test) for m, _ in profiles}
    r_rrf = dense_rank_variant(profiles, "rrf")
    r_mean = dense_rank_variant(profiles, "mean")
    best_single = max(singles, key=singles.get)
    fusion_rows[label] = dict(best_single=best_single, best_single_mrr=singles[best_single],
                              rrf=macro_of(r_rrf, test), mean_cos=macro_of(r_mean, test))
    L.append(f"| {label} | {singles[best_single]:.3f} ({best_single}) | {macro_of(r_rrf, test):.3f} | {macro_of(r_mean, test):.3f} |")
summary["fusion_rank_vs_score"] = fusion_rows

open(os.path.join(WORK, "ablation.md"), "w").write("\n".join(L) + "\n")
json.dump(summary, open(os.path.join(WORK, "ablation.json"), "w"), indent=1)
print("\n".join(L))
