#!/usr/bin/env python3
"""Metrics, hierarchical-bootstrap CIs and paired comparisons for the synthetic personal-memory benchmark.

Queries are nested in personas, so intervals resample personas first and then queries within each drawn persona
(two-stage bootstrap, B = 4,000). Paired differences reuse the same resampling draws for both configurations.
Answerable queries (one gold item) give MRR@10, Recall@k and nDCG@10. 'injected' means the gold item is among the
(at most 6) items the app really injects with its default limits. Unanswerable queries measure false recall: how
often the app would still inject some memory although none answers the question.
"""
import json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
RNG = np.random.default_rng(20261025)
B = 4000

ds = json.load(open(os.path.join(WORK, "dataset.json")))
queries = ds["queries"]
items = {i["id"]: i for i in ds["items"]}
nq = len(queries)
persona = np.array([q["persona"] for q in queries])
personas = ds["personas"]
qtype = np.array([q["type"] for q in queries])
qlang = np.array([q["lang"] for q in queries])
gold_kind = np.array([items[q["gold"][0]]["kind"] if q["gold"] else "-" for q in queries])
answerable = qtype != "unanswerable"
DEV = np.isin(persona, [p for i, p in enumerate(personas) if i % 2 == 0])  # p1,p3,p5,p7
TEST = ~DEV

res = {}
for label in ("current", "previous", "legacyfade"):
    path = os.path.join(WORK, f"results.{label}.json")
    if os.path.exists(path):
        res[label] = json.load(open(path))
cur = res["current"]
configs = list(cur["stores"]["per-persona"].keys())
fmt = lambda x: f"{x:.3f}"


def arr(label, store, cfg, key):
    return np.asarray(res[label]["stores"][store][cfg][key], dtype=float)


def rr(r): return np.where(r > 0, 1.0 / np.maximum(r, 1), 0.0)
def ndcg(r): return np.where(r > 0, 1.0 / np.log2(np.maximum(r, 1) + 1), 0.0)
def hit(r, k): return ((r > 0) & (r <= k)).astype(float)


def persona_groups(mask):
    return [np.where(mask & (persona == p))[0] for p in personas if (mask & (persona == p)).any()]


def draws(groups):
    """B two-stage bootstrap draws -> list of index arrays into the query axis."""
    out = []
    g = len(groups)
    for _ in range(B):
        picked = RNG.integers(0, g, size=g)
        out.append(np.concatenate([RNG.choice(groups[k], size=len(groups[k]), replace=True) for k in picked]))
    return out


def ci_of(values, dr):
    m = np.array([values[d].mean() for d in dr])
    return np.percentile(m, [2.5, 97.5])


def paired(a, b, dr):
    d = a - b
    m = np.array([d[x].mean() for x in dr])
    ci = np.percentile(m, [2.5, 97.5])
    p = min(1.0, 2 * min((m <= 0).mean(), (m >= 0).mean()) + 1 / B)
    return d[ans_idx].mean(), ci, p  # draws index answerable queries only


ans_groups = persona_groups(answerable)
ans_draws = draws(ans_groups)
ans_idx = np.concatenate(ans_groups)
L = ["# Synthetic personal-memory benchmark: results\n"]
L.append(f"{len(personas)} fictional personas, {len(items)} stored items, {nq} queries "
         f"({int(answerable.sum())} answerable, {int((~answerable).sum())} unanswerable). "
         f"Real `HybridMemoryRetriever`, three local embedding models. Two-stage (persona → query) bootstrap, B = {B}. "
         f"No parameter was tuned on this data except the abstention thresholds in §8 and §10 (DEV personas p1,p3,p5,p7 → TEST p2,p4,p6,p8).\n")


def metric_row(label, store, cfg, mask_idx_draws=None):
    r = arr(label, store, cfg, "rank")
    x = rr(r)
    lo, hi = ci_of(x, ans_draws)
    return dict(mrr=x[ans_idx].mean(), lo=lo, hi=hi, r1=hit(r, 1)[ans_idx].mean(), r3=hit(r, 3)[ans_idx].mean(),
                inj=arr(label, store, cfg, "injected")[ans_idx].mean(), ndcg=ndcg(r)[ans_idx].mean(),
                false=(arr(label, store, cfg, "returned")[~answerable] > 0).mean(),
                nret=arr(label, store, cfg, "returned")[~answerable].mean())


summary = {}
for store, title in (("per-persona", "1. Each persona's own store (60-75 candidates), current retriever"),
                     ("pooled", "5. Pooled store (all personas together, ~500 candidates), current retriever")):
    if store == "pooled":
        continue
    L.append(f"## {title}\n")
    L.append("| config | MRR@10 [95% CI] | R@1 | R@3 | gold injected (top-6) | nDCG@10 | false recall (unanswerable) |\n|---|---|---|---|---|---|---|")
    rows = {c: metric_row("current", store, c) for c in configs}
    summary[store] = rows
    for c in sorted(configs, key=lambda c: -rows[c]["mrr"]):
        m = rows[c]
        L.append(f"| {c} | {fmt(m['mrr'])} [{fmt(m['lo'])}, {fmt(m['hi'])}] | {fmt(m['r1'])} | {fmt(m['r3'])} | {fmt(m['inj'])} | {fmt(m['ndcg'])} | {m['false']:.0%} ({m['nret']:.1f} items) |")

best_single = max(["nomic-v1.5", "bge-m3", "qwen3-emb-0.6b"], key=lambda c: summary["per-persona"][c]["mrr"])
FUSED = "bge-m3+qwen3-emb-0.6b"
ALL3 = "nomic-v1.5+bge-m3+qwen3-emb-0.6b"
show = ["local-only", best_single, FUSED, ALL3]
show = list(dict.fromkeys(show))

# 2. by query type / language / gold kind
def breakdown(title, key, values):
    L.append(f"\n## {title}\n")
    L.append("| " + key + " | n | " + " | ".join(show) + " |\n|---|---|" + "---|" * len(show))
    for v in values:
        sel = (answerable & (key_arr[key] == v))
        if not sel.any():
            continue
        cells = [fmt(rr(arr("current", "per-persona", c, "rank"))[sel].mean()) for c in show]
        L.append(f"| {v} | {int(sel.sum())} | " + " | ".join(cells) + " |")

key_arr = {"query type": qtype, "query language": qlang, "gold item kind": gold_kind}
L.append("\n*MRR@10 by subset (per-persona stores).*")
breakdown("2. By query type", "query type", ["direct", "paraphrase", "cross_lingual", "hard_negative"])
breakdown("3. By query language", "query language", ["tr", "en"])
breakdown("4. By kind of the gold item", "gold item kind", ["topic", "event", "message", "document"])

# 5. pooled
L.append("\n## 5. Pooled store (all personas together, ~500 candidates)\n")
L.append("| config | MRR@10 [95% CI] | R@1 | gold injected (top-6) | false recall |\n|---|---|---|---|---|")
for c in show:
    m = metric_row("current", "pooled", c)
    L.append(f"| {c} | {fmt(m['mrr'])} [{fmt(m['lo'])}, {fmt(m['hi'])}] | {fmt(m['r1'])} | {fmt(m['inj'])} | {m['false']:.0%} |")

# 6. before/after
if "previous" in res:
    L.append("\n## 6. Before both changes (rank-percentile blend, 14-day event fade) vs current retriever, same data, paired\n")
    L.append("| config | previous MRR | current MRR | ΔMRR@10 [95% CI] | p | Δ gold-injected |\n|---|---|---|---|---|---|")
    summary["before_after"] = {}
    for c in configs:
        a = rr(arr("current", "per-persona", c, "rank"))
        b = rr(arr("previous", "per-persona", c, "rank"))
        d, ci, p = paired(a, b, ans_draws)
        di = (arr("current", "per-persona", c, "injected") - arr("previous", "per-persona", c, "injected"))[ans_idx].mean()
        summary["before_after"][c] = dict(previous=b[ans_idx].mean(), current=a[ans_idx].mean(), delta=d, ci=list(ci), p=p)
        L.append(f"| {c} | {fmt(b[ans_idx].mean())} | {fmt(a[ans_idx].mean())} | {d:+.3f} [{ci[0]:+.3f}, {ci[1]:+.3f}] | {p:.4f} | {di:+.3f} |")
    fa = (arr("previous", "per-persona", FUSED, "returned")[~answerable] > 0).mean()
    fb = (arr("current", "per-persona", FUSED, "returned")[~answerable] > 0).mean()
    L.append(f"\nFalse recall on unanswerable queries ({FUSED}): previous {fa:.0%} → current {fb:.0%}.")

# 6b. event fade only
if "legacyfade" in res:
    L.append("\n## 6b. Event-fade change alone: legacy 14-day/0.15 fade vs the standard policy (same min-max retriever), paired\n")
    L.append("| config | subset | legacy fade MRR | standard MRR | ΔMRR@10 [95% CI] | p |\n|---|---|---|---|---|---|")
    for c in (FUSED := "bge-m3+qwen3-emb-0.6b", "local-only"):
        for name, sel in (("answer is an event", answerable & (gold_kind == "event")), ("answer is not an event", answerable & (gold_kind != "event"))):
            gs = [np.where(sel & (persona == p))[0] for p in personas if (sel & (persona == p)).any()]
            dr = draws(gs)
            a = rr(arr("current", "per-persona", c, "rank")); b = rr(arr("legacyfade", "per-persona", c, "rank"))
            d = a - b
            m = np.array([d[x].mean() for x in dr]); ci = np.percentile(m, [2.5, 97.5]); p = min(1.0, 2 * min((m <= 0).mean(), (m >= 0).mean()) + 1 / B)
            idx = np.concatenate(gs)
            L.append(f"| {c} | {name} (n={int(sel.sum())}) | {fmt(b[idx].mean())} | {fmt(a[idx].mean())} | {d[idx].mean():+.3f} [{ci[0]:+.3f}, {ci[1]:+.3f}] | {p:.4f} |")

# 7. significance of fusion vs best single and vs local-only (current)
L.append("\n## 7. Paired comparisons (current retriever, per-persona stores)\n")
L.append("| comparison | ΔMRR@10 [95% CI] | p |\n|---|---|---|")
for a_cfg, b_cfg in [(FUSED, best_single), (ALL3, best_single), (FUSED, "local-only"), (best_single, "local-only")]:
    d, ci, p = paired(rr(arr("current", "per-persona", a_cfg, "rank")), rr(arr("current", "per-persona", b_cfg, "rank")), ans_draws)
    L.append(f"| {a_cfg} vs {b_cfg} | {d:+.3f} [{ci[0]:+.3f}, {ci[1]:+.3f}] | {p:.4f} |")

# 8. abstention
L.append("\n## 8. Can the retriever abstain? (top-1 relevance as an answerable-vs-unanswerable detector)\n")
def auroc(pos, neg):
    allv = np.concatenate([pos, neg])
    order = allv.argsort().argsort() + 1.0
    return (order[:len(pos)].sum() - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))
L.append("| config | AUROC (all) | false recall at app defaults | τ chosen on DEV (keeps 90% of answerable) | TEST: answerable kept | TEST: unanswerable still recalled |\n|---|---|---|---|---|---|")
summary["abstention"] = {}
for c in show:
    top = arr("current", "per-persona", c, "top")
    au = auroc(top[answerable], top[~answerable])
    dev_pos = top[answerable & DEV]
    tau = np.percentile(dev_pos, 10)
    kept = (top[answerable & TEST] >= tau).mean()
    still = (top[~answerable & TEST] >= tau).mean()
    base = (arr("current", "per-persona", c, "returned")[~answerable] > 0).mean()
    summary["abstention"][c] = dict(auroc=au, tau=tau, kept=kept, still=still, base=base)
    L.append(f"| {c} | {au:.3f} | {base:.0%} | {tau:.3f} | {kept:.0%} | {still:.0%} |")


# 9. Event age
L.append("\n## 9. Events fade by design: MRR@10 of event-gold queries by age of the gold item (current retriever)\n")
age = np.array([items[q["gold"][0]]["age_days"] if q["gold"] else -1 for q in queries])
L.append("| age of gold event | n | " + " | ".join(show) + " |\n|---|---|" + "---|" * len(show))
for name, lo, hi in (("<= 14 days", 0, 14), ("15-45 days", 15, 45), ("> 45 days", 46, 10_000)):
    sel = answerable & (gold_kind == "event") & (age >= lo) & (age <= hi)
    if sel.any():
        L.append(f"| {name} | {int(sel.sum())} | " + " | ".join(fmt(rr(arr("current", "per-persona", c, "rank"))[sel].mean()) for c in show) + " |")
sel = answerable & (gold_kind == "topic")
L.append(f"| (reference: lasting topics) | {int(sel.sum())} | " + " | ".join(fmt(rr(arr("current", "per-persona", c, "rank"))[sel].mean()) for c in show) + " |")

# 10. Raw-cosine abstention
L.append("\n## 10. Abstention with the raw embedding similarity instead of the blended relevance\n")
L.append("Detector = the maximum cosine between the query and any item of the persona's store, per model. "
         "Threshold τ is the 10th percentile of that value over answerable DEV queries (keeps 90% of them); reported on TEST personas.\n")
L.append("| model | AUROC | τ (DEV) | TEST: answerable kept | TEST: unanswerable still recalled |\n|---|---|---|---|---|")
pers_items = {p: np.array([k for k, it in enumerate(ds["items"]) if it["persona"] == p]) for p in personas}
summary["raw_abstention"] = {}
for m in ["nomic-v1.5", "bge-m3", "qwen3-emb-0.6b"]:
    mat = np.fromfile(os.path.join(WORK, "scores", f"{m}.f32"), dtype=np.float32).reshape(nq, -1)
    mx = np.array([mat[i, pers_items[queries[i]["persona"]]].max() for i in range(nq)])
    au = auroc(mx[answerable], mx[~answerable])
    tau = np.percentile(mx[answerable & DEV], 10)
    kept = (mx[answerable & TEST] >= tau).mean()
    still = (mx[~answerable & TEST] >= tau).mean()
    summary["raw_abstention"][m] = dict(auroc=au, tau=float(tau), kept=kept, still=still)
    L.append(f"| {m} | {au:.3f} | {tau:.3f} | {kept:.0%} | {still:.0%} |")

json.dump(summary, open(os.path.join(WORK, "summary.json"), "w"), indent=1, default=float)
open(os.path.join(WORK, "results.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
