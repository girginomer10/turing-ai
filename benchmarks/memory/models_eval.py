#!/usr/bin/env python3
"""Model comparison on the synthetic personal-memory benchmark: embeddings, fusion, rerankers, abstention.

Inputs: work/results.models.json (MemoryBench run with all models and fusion candidates), work/scores/*.f32,
work/rerank/*.f32 (rerank.py). Output: work/models.md, work/models.json.
Protocol: DEV personas p1,p3,p5,p7 select; TEST personas p2,p4,p6,p8 confirm. Two-stage bootstrap (persona, query), B = 4000.
"""
import itertools, json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
RNG = np.random.default_rng(20261027)
B = 4000

ds = json.load(open(os.path.join(WORK, "dataset.json")))
queries, items, personas = ds["queries"], ds["items"], ds["personas"]
nq = len(queries)
persona = np.array([q["persona"] for q in queries])
qtype = np.array([q["type"] for q in queries])
answerable = qtype != "unanswerable"
gold_idx = np.array([next((k for k, it in enumerate(items) if it["id"] == q["gold"][0]), -1) if q["gold"] else -1 for q in queries])
DEV = np.isin(persona, personas[0::2])
TEST = ~DEV
R = json.load(open(os.path.join(WORK, "results.models.json")))
store = R["stores"]["per-persona"]
singles = [m for m in R["models"]]
configs = list(store.keys())
fmt = lambda x: f"{x:.3f}"


def arr(cfg, key): return np.asarray(store[cfg][key], dtype=float)
def rr(r): return np.where(r > 0, 1.0 / np.maximum(r, 1), 0.0)
def ndcg(r): return np.where(r > 0, 1.0 / np.log2(np.maximum(r, 1) + 1), 0.0)
def hit(r, k): return ((r > 0) & (r <= k)).astype(float)


def groups(mask):
    return [np.where(mask & (persona == p))[0] for p in personas if (mask & (persona == p)).any()]


def draws(gs):
    out = []
    for _ in range(B):
        pick = RNG.integers(0, len(gs), size=len(gs))
        out.append(np.concatenate([RNG.choice(gs[k], size=len(gs[k]), replace=True) for k in pick]))
    return out


def ci(values, dr):
    return np.percentile([values[d].mean() for d in dr], [2.5, 97.5])


def paired(a, b, dr, idx):
    d = a - b
    m = np.array([d[x].mean() for x in dr])
    p = min(1.0, 2 * min((m <= 0).mean(), (m >= 0).mean()) + 1 / B)
    return d[idx].mean(), np.percentile(m, [2.5, 97.5]), p


ALL = groups(answerable); ALL_D = draws(ALL); ALL_I = np.concatenate(ALL)
TST = groups(answerable & TEST); TST_D = draws(TST); TST_I = np.concatenate(TST)
DEVG = groups(answerable & DEV)
L = ["# Model comparison on the synthetic personal-memory benchmark\n",
     f"{len(personas)} personas, {int(answerable.sum())} answerable queries, per-persona stores, real retriever. "
     "Two-stage bootstrap B = 4000. DEV personas p1,p3,p5,p7 select, TEST personas p2,p4,p6,p8 confirm.\n"]

# ---------- A. leaderboard ----------
info = {}
for m in singles:
    t = os.path.join(WORK, "scores", f"{m}.timing.json")
    info[m] = json.load(open(t)) if os.path.exists(t) else {}
L.append("## A. Embedding models alone (all personas)\n")
L.append("| model | MRR@10 [95% CI] | R@1 | gold injected (top-6) | direct | paraphrase | cross-lingual | hard neg. | embed s |\n|---|---|---|---|---|---|---|---|---|")
rows = []
for c in ["local-only"] + singles:
    x = rr(arr(c, "rank"))
    lo, hi = ci(x, ALL_D)
    bytype = [x[answerable & (qtype == t)].mean() for t in ("direct", "paraphrase", "cross_lingual", "hard_negative")]
    rows.append((x[ALL_I].mean(), c, lo, hi, hit(arr(c, "rank"), 1)[ALL_I].mean(), arr(c, "injected")[ALL_I].mean(), bytype))
for mrr, c, lo, hi, r1, inj, bt in sorted(rows, reverse=True):
    sec = info.get(c, {}).get("seconds")
    L.append(f"| {c} | {fmt(mrr)} [{fmt(lo)}, {fmt(hi)}] | {fmt(r1)} | {fmt(inj)} | " + " | ".join(fmt(v) for v in bt) + f" | {sec:.0f} |" if sec else
             f"| {c} | {fmt(mrr)} [{fmt(lo)}, {fmt(hi)}] | {fmt(r1)} | {fmt(inj)} | " + " | ".join(fmt(v) for v in bt) + " | - |")

# ---------- B. fusion selection ----------
dev_mrr = {c: np.mean([rr(arr(c, "rank"))[g].mean() for g in DEVG] ) for c in configs}
top5 = sorted(singles, key=lambda c: -dev_mrr[c])[:5]
fusion_cfgs = [c for c in configs if c not in singles and c != "local-only"]
best_single = max(singles, key=lambda c: dev_mrr[c])
best_fusion = max(fusion_cfgs, key=lambda c: dev_mrr[c]) if fusion_cfgs else None
L.append("\n## B. Does fusing profiles help? (selection on DEV, report on TEST)\n")
L.append(f"Best single on DEV: **{best_single}**; best fusion on DEV: **{best_fusion}** (from {len(fusion_cfgs)} candidate fusions of the top models).\n")
L.append("| config | TEST MRR@10 [95% CI] | TEST R@1 | TEST gold injected |\n|---|---|---|---|")
shown = [best_single, best_fusion]
for c in shown:
    x = rr(arr(c, "rank")); lo, hi = ci(x, TST_D)
    L.append(f"| {c} | {fmt(x[TST_I].mean())} [{fmt(lo)}, {fmt(hi)}] | {fmt(hit(arr(c, 'rank'), 1)[TST_I].mean())} | {fmt(arr(c, 'injected')[TST_I].mean())} |")
d, c2, p = paired(rr(arr(best_fusion, "rank")), rr(arr(best_single, "rank")), TST_D, TST_I)
L.append(f"\nFusion minus best single on TEST: ΔMRR@10 {d:+.3f} [{c2[0]:+.3f}, {c2[1]:+.3f}], p = {p:.3f}.")
L.append("\nTop fusions by DEV MRR: " + ", ".join(f"{c} ({dev_mrr[c]:.3f})" for c in sorted(fusion_cfgs, key=lambda c: -dev_mrr[c])[:5]) + ".")

# ---------- C. reranking ----------
rr_dir = os.path.join(WORK, "rerank")
DEFAULT_FIRST = "bge-m3+qwen3-emb-0.6b"
summary = {"best_single": best_single, "best_fusion": best_fusion}
DEPTH = 20


def auroc(pos, neg):
    v = np.concatenate([pos, neg]); o = v.argsort().argsort() + 1.0
    return (o[:len(pos)].sum() - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))


RERANK_RANKS = {}


def rerankers_for(first):
    if not os.path.isdir(rr_dir):
        return {}
    suffix = "" if first == DEFAULT_FIRST else "@" + first
    out = {}
    for f in sorted(os.listdir(rr_dir)):
        if not f.endswith(".f32"):
            continue
        stem = f[:-4]
        name, _, tag = stem.partition("@")
        if ("@" + tag if tag else "") == suffix:
            out[name] = np.fromfile(os.path.join(rr_dir, f), dtype=np.float32).reshape(nq, -1)
    return out


def rerank_section(first):
    mats = rerankers_for(first)
    if not mats:
        return
    cand = store[first]["candidates"]
    suffix = "" if first == DEFAULT_FIRST else "@" + first

    def rerank_rank(r, mode):
        out = np.zeros(nq); inj = np.zeros(nq)
        for q in range(nq):
            c = cand[q][:DEPTH]
            if not c:
                continue
            s = np.where(np.isnan(mats[r][q, c]), -1e9, mats[r][q, c])
            rank_rr = np.empty(len(c), dtype=int); rank_rr[np.argsort(-s, kind="stable")] = np.arange(1, len(c) + 1)
            key = -s if mode == "rerank" else -(1 / (60 + np.arange(1, len(c) + 1)) + 1 / (60 + rank_rr))
            order = np.argsort(key, kind="stable")
            pos = [i for i, j in enumerate(order) if c[j] == gold_idx[q]]
            if pos:
                out[q] = pos[0] + 1 if pos[0] < 10 else 0
                inj[q] = 1.0 if pos[0] < 6 else 0.0
        return out, inj

    cover = np.array([1.0 if gold_idx[q] in cand[q][:DEPTH] else 0.0 for q in range(nq)])
    base_inj = np.array([1.0 if gold_idx[q] in cand[q][:6] else 0.0 for q in range(nq)])
    base = rr(arr(first, "rank"))
    L.append(f"\n## C. Second-stage reranking (first stage: {first}, top {DEPTH} candidates)\n")
    L.append(f"The correct item is among the first stage's top {DEPTH} for {cover[ALL_I].mean():.1%} of answerable queries (upper bound for any reranker).\n")
    L.append("| pipeline | MRR@10 [95% CI] | R@1 | gold in top-6 | ΔMRR vs first stage [95% CI] | p |\n|---|---|---|---|---|---|")
    lo, hi = ci(base, ALL_D)
    L.append(f"| {first} (no reranker) | {fmt(base[ALL_I].mean())} [{fmt(lo)}, {fmt(hi)}] | {fmt(hit(arr(first, 'rank'), 1)[ALL_I].mean())} | {fmt(base_inj[ALL_I].mean())} | - | - |")
    res_c = {}
    for r in mats:
        for mode, label in (("rerank", "reranker only"), ("rrf", "reranker + first stage (RRF)")):
            ranks, inj = rerank_rank(r, mode)
            RERANK_RANKS[(first, r, mode)] = ranks
            x = rr(ranks); lo, hi = ci(x, ALL_D)
            d, c2, p = paired(x, base, ALL_D, ALL_I)
            res_c[f"{r}|{mode}"] = dict(mrr=x[ALL_I].mean(), r1=hit(ranks, 1)[ALL_I].mean(), delta=d, ci=list(c2), p=p, inj=inj[ALL_I].mean())
            L.append(f"| + {r}, {label} | {fmt(x[ALL_I].mean())} [{fmt(lo)}, {fmt(hi)}] | {fmt(hit(ranks, 1)[ALL_I].mean())} | {fmt(inj[ALL_I].mean())} | {d:+.3f} [{c2[0]:+.3f}, {c2[1]:+.3f}] | {p:.4f} |")
    summary.setdefault("rerank", {})[first] = res_c
    best_r = max(mats, key=lambda r: res_c[f"{r}|rerank"]["mrr"])
    ranks, _ = rerank_rank(best_r, "rerank")
    L.append(f"\nMRR@10 by query type, {first} vs + {best_r} (reranker only):\n")
    L.append("| type | first stage | + reranker |\n|---|---|---|")
    for t in ("direct", "paraphrase", "cross_lingual", "hard_negative"):
        sel = answerable & (qtype == t)
        L.append(f"| {t} | {fmt(base[sel].mean())} | {fmt(rr(ranks)[sel].mean())} |")
    L.append(f"\n**Abstention with the reranker's top score (first stage {first}).** DEV personas choose τ (keeps 90% of answerable queries), TEST confirms; today the app injects 6 items for 100% of unanswerable queries.\n")
    L.append("| reranker | AUROC | τ | TEST: answerable kept | TEST: unanswerable still injected | latency per query (20 docs) |\n|---|---|---|---|---|---|")
    summary.setdefault("abstention", {})[first] = {}
    for r in mats:
        top = np.array([np.max(np.where(np.isnan(mats[r][q, cand[q][:DEPTH]]), -1e9, mats[r][q, cand[q][:DEPTH]])) if cand[q] else -1e9 for q in range(nq)])
        au = auroc(top[answerable], top[~answerable])
        tau = np.percentile(top[answerable & DEV], 10)
        kept = (top[answerable & TEST] >= tau).mean(); still = (top[~answerable & TEST] >= tau).mean()
        tpath = os.path.join(rr_dir, f"{r}{suffix}.timing.json")
        lat = ""
        if os.path.exists(tpath):
            t = json.load(open(tpath)); lat = f"{DEPTH / t['pairs_per_second'] * 1000:.0f} ms"
        summary["abstention"][first][r] = dict(auroc=au, tau=float(tau), kept=kept, still=still)
        L.append(f"| {r} | {au:.3f} | {tau:.4g} | {kept:.0%} | {still:.0%} | {lat or '-'} |")


rerank_section(DEFAULT_FIRST)
if best_fusion and best_fusion != DEFAULT_FIRST:
    rerank_section(best_fusion)

# ---------- E. prefix ablation ----------
pp = os.path.join(WORK, "results.prefix.json")
if os.path.exists(pp):
    P = json.load(open(pp))["stores"]["per-persona"]
    L.append("\n## E. Do query/document prefixes matter? (single model, formatted vs raw text, all personas)\n")
    L.append("| model | formatted MRR@10 | raw MRR@10 | ΔMRR@10 [95% CI] | p |\n|---|---|---|---|---|")
    summary["prefix"] = {}
    for m in ("embeddinggemma-300m", "arctic-embed-l-v2", "e5-large-instruct", "qwen3-emb-0.6b", "nomic-v2-moe", "nomic-v1.5"):
        a_ = rr(np.asarray(P[m]["rank"], dtype=float)); b_ = rr(np.asarray(P[m + "-raw"]["rank"], dtype=float))
        d, c2, p = paired(a_, b_, ALL_D, ALL_I)
        summary["prefix"][m] = dict(formatted=a_[ALL_I].mean(), raw=b_[ALL_I].mean(), delta=d, ci=list(c2), p=p)
        L.append(f"| {m} | {fmt(a_[ALL_I].mean())} | {fmt(b_[ALL_I].mean())} | {d:+.3f} [{c2[0]:+.3f}, {c2[1]:+.3f}] | {p:.4f} |")

# ---------- F. dimension truncation ----------
dp = os.path.join(WORK, "results.dims.json")
if os.path.exists(dp):
    D_ = json.load(open(dp))["stores"]["per-persona"]
    L.append("\n## F. Matryoshka truncation: smaller vectors, same model (all personas)\n")
    L.append("| model | dims | vector bytes per item (float32) | MRR@10 [95% CI] | ΔMRR vs full |\n|---|---|---|---|---|")
    summary["dims"] = {}
    for m, full in (("embeddinggemma-300m", 768), ("arctic-embed-l-v2", 1024)):
        base_ = rr(np.asarray(D_[m]["rank"], dtype=float))
        for dim in (full, 512, 256, 128):
            name = m if dim == full else f"{m}-d{dim}"
            if name not in D_:
                continue
            x = rr(np.asarray(D_[name]["rank"], dtype=float)); lo, hi = ci(x, ALL_D)
            d, c2, p = paired(x, base_, ALL_D, ALL_I)
            summary["dims"][name] = dict(mrr=x[ALL_I].mean(), delta=d, ci=list(c2))
            L.append(f"| {m} | {dim} | {dim * 4} | {fmt(x[ALL_I].mean())} [{fmt(lo)}, {fmt(hi)}] | " + ("-" if dim == full else f"{d:+.3f} [{c2[0]:+.3f}, {c2[1]:+.3f}]") + " |")


# ---------- G. ladder (for the figure) ----------
stages = [("lexical only (no embedding model)", arr("local-only", "rank")),
          ("nomic-embed v1.5 (the Tinfoil preset's default model)", arr("nomic-v1.5", "rank")),
          ("bge-m3 + Qwen3-0.6B fused (earlier setup)", arr(DEFAULT_FIRST, "rank")),
          ("best single embedding: " + max(singles, key=lambda c: rr(arr(c, "rank"))[ALL_I].mean()), arr(max(singles, key=lambda c: rr(arr(c, "rank"))[ALL_I].mean()), "rank")),
          ("best fusion (DEV): " + str(best_fusion), arr(best_fusion, "rank"))]
for r in ("bge-reranker-v2-m3", "qwen3-rerank-4b"):
    key = (best_fusion, r, "rerank")
    if key in RERANK_RANKS:
        stages.append((f"+ {r} reranker", RERANK_RANKS[key]))
ladder_rows = []
for label, ranks in stages:
    x = rr(np.asarray(ranks, dtype=float)); lo, hi = ci(x, ALL_D)
    ladder_rows.append(dict(label=label, mrr=float(x[ALL_I].mean()), lo=float(lo), hi=float(hi), r1=float(hit(np.asarray(ranks), 1)[ALL_I].mean())))
summary["ladder"] = ladder_rows
L.append("\n## G. Ladder: from lexical search to the best pipeline (all personas)\n")
L.append("| stage | MRR@10 [95% CI] | R@1 |\n|---|---|---|")
for r_ in ladder_rows:
    L.append(f"| {r_['label']} | {r_['mrr']:.3f} [{r_['lo']:.3f}, {r_['hi']:.3f}] | {r_['r1']:.3f} |")

json.dump(summary, open(os.path.join(WORK, "models.json"), "w"), indent=1, default=float)
open(os.path.join(WORK, "models.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
