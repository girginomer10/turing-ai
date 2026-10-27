#!/usr/bin/env python3
"""Hosted embeddings, rerankers and LLM judges on the synthetic personal-memory benchmark.

Inputs: work/results.allmodels.json (every embedding model, real retriever), work/results.hostedfusions.json (first-stage candidates),
work/rerank/<model>@voyage-4-large.f32, work/llm/{A,B}/*.jsonl (smart_memory.py). Output: work/hosted.md, work/hosted.json.
Two-stage (persona, query) bootstrap, B = 4000. DEV personas p1,p3,p5,p7 choose anything chosen; TEST personas confirm.
"""
import glob, json, os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
RNG = np.random.default_rng(20261030)
B = 4000
FIRST = os.environ.get("FIRST_STAGE", "voyage-4-large")

ds = json.load(open(os.path.join(WORK, "dataset.json")))
queries, items, personas = ds["queries"], ds["items"], ds["personas"]
nq = len(queries)
persona = np.array([q["persona"] for q in queries]); qtype = np.array([q["type"] for q in queries])
answerable = qtype != "unanswerable"
gold_idx = np.array([next((k for k, it in enumerate(items) if it["id"] == q["gold"][0]), -1) if q["gold"] else -1 for q in queries])
DEV = np.isin(persona, personas[0::2]); TEST = ~DEV
ALLM = json.load(open(os.path.join(WORK, "results.allmodels.json")))["stores"]["per-persona"]
FS = json.load(open(os.path.join(WORK, "results.hostedfusions.json")))["stores"]["per-persona"]
fmt = lambda x: f"{x:.3f}"
rr = lambda r: np.where(np.asarray(r, dtype=float) > 0, 1.0 / np.maximum(np.asarray(r, dtype=float), 1), 0.0)


def groups(mask): return [np.where(mask & (persona == p))[0] for p in personas if (mask & (persona == p)).any()]
def draws(gs):
    out = []
    for _ in range(B):
        pick = RNG.integers(0, len(gs), size=len(gs))
        out.append(np.concatenate([RNG.choice(gs[k], size=len(gs[k]), replace=True) for k in pick]))
    return out
def ci(v, dr): return np.percentile([v[d].mean() for d in dr], [2.5, 97.5])
def paired(a, b, dr, idx):
    d = a - b; m = np.array([d[x].mean() for x in dr])
    return d[idx].mean(), np.percentile(m, [2.5, 97.5]), min(1.0, 2 * min((m <= 0).mean(), (m >= 0).mean()) + 1 / B)


AG = groups(answerable); AD = draws(AG); AI = np.concatenate(AG)
L = ["# Hosted models, rerankers and LLM judges\n",
     f"Synthetic personal-memory benchmark, {int(answerable.sum())} answerable queries, per-persona stores, real retriever. "
     "Two-stage bootstrap B = 4000.\n"]
summary = {}

# ---------- 1. embedding leaderboard ----------
HOSTED = lambda m: m.startswith(("openai", "voyage", "cohere", "or-", "di-"))
L.append("## 1. Every embedding model (alone, all personas)\n")
L.append("| model | where | MRR@10 [95% CI] | R@1 | gold injected | cross-lingual MRR |\n|---|---|---|---|---|---|")
rows = []
for c, v in ALLM.items():
    r = v["rank"]; x = rr(r); lo, hi = ci(x, AD)
    xl = x[answerable & (qtype == "cross_lingual")].mean()
    rows.append((x[AI].mean(), c, lo, hi, (np.asarray(r) == 1)[AI].mean(), np.asarray(v["injected"])[AI].mean(), xl))
for mrr, c, lo, hi, r1, inj, xl in sorted(rows, reverse=True):
    L.append(f"| {c} | {'hosted' if HOSTED(c) else ('baseline' if c == 'local-only' else 'local Q8')} | {fmt(mrr)} [{fmt(lo)}, {fmt(hi)}] | {fmt(r1)} | {fmt(inj)} | {fmt(xl)} |")
summary["leaderboard"] = {c: dict(mrr=m, r1=r1, inj=inj, xlingual=xl) for m, c, lo, hi, r1, inj, xl in rows}
L.append("\nSame model, local 8-bit GGUF vs hosted full precision: " + "; ".join(
    f"{a} {summary['leaderboard'][a]['mrr']:.3f} vs {b} {summary['leaderboard'][b]['mrr']:.3f}"
    for a, b in (("bge-m3", "di-bge-m3"), ("embeddinggemma-300m", "di-embeddinggemma-300m")) if a in summary["leaderboard"] and b in summary["leaderboard"]) + ".")
if "di-nemotron-embed-8b" in ALLM and "di-nemotron-embed-8b-qp" in ALLM:
    a, b = (summary["leaderboard"][k]["mrr"] for k in ("di-nemotron-embed-8b-qp", "di-nemotron-embed-8b"))
    L.append(f"Nemotron-Embed-8B with `query:`/`passage:` prefixes {a:.3f} vs raw {b:.3f} (Δ {a-b:+.3f}).")

# ---------- 2. rerankers ----------
cand = FS[FIRST]["candidates"]
DEPTH = 20
rr_dir = os.path.join(WORK, "rerank")
mats = {}
for f in sorted(glob.glob(os.path.join(rr_dir, f"*@{FIRST}.f32"))):
    name = os.path.basename(f)[: -len(f"@{FIRST}.f32")]
    mats[name] = np.fromfile(f, dtype=np.float32).reshape(nq, -1)


def rerank_ranks(m):
    out = np.zeros(nq); inj = np.zeros(nq)
    for q in range(nq):
        c = cand[q][:DEPTH]
        if not c: continue
        s = np.where(np.isnan(m[q, c]), -1e9, m[q, c])
        order = np.argsort(-s, kind="stable")
        pos = [i for i, j in enumerate(order) if c[j] == gold_idx[q]]
        if pos:
            out[q] = pos[0] + 1 if pos[0] < 10 else 0
            inj[q] = 1.0 if pos[0] < 6 else 0.0
    return out, inj


def auroc(pos, neg):
    v = np.concatenate([pos, neg]); o = v.argsort().argsort() + 1.0
    return (o[:len(pos)].sum() - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))


base = rr(ALLM[FIRST]["rank"]); base_inj = np.array([1.0 if gold_idx[q] in cand[q][:6] else 0.0 for q in range(nq)])
cover = np.array([1.0 if gold_idx[q] in cand[q][:DEPTH] else 0.0 for q in range(nq)])
L.append(f"\n## 2. Rerankers on top of {FIRST} (top {DEPTH})\n")
L.append(f"The correct item is inside the first stage's top {DEPTH} for {cover[AI].mean():.1%} of answerable queries.\n")
L.append("| reranker | MRR@10 [95% CI] | R@1 | gold in top-6 | ΔMRR vs first stage | abstention AUROC | s / query |\n|---|---|---|---|---|---|---|")
lo, hi = ci(base, AD)
L.append(f"| {FIRST} alone | {fmt(base[AI].mean())} [{fmt(lo)}, {fmt(hi)}] | {fmt((np.asarray(ALLM[FIRST]['rank']) == 1)[AI].mean())} | {fmt(base_inj[AI].mean())} | - | - | - |")
summary["rerank"] = {}
rr_rows = []
for name, m in mats.items():
    ranks, inj = rerank_ranks(m); x = rr(ranks); lo, hi = ci(x, AD)
    d, c2, p = paired(x, base, AD, AI)
    top = np.array([np.max(np.where(np.isnan(m[q, cand[q][:DEPTH]]), -1e9, m[q, cand[q][:DEPTH]])) if cand[q] else -1e9 for q in range(nq)])
    au = auroc(top[answerable], top[~answerable])
    tpath = os.path.join(rr_dir, f"{name}@{FIRST}.timing.json")
    sec = json.load(open(tpath))["seconds"] / nq if os.path.exists(tpath) and not name.startswith("cohere") else None  # Cohere ran on a rate-limited trial key
    summary["rerank"][name] = dict(mrr=x[AI].mean(), r1=(ranks == 1)[AI].mean(), inj=inj[AI].mean(), delta=d, ci=list(c2), p=p, auroc=au, sec=sec)
    rr_rows.append((x[AI].mean(), name, lo, hi, (ranks == 1)[AI].mean(), inj[AI].mean(), d, c2, p, au, sec))
for mrr, name, lo, hi, r1, inj, d, c2, p, au, sec in sorted(rr_rows, reverse=True):
    L.append(f"| {name} | {fmt(mrr)} [{fmt(lo)}, {fmt(hi)}] | {fmt(r1)} | {fmt(inj)} | {d:+.3f} [{c2[0]:+.3f}, {c2[1]:+.3f}] | {au:.3f} | {('%.2f' % sec) if sec else '-'} |")

# ---------- 3. LLM judges (the app's Smart memory prompt) ----------
def tolerant(raw, allowed):
    """The relaxed Swift decoder (SemanticMemoryReranker.decode) applied to a stored answer: the first JSON value is used (trailing
    prose ignored), a bare array is accepted, entries with unknown IDs or confidence outside 0.75...1 are dropped, at most six survive,
    and an answer whose only entries are unknown IDs is rejected (None), exactly as in the app."""
    import re
    text = (raw or "").strip()
    text = re.sub(r"^```(?:json)?", "", text).strip()
    start = min([i for i in (text.find("{"), text.find("[")) if i >= 0], default=-1)
    if start < 0:
        return None
    try:
        value, _ = json.JSONDecoder().raw_decode(text[start:])
    except ValueError:
        return None
    rel = value.get("relevant") if isinstance(value, dict) else value
    if not isinstance(rel, list):
        return None
    picked, unknown, below = {}, 0, 0
    for e in rel:
        if not (isinstance(e, dict) and isinstance(e.get("id"), str) and isinstance(e.get("confidence"), (int, float))):
            return None
        if e["id"] not in allowed:
            unknown += 1
            continue
        if not 0.75 <= e["confidence"] <= 1:
            below += 1
            continue
        picked[e["id"]] = max(picked.get(e["id"], 0), e["confidence"])
    if not picked and unknown > 0 and below == 0:
        return None
    return dict(sorted(picked.items(), key=lambda kv: -kv[1])[:6])


def load_llm(setting):
    """First attempt per query only. The runner re-asked rejected queries once to learn what the answers looked like; the app never
    re-asks, so those later records are ignored here. Provider errors (e.g. HTTP 402 payment failures) are not model output."""
    out = {}
    for f in sorted(glob.glob(os.path.join(WORK, "llm", setting, "*.jsonl"))):
        first = {}
        for line in open(f):
            r = json.loads(line)
            first.setdefault(r["q"], r)
        if len(first) >= 0.9 * nq:
            out[os.path.basename(f)[:-6]] = first
    return out


PSEUDO = None
def pseudo(item_id):
    import uuid
    return str(uuid.uuid5(uuid.UUID("5d1d6e4a-79d1-4a63-8c33-0e0d0c6f9a11"), item_id)).upper()


def wilson(k, n, z=1.96):
    p = k / n; den = 1 + z * z / n; c = (p + z * z / (2 * n)) / den; h = z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return c - h, c + h


for setting, title in (("B", f"candidates = top 20 of {FIRST}"), ("A", "the app's old pool: first 40 of the local lexical ranking")):
    runs = load_llm(setting)
    if not runs: continue
    L.append(f"\n## 3{setting}. LLM judge, setting {setting} ({title})\n")
    L.append("First attempt only, provider errors excluded (they are not model output). Strict = the app's previous decoder (any deviation rejects the "
             "whole answer); tolerant = the new decoder (first JSON value, bare arrays accepted, unknown IDs and confidence < 0.75 dropped, answers made "
             "only of invented IDs still rejected). Rejected answers fall back to ordinary ranking in the app and are left out of the two right-hand "
             "rates. Because rejected stored answers keep only their first 400 characters, tolerant validity is a lower bound.\n")
    L.append("| model | answers scored | strict valid | tolerant valid | answer selected (tolerant) | mean items | unanswerable: anything selected [95% Wilson] | answer in candidates | $ / 1k queries | s / query |\n|---|---|---|---|---|---|---|---|---|---|")
    summary.setdefault("llm", {})[setting] = {}
    for name, recs in runs.items():
        n_ok = hit = n_ans_valid = nsel_total = n_valid = any_sel = n_unans_valid = strict_ok = 0
        cov = n_cov = 0
        cost = sec = 0.0; n_cost = 0
        for q in range(nq):
            r = recs.get(q)
            if r is None or r.get("error"): continue
            n_ok += 1; cost += r.get("cost") or 0; sec += r.get("seconds") or 0; n_cost += 1
            if answerable[q]:
                n_cov += 1; cov += 1 if gold_idx[q] in r["candidates"] else 0
            strict_ok += 1 if r["valid"] else 0
            if r["valid"]:
                ids = [s_[0] for s_ in sorted(r["selected"], key=lambda t: -t[1])]
            else:
                allowed = {pseudo(items[k]["id"]): k for k in r["candidates"]}
                t = tolerant(r.get("raw"), set(allowed))
                if t is None: continue
                ids = [allowed[k] for k in t]
            n_valid += 1; nsel_total += len(ids)
            if answerable[q]:
                n_ans_valid += 1; hit += 1 if gold_idx[q] in ids else 0
            else:
                n_unans_valid += 1; any_sel += 1 if ids else 0
        lo, hi = wilson(any_sel, n_unans_valid)
        L.append(f"| {name} | {n_ok} | {strict_ok / n_ok:.1%} | {n_valid / n_ok:.1%} | {hit / n_ans_valid:.3f} | {nsel_total / n_valid:.2f} | "
                 f"{any_sel / n_unans_valid:.0%} [{lo:.0%}, {hi:.0%}] ({any_sel}/{n_unans_valid}) | {cov / n_cov:.3f} | {cost / n_cost * 1000:.2f} | {sec / n_cost:.1f} |")
        summary["llm"][setting][name] = dict(n=n_ok, strict_valid=strict_ok / n_ok, tolerant_valid=n_valid / n_ok, hit=hit / n_ans_valid, false=any_sel / n_unans_valid,
                                              false_ci=[lo, hi], cost_per_1k=cost / n_cost * 1000, sec=sec / n_cost, items=nsel_total / n_valid, coverage=cov / n_cov)

# ---------- 4. Abstention frontier: thresholded rerankers vs LLM judges ----------
pp = os.path.join(WORK, "results.pipelinehosted.json")
if os.path.exists(pp):
    P = json.load(open(pp))["stores"]["per-persona"]
    L.append("\n## 4. When nothing answers: injecting less without losing the answer\n")
    L.append("Real retriever, candidates = top 20 of voyage-4-large. A cross-encoder keeps candidates above a probability threshold τ and injects at most six; "
             "an LLM judge selects the IDs that help (Smart memory prompt, setting B, tolerant decoding). "
             "x = share of unanswerable queries where anything is injected (lower is better), y = share of answerable queries whose answer is injected.\n")
    L.append("| method | τ | gold injected (answerable) | anything injected (unanswerable) | mean items (unanswerable) |\n|---|---|---|---|---|")
    frontier = []
    for c, v in sorted(P.items(), key=lambda kv: (kv[0].split(">>")[-1].split("~")[0], float(kv[0].split("~")[-1]) if "~" in kv[0] else 0)):
        if ">>" not in c: continue
        name, tau = c.replace("@" + FIRST, "").split(">>")[1].split("~")
        if name == "di-nemotron-rerank-8b": continue  # raw logits: a probability threshold grid is meaningless for it
        if name in ("voyage-rerank-2.5-lite", "di-qwen3-rerank-4b", "cohere-rerank-v3.5") and float(tau) not in (0.0, 0.5): continue
        inj = np.asarray(v["injected"], dtype=float); ret = np.asarray(v["returned"], dtype=float)
        pt = (name, float(tau), inj[answerable].mean(), float((ret[~answerable] > 0).mean()), float(ret[~answerable].mean()))
        frontier.append(pt)
        L.append(f"| {name} | {tau} | {pt[2]:.3f} | {pt[3]:.0%} | {pt[4]:.1f} |")
    llm_points = []
    for name, rec in summary.get("llm", {}).get("B", {}).items():
        pt = (name, None, rec["hit"], rec["false"], rec["items"])
        llm_points.append(pt)
        L.append(f"| LLM judge: {name} | - | {rec['hit']:.3f} | {rec['false']:.0%} | - |")
    summary["frontier"] = dict(rerankers=frontier, llm=llm_points)

json.dump(summary, open(os.path.join(WORK, "hosted.json"), "w"), indent=1, default=float)
open(os.path.join(WORK, "hosted.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
