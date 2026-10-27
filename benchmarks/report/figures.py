#!/usr/bin/env python3
"""Draw every figure of the report from the benchmark result files (benchmarks/memory/work). Run: python3 figures.py"""
import json, os, sys, textwrap
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

HERE = os.path.dirname(os.path.abspath(__file__))
MEM = os.path.join(HERE, "..", "memory")
WORK = os.path.join(MEM, "work")
OUT = os.path.join(HERE, "figs")
os.makedirs(OUT, exist_ok=True)
sys.path.insert(0, MEM)
import prepare  # noqa: E402  (token-overlap helper used for the dataset figure)

CI = "#ffb703"
NAVY, TEAL, ORANGE, RED, GREY, LIGHT, GOLD, PURPLE = "#1b3a5c", "#2a9d8f", "#e76f51", "#c0392b", "#9aa5b1", "#e8edf2", "#e9c46a", "#7d5ba6"
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9, "axes.spines.top": False, "axes.spines.right": False,
                     "axes.edgecolor": "#55606c", "axes.labelcolor": "#2b3440", "xtick.color": "#2b3440", "ytick.color": "#2b3440",
                     "axes.titleweight": "bold", "axes.titlesize": 10.5, "figure.dpi": 100})

ds = json.load(open(os.path.join(WORK, "dataset.json")))
queries, items, personas = ds["queries"], ds["items"], ds["personas"]
nq = len(queries)
persona = np.array([q["persona"] for q in queries]); qtype = np.array([q["type"] for q in queries])
answerable = qtype != "unanswerable"
gold_idx = np.array([next((k for k, it in enumerate(items) if it["id"] == q["gold"][0]), -1) if q["gold"] else -1 for q in queries])
rng = np.random.default_rng(20261101)
B = 3000


def load(name): return json.load(open(os.path.join(WORK, name)))
ALL = load("results.allmodels.json")["stores"]["per-persona"]
MODELS = load("results.models.json")["stores"]["per-persona"]
PIPE_L = load("results.pipeline.json")["stores"]["per-persona"]
PIPE_H = load("results.pipelinehosted.json")["stores"]["per-persona"]
HOSTFS = load("results.hostedfusions.json")["stores"]["per-persona"]
rr = lambda r: np.where(np.asarray(r, dtype=float) > 0, 1.0 / np.maximum(np.asarray(r, dtype=float), 1), 0.0)


def groups(mask): return [np.where(mask & (persona == p))[0] for p in personas if (mask & (persona == p)).any()]
AG = groups(answerable)
IDX = np.concatenate(AG)
DRAWS = []
for _ in range(B):
    pick = rng.integers(0, len(AG), size=len(AG))
    DRAWS.append(np.concatenate([rng.choice(AG[k], size=len(AG[k]), replace=True) for k in pick]))


def mrr_ci(ranks):
    x = rr(ranks)
    m = np.array([x[d].mean() for d in DRAWS])
    return float(x[IDX].mean()), float(np.percentile(m, 2.5)), float(np.percentile(m, 97.5))


def save(fig, name):
    fig.savefig(os.path.join(OUT, name), dpi=200, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print("wrote", name)


NAMES = {
    "voyage-4-large": "Voyage-4-large", "di-nemotron-embed-8b-qp": "Nemotron-Embed-8B (+prefixes)", "voyage-4": "Voyage-4",
    "or-pplx-embed-4b": "Perplexity pplx-embed-4B", "voyage-4-lite": "Voyage-4-lite", "arctic-embed-l-v2": "Snowflake Arctic Embed L v2",
    "di-qwen3-emb-8b": "Qwen3-Embedding-8B", "di-embeddinggemma-300m": "EmbeddingGemma-300M (full precision)",
    "embeddinggemma-300m": "EmbeddingGemma-300M (8-bit, local)", "or-gemini-embedding-2": "Gemini embedding-2", "voyage-3-large": "Voyage-3-large",
    "openai-3-large": "OpenAI text-embedding-3-large", "cohere-embed-v4": "Cohere embed-v4.0", "di-nemotron-embed-8b": "Nemotron-Embed-8B (raw text)",
    "or-gemini-embedding-001": "Gemini embedding-001", "nomic-v2-moe": "nomic-embed v2 MoE", "qwen3-emb-4b": "Qwen3-Embedding-4B",
    "bge-m3": "bge-m3 (8-bit, local)", "di-bge-m3": "bge-m3 (full precision)", "di-embeddinggemma-2": "embeddinggemma-2",
    "qwen3-emb-0.6b": "Qwen3-Embedding-0.6B", "openai-3-small": "OpenAI text-embedding-3-small", "e5-large-instruct": "multilingual-e5-large-instruct",
    "or-mistral-embed": "Mistral embed", "nomic-v1.5": "nomic-embed v1.5", "local-only": "Lexical search only (no embeddings)"}
LOCAL = {"arctic-embed-l-v2", "embeddinggemma-300m", "nomic-v2-moe", "qwen3-emb-4b", "bge-m3", "qwen3-emb-0.6b", "e5-large-instruct", "nomic-v1.5"}


# ---------------------------------------------------------------- 1. architecture
def fig_architecture():
    fig, ax = plt.subplots(figsize=(10.2, 4.3))
    ax.set_xlim(0, 100); ax.set_ylim(0, 44); ax.axis("off")

    def box(x, y, w, h, title, body, fc, ec, tc=NAVY):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.4,rounding_size=1.6", fc=fc, ec=ec, lw=1.4))
        ax.text(x + w / 2, y + h - 2.2, title, ha="center", va="top", fontsize=9.3, fontweight="bold", color=tc)
        ax.text(x + w / 2, y + h - 6.2, body, ha="center", va="top", fontsize=7.6, color="#2b3440", linespacing=1.35)

    def arrow(x1, y1, x2, y2, color=NAVY, style="-|>"):
        ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style, mutation_scale=13, color=color, lw=1.6, shrinkA=1, shrinkB=1))

    ax.add_patch(FancyBboxPatch((0.5, 36.2), 99, 6.6, boxstyle="round,pad=0.3,rounding_size=1.2", fc=LIGHT, ec="none"))
    ax.text(50, 41.0, "On the device:  lasting facts  ·  dated events  ·  chat messages  ·  imported documents", ha="center", va="center", fontsize=8.6, color=NAVY, fontweight="bold")
    ax.text(50, 38.1, "keys in the Keychain  ·  vectors rebuildable  ·  nothing leaves the device except what a model call needs", ha="center", va="center", fontsize=7.6, color="#55606c")
    box(1, 14, 16, 16, "Question", "typed in Turkish\nor English,\nto any chat provider", "#ffffff", NAVY)
    box(22, 8, 24, 24, "1  First stage", "lexical search (BM25 + hashing)\n+ one or more embedding models\nscores blended per query\n(min-max cosine, rank fusion)\n\ntop 20 candidates", "#eaf4f2", TEAL, TEAL)
    box(51, 19, 25, 14, "2a  Reranker", "a cross-encoder reads the question\nwith each candidate; its probability\npicks what is injected", "#fdf0ec", ORANGE, ORANGE)
    box(51, 2, 25, 14, "2b  LLM judge", "(the app's Smart memory) a chat\nmodel returns the IDs that help,\nor none at all", "#fbeceb", RED, RED)
    box(80.2, 12, 19, 18, "Injected", "at most 6 memories,\nlabelled as untrusted data,\ninto the chat model\nthe user picked", "#ffffff", NAVY)
    arrow(17.4, 22, 21.6, 22); arrow(46.4, 27, 50.6, 27, TEAL); arrow(46.4, 14, 50.6, 10, TEAL)
    arrow(76.4, 26, 79.6, 24, ORANGE); arrow(76.4, 9, 79.6, 17, RED)
    ax.text(50, 0.4, "Both second stages are optional; either can fall back to the first stage if a provider fails.", ha="center", fontsize=7.4, style="italic", color="#55606c")
    save(fig, "f1_architecture.png")


# ---------------------------------------------------------------- 2. dataset
def fig_dataset():
    fig, axes = plt.subplots(1, 4, figsize=(10.4, 3.1), gridspec_kw={"width_ratios": [1.15, 1, 0.8, 1.1]})
    types = [("direct", "direct"), ("paraphrase", "paraphrase"), ("cross_lingual", "cross-lingual"), ("hard_negative", "hard negative"), ("unanswerable", "unanswerable")]
    cols = [TEAL, NAVY, ORANGE, PURPLE, GREY]
    counts = [int((qtype == t).sum()) for t, _ in types]
    ax = axes[0]
    ax.barh([l for _, l in types][::-1], counts[::-1], color=cols[::-1])
    for i, c in enumerate(counts[::-1]): ax.text(c + 1.5, i, str(c), va="center", fontsize=8)
    ax.set_title("360 queries"); ax.set_xlim(0, 118)
    kinds = ["topic", "event", "message", "document"]
    kc = [sum(1 for it in items if it["kind"] == k) for k in kinds]
    ax = axes[1]
    ax.barh(["lasting fact", "dated event", "chat message", "document chunk"][::-1], kc[::-1], color=[NAVY, TEAL, GOLD, PURPLE][::-1])
    for i, c in enumerate(kc[::-1]): ax.text(c + 3, i, str(c), va="center", fontsize=8)
    ax.set_title("560 stored items"); ax.set_xlim(0, 255)
    langs = [("tr", "Turkish"), ("en", "English"), ("mixed", "code-switched")]
    lc = [sum(1 for it in items if it["lang"] == k) for k, _ in langs]
    ax = axes[2]
    ax.pie(lc, labels=[f"{n}\n{c}" for (_, n), c in zip(langs, lc)], colors=[ORANGE, NAVY, GREY], startangle=90, wedgeprops=dict(width=0.45, edgecolor="white"), textprops=dict(fontsize=7.8), labeldistance=1.22)
    ax.set_title("item language", pad=22)
    byid = {it["id"]: it for it in items}
    ov = {}
    for t, _ in types[:4]:
        vals = []
        for q in queries:
            if q["type"] == t:
                g_ = byid[q["gold"][0]]
                a_, b_ = prepare.stems(q["text"]), prepare.stems(g_["text"] + " " + g_.get("title", ""))
                vals.append(len(a_ & b_) / max(1, len(a_ | b_)))
        ov[t] = float(np.mean(vals))
    ax = axes[3]
    ax.barh([l for _, l in types[:4]][::-1], [ov[t] for t, _ in types[:4]][::-1], color=cols[:4][::-1])
    for i, t in enumerate([t for t, _ in types[:4]][::-1]): ax.text(ov[t] + 0.005, i, f"{ov[t]:.3f}", va="center", fontsize=8)
    ax.set_title("word overlap with the answer"); ax.set_xlim(0, 0.27); ax.set_xlabel("mean Jaccard (lower = harder to keyword-match)", fontsize=7.4)
    fig.tight_layout(w_pad=1.2)
    save(fig, "f2_dataset.png")


# ---------------------------------------------------------------- 3. leaderboard
def fig_leaderboard():
    rows = []
    for c, v in ALL.items():
        m, lo, hi = mrr_ci(v["rank"])
        rows.append((m, lo, hi, c))
    rows.sort()
    fig, ax = plt.subplots(figsize=(9.2, 8.2))
    for i, (m, lo, hi, c) in enumerate(rows):
        color = GREY if c == "local-only" else (TEAL if c in LOCAL else NAVY)
        ax.barh(i, m, color=color, height=0.72, alpha=0.95)
        ax.plot([lo, hi], [i, i], color=CI, lw=2.0, marker="|", ms=6, mew=1.6, zorder=4)
        ax.text(min(hi + 0.006, 1.03), i, f"{m:.3f}", va="center", fontsize=7.6, fontweight="bold", color="#2b3440")
    ax.set_yticks(range(len(rows))); ax.set_yticklabels([NAMES.get(c, c) for *_, c in rows], fontsize=7.7)
    ax.set_xlim(0, 1.09); ax.set_xlabel("MRR@10 on the personal-memory benchmark (304 answerable queries; amber bar = 95% bootstrap CI)")
    ax.axvline(rows[[c for *_, c in rows].index("local-only")][0], color=GREY, ls="--", lw=0.9)
    ax.grid(axis="x", alpha=0.25)
    from matplotlib.patches import Patch
    ax.legend(handles=[Patch(color=NAVY, label="hosted (API)"), Patch(color=TEAL, label="local, 8-bit GGUF"), Patch(color=GREY, label="no embeddings")], loc="lower right", fontsize=8, frameon=False)
    ax.set_title("25 embedding configurations, same retriever, same queries")
    save(fig, "f3_leaderboard.png")


# ---------------------------------------------------------------- 4. cross-lingual scatter
def fig_crossling():
    pts = {}
    for c, v in ALL.items():
        x = rr(v["rank"])
        pts[c] = (x[answerable & (qtype != "cross_lingual")].mean(), x[answerable & (qtype == "cross_lingual")].mean())
    fig, ax = plt.subplots(figsize=(4.9, 4.3))
    ax.plot([0, 1], [0, 1], color=GREY, ls="--", lw=0.9)
    ax.text(0.295, 0.36, "no penalty", fontsize=7, color=GREY, rotation=33)
    for c, (mono, cross) in pts.items():
        color = GREY if c == "local-only" else (TEAL if c in LOCAL else NAVY)
        ax.scatter(mono, cross, s=36, color=color, zorder=3, edgecolor="white", lw=0.6)
    # labels live in the empty left/top area and point at their dots
    targets = {"voyage-4-large": (0.62, 0.97), "di-nemotron-embed-8b-qp": (0.40, 0.89), "or-pplx-embed-4b": (0.40, 0.82), "arctic-embed-l-v2": (0.40, 0.75),
               "cohere-embed-v4": (0.40, 0.68), "openai-3-large": (0.40, 0.61), "qwen3-emb-0.6b": (0.40, 0.54), "openai-3-small": (0.40, 0.47), "e5-large-instruct": (0.40, 0.40),
               "or-mistral-embed": (0.40, 0.27), "nomic-v1.5": (0.50, 0.15), "local-only": (0.36, 0.03)}
    for c, (tx, ty) in targets.items():
        mono, cross = pts[c]
        ax.annotate(NAMES[c].replace(" (8-bit, local)", "").replace(" (+prefixes)", " (+prefixes)").replace("OpenAI text-embedding-", "OpenAI ").replace("Lexical search only (no embeddings)", "Lexical only"),
                    (mono, cross), xytext=(tx, ty), textcoords="data", fontsize=7.2, ha="left", va="center", color="#2b3440",
                    arrowprops=dict(arrowstyle="-", color="#9aa5b1", lw=0.6, shrinkA=1, shrinkB=3))
    ax.set_xlim(0.28, 1.0); ax.set_ylim(-0.02, 1.02)
    from matplotlib.patches import Patch
    ax.legend(handles=[Patch(color=NAVY, label="hosted"), Patch(color=TEAL, label="local 8-bit"), Patch(color=GREY, label="lexical only")], loc="lower right", fontsize=7.4, frameon=False)
    ax.text(0.995, 0.34, "12 of 25 configurations labelled;\nx-axis starts at 0.28", fontsize=6.6, color="#55606c", ha="right")
    ax.set_xlabel("MRR@10, queries in the same language as the memory"); ax.set_ylabel("MRR@10, queries in the other language")
    ax.set_title("What separates the models: crossing languages"); ax.grid(alpha=0.25)
    save(fig, "f4_crossling.png")


# ---------------------------------------------------------------- 5. prefixes
def fig_prefix():
    pref = load("models.json")["prefix"]
    order = sorted(pref, key=lambda m: -pref[m]["delta"])
    nice = {"embeddinggemma-300m": "EmbeddingGemma-300M", "arctic-embed-l-v2": "Arctic Embed L v2", "e5-large-instruct": "multilingual-e5-large-instruct",
            "qwen3-emb-0.6b": "Qwen3-Embedding-0.6B", "nomic-v2-moe": "nomic-embed v2 MoE", "nomic-v1.5": "nomic-embed v1.5"}
    rows = [(nice[m], pref[m]["raw"], pref[m]["formatted"], pref[m]["delta"], pref[m]["ci"]) for m in order]
    h = load("hosted.json")["leaderboard"]
    rows.insert(2, ("Nemotron-Embed-8B", h["di-nemotron-embed-8b"]["mrr"], h["di-nemotron-embed-8b-qp"]["mrr"], h["di-nemotron-embed-8b-qp"]["mrr"] - h["di-nemotron-embed-8b"]["mrr"], None))
    rows.sort(key=lambda r: -r[3])
    fig, ax = plt.subplots(figsize=(4.9, 4.3))
    for i, (n, raw, fm, d, ci) in enumerate(rows[::-1]):
        sure = ci is None or ci[0] > 0          # Nemotron has no interval; the others are coloured only when their CI excludes 0
        ax.plot([raw, fm], [i, i], color=TEAL if sure and d > 0.02 else GREY, lw=3, solid_capstyle="round", zorder=2)
        ax.scatter(raw, i, s=40, color="white", edgecolor=GREY, lw=1.4, zorder=3)
        ax.scatter(fm, i, s=46, color="#1f2933", zorder=3)
        ax.text(fm + 0.012, i, f"{d:+.3f}" + ("*" if ci is None else ""), va="center", fontsize=8, fontweight="bold", color=TEAL if sure and d > 0.02 else "#55606c")
    ax.set_yticks(range(len(rows))); ax.set_yticklabels([r[0] for r in rows[::-1]], fontsize=8)
    ax.set_xlim(0.5, 0.97); ax.set_xlabel("MRR@10, axis starts at 0.5   (○ raw text → ● formatted per model card)\nteal = interval excludes 0; * = no interval computed", fontsize=7.8)
    ax.set_title("Input format: raw text vs model-card prefixes"); ax.grid(axis="x", alpha=0.25)
    save(fig, "f5_prefix.png")


# ---------------------------------------------------------------- 6. event fade
def fig_fade():
    f = load("fade.json")
    rows = {r["name"]: r for r in f["rows"]}
    legacy, none, chosen = rows["legacy 14d/floor .15"], rows["14d/floor 1"], rows[f["chosen"]]
    fig, axes = plt.subplots(1, 2, figsize=(10.2, 3.6), gridspec_kw={"width_ratios": [1, 1.1]})
    ax = axes[0]
    age = np.linspace(0, 400, 400)
    ax.plot(age, np.maximum(0.15, 0.5 ** (age / 14)), color=RED, lw=2.2, label="before: 14-day half-life, floor 0.15")
    ax.plot(age, np.maximum(0.4, 0.5 ** (age / 45)), color=TEAL, lw=2.2, label="now: 45-day half-life, floor 0.4")
    ax.axhline(0.85, color=TEAL, ls=":", lw=1.4); ax.text(402, 0.855, "events already in the top 3\nare shielded at 0.85", fontsize=7.2, color=TEAL, ha="right", va="bottom")
    ax.axvline(30, color=GREY, ls="--", lw=0.8); ax.text(34, 0.97, "a month old", fontsize=7.4, color="#55606c", va="top")
    ax.set_xlabel("age of the event (days)"); ax.set_ylabel("ranking weight"); ax.set_ylim(0, 1.05)
    ax.set_title("How much an old event is discounted"); ax.legend(fontsize=7.6, frameon=False, loc="upper right", bbox_to_anchor=(1, 0.8)); ax.grid(alpha=0.25)
    ax = axes[1]
    shifts = ["as stored", "+30 days", "+90 days", "+365 days"]
    for r, color, lab, ls in ((legacy, RED, "before (14 d / 0.15)", "-"), (chosen, TEAL, "now (45 d / 0.4 + shield)", "-"), (none, GREY, "no fading at all", "--")):
        ax.plot(range(4), r["ev_test"], marker="o", color=color, lw=2.2, ls=ls, label=lab)
        ax.text(3.06, r["ev_test"][3], f"{r['ev_test'][3]:.2f}", fontsize=8, color=color, va="center")
    ax.set_xticks(range(4)); ax.set_xticklabels(shifts); ax.set_ylim(0, 1.0); ax.set_xlim(-0.2, 3.5)
    ax.set_ylabel("MRR@10 when the answer is an event"); ax.set_xlabel("every event made older by (counterfactual aging, held-out personas)")
    ax.set_title("Finding an event again"); ax.legend(fontsize=7.6, frameon=False, loc="center right"); ax.grid(alpha=0.25)
    fig.tight_layout(w_pad=2)
    save(fig, "f6_fade.png")


# ---------------------------------------------------------------- 7. rerankers
def rerank_rr(name, tag, first_stage_key):
    cand = HOSTFS[first_stage_key]["candidates"]
    m = np.fromfile(os.path.join(WORK, "rerank", f"{name}@{tag}.f32"), dtype=np.float32).reshape(nq, -1)
    out = np.zeros(nq)
    for q in range(nq):
        c = cand[q][:20]
        if not c: continue
        s = np.where(np.isnan(m[q, c]), -1e9, m[q, c])
        order = np.argsort(-s, kind="stable")
        pos = [i for i, j in enumerate(order) if c[j] == gold_idx[q]]
        if pos and pos[0] < 10: out[q] = pos[0] + 1
    return out


def fig_rerankers():
    fig, axes = plt.subplots(1, 2, figsize=(10.4, 4.2), gridspec_kw={"width_ratios": [1.5, 1]})
    ax = axes[0]
    names = {"voyage-rerank-2.5": "Voyage rerank-2.5", "di-nemotron-rerank-8b": "Nemotron-Rerank-8B", "cohere-rerank-v4-pro": "Cohere rerank-v4.0-pro", "di-qwen3-rerank-8b": "Qwen3-Reranker-8B",
             "voyage-rerank-2.5-lite": "Voyage rerank-2.5-lite", "di-qwen3-rerank-4b": "Qwen3-Reranker-4B", "cohere-rerank-v3.5": "Cohere rerank-v3.5", "di-qwen3-rerank-0.6b": "Qwen3-Reranker-0.6B"}
    rows = [(*mrr_ci(ALL["voyage-4-large"]["rank"]), "Voyage-4-large alone (first stage)")]
    for k, n in names.items():
        rows.append((*mrr_ci(rerank_rr(k, "voyage-4-large", "voyage-4-large")), n))
    base = rows[0][0]
    ordered = sorted(rows, key=lambda r: r[0])
    for i, (m, lo, hi, n) in enumerate(ordered):
        color = GREY if "alone" in n else (ORANGE if m < base else NAVY)
        ax.plot([lo, hi], [i, i], color=color, lw=3.2, alpha=0.55, solid_capstyle="round", zorder=2)
        ax.scatter(m, i, s=62, color=color, zorder=3, edgecolor="white", lw=0.8)
        ax.text(max(hi, m) + 0.006, i, f"{m:.3f}", va="center", fontsize=8, fontweight="bold")
    ax.axvline(base, color=GREY, ls="--", lw=0.9)
    ax.set_yticks(range(len(ordered))); ax.set_yticklabels([r[3] for r in ordered], fontsize=8)
    ax.set_xlim(0.80, 1.03); ax.set_ylim(-0.6, len(ordered) - 0.4)
    ax.set_xlabel("MRR@10 (dot) with 95% CI (line); the axis starts at 0.80", fontsize=8.4); ax.grid(axis="x", alpha=0.25)
    ax.set_title("Hosted: rerank Voyage-4-large's top 20")
    ax = axes[1]
    FS = "embeddinggemma-300m+arctic-embed-l-v2"
    stages = [("first stage\n(Gemma +\nArctic)", PIPE_L[FS]["rank"], GREY),
              ("+ Qwen3-\nReranker\n0.6B", PIPE_L[f"{FS}>>qwen3-rerank-0.6b@{FS}~0"]["rank"], ORANGE),
              ("+ bge-\nreranker\nv2-m3", PIPE_L[f"{FS}>>bge-reranker-v2-m3@{FS}~0"]["rank"], NAVY),
              ("+ Qwen3-\nReranker\n4B", PIPE_L[f"{FS}>>qwen3-rerank-4b@{FS}~0"]["rank"], TEAL)]
    for i, (n, r, color) in enumerate(stages):
        m, lo, hi = mrr_ci(r)
        ax.plot([i, i], [lo, hi], color=color, lw=3.2, alpha=0.55, solid_capstyle="round", zorder=2)
        ax.scatter(i, m, s=70, color=color, zorder=3, edgecolor="white", lw=0.8)
        ax.text(i + 0.12, m, f"{m:.3f}", fontsize=8, fontweight="bold", va="center")
    ax.axhline(mrr_ci(PIPE_L[FS]["rank"])[0], color=GREY, ls="--", lw=0.9)
    ax.set_xticks(range(4)); ax.set_xticklabels([s_[0] for s_ in stages], fontsize=7.2); ax.set_ylim(0.78, 1.0); ax.set_xlim(-0.4, 3.7)
    ax.set_ylabel("MRR@10 (axis starts at 0.78)", fontsize=8.4); ax.set_title("Local: open-weight rerankers"); ax.grid(axis="y", alpha=0.25)
    fig.tight_layout(w_pad=2)
    save(fig, "f7_rerankers.png")


# ---------------------------------------------------------------- 8. abstention frontier
def fig_abstention():
    fr = load("hosted.json")["frontier"]
    fig, ax = plt.subplots(figsize=(8.4, 5.0))
    series = {}
    for name, tau, gold, false, items_ in fr["rerankers"]:
        if name in ("cohere-rerank-v3.5", "di-qwen3-rerank-4b"):  # steep curves that add clutter; their numbers are in the tables
            continue
        series.setdefault(name, []).append((false * 100, gold * 100))
    colors = {"voyage-rerank-2.5": "#1b6ca8", "di-qwen3-rerank-8b": "#2e8b57", "di-qwen3-rerank-4b": "#8fbc8f", "voyage-rerank-2.5-lite": "#9bbfdc", "cohere-rerank-v4-pro": PURPLE, "cohere-rerank-v3.5": "#c3a8dc"}
    nice = {"voyage-rerank-2.5": "Voyage rerank-2.5", "di-qwen3-rerank-8b": "Qwen3-Reranker-8B", "di-qwen3-rerank-4b": "Qwen3-Reranker-4B", "voyage-rerank-2.5-lite": "Voyage rerank-2.5-lite",
            "cohere-rerank-v4-pro": "Cohere rerank-v4.0-pro", "cohere-rerank-v3.5": "Cohere rerank-v3.5"}
    for name, pts in series.items():
        pts.sort()
        ax.plot([p[0] for p in pts], [p[1] for p in pts], "-o", ms=4.2, lw=1.3, color=colors.get(name, "#888"), label=nice.get(name, name) + " (threshold sweep)", alpha=0.95)
    lbl = {"oa_gpt-6-luna": "GPT-6 Luna", "oa_gpt-6.1-sol": "GPT-6.1 Sol", "or_anthropic_claude-haiku-5.5": "Claude Haiku 5.5", "or_anthropic_claude-sonnet-5.5": "Claude Sonnet 5.5",
           "or_google_gemini-3.8-flash": "Gemini 3.8 Flash", "or_qwen_qwen3.8-flash": "Qwen3.8 Flash"}
    pts = {}
    for name, _, gold, false, _ in fr["llm"]:
        pts.setdefault((round(false * 100, 1), round(gold * 100, 1)), []).append(lbl[name])   # judges sharing a point share a label
    offsets = [(-70, 20), (-4, 30), (30, 18), (-30, -34), (24, 36), (-8, 28)]
    for k, ((fx, gy), names_) in enumerate(sorted(pts.items())):
        ax.scatter(fx, gy, marker="*", s=190, color=RED, zorder=5, edgecolor="white", lw=0.5)
        ax.annotate(" / ".join(names_), (fx, gy), textcoords="offset points", xytext=offsets[k % len(offsets)], fontsize=8, color="#7b241c", arrowprops=dict(arrowstyle="-", color=RED, lw=0.6))
    ax.scatter([], [], marker="*", s=140, color=RED, label="LLM judge (the app's Smart memory prompt)")
    ax.set_xlabel("Unanswerable queries where something is still injected (%)"); ax.set_ylabel("Answerable queries whose answer is injected (%)")
    ax.set_xlim(-2, 102); ax.set_ylim(76, 106); ax.set_yticks(range(80, 101, 5)); ax.grid(alpha=0.25)
    ax.legend(fontsize=7.6, loc="lower right", frameon=False)
    ax.set_title("Staying silent when nothing helps: judges vs score thresholds  (up and to the left is better)", fontsize=9.6)
    save(fig, "f8_abstention.png")


# ---------------------------------------------------------------- 9. product fixes
def fig_fixes():
    H = load("hosted.json")["llm"]
    fig, axes = plt.subplots(1, 4, figsize=(11.2, 3.5))
    def pair(ax, labels, vals, colors, title, ylim=(0, 1.15), fmt="{:.3f}"):
        ax.bar(range(len(vals)), vals, color=colors, width=0.62)
        for i, v in enumerate(vals): ax.text(i, v + 0.018, fmt.format(v), ha="center", fontsize=8, fontweight="bold")
        ax.set_xticks(range(len(vals))); ax.set_xticklabels(labels, fontsize=7.2); ax.set_ylim(*ylim); ax.set_title(title, fontsize=8.6, pad=8); ax.grid(axis="y", alpha=0.25)
        ax.set_yticks([0, 0.2, 0.4, 0.6, 0.8, 1.0])
    # values verified against RESULTS.md (XQuAD macro-MRR@10 TEST; personal-memory MRR@10 all personas; section 6b of the personal-memory results)
    pair(axes[0], ["XQuAD\nbefore", "XQuAD\nnow", "memory\nbefore", "memory\nblend only"], [0.865, 0.950, 0.572, 0.733], [GREY, TEAL, GREY, TEAL], "Score blend: min-max cosine\n(MRR@10, bge-m3 + Qwen3)")
    pair(axes[1], ["event\nbefore", "event\nnow", "other\nbefore", "other\nnow"], [0.480, 0.836, 0.818, 0.810], [GREY, TEAL, GREY, TEAL], "Event fading: answer is an\nevent (others = control)")
    pair(axes[2], ["lexical\ntop 40", "embedding\ntop 20"], [H["A"]["or_google_gemini-3.8-flash"]["coverage"], H["B"]["or_google_gemini-3.8-flash"]["coverage"]], [GREY, TEAL], "Smart memory pool:\nanswer inside the pool", fmt="{:.1%}")
    ax = axes[3]
    labels = ["Sonnet\n(emb.)", "Sonnet\n(lex.)", "Qwen\n(emb.)", "Qwen\n(lex.)"]
    keys = [("B", "or_anthropic_claude-sonnet-5.5"), ("A", "or_anthropic_claude-sonnet-5.5"), ("B", "or_qwen_qwen3.8-flash"), ("A", "or_qwen_qwen3.8-flash")]
    strict = [H[a_][k_]["strict_valid"] for a_, k_ in keys]; tol = [H[a_][k_]["tolerant_valid"] for a_, k_ in keys]
    x = np.arange(4); w = 0.36
    ax.bar(x - w / 2, strict, w, color=GREY, label="strict (before)"); ax.bar(x + w / 2, tol, w, color=TEAL, label="tolerant (now)")
    for i in range(4):
        ax.text(x[i] - w / 2, strict[i] + 0.018, f"{strict[i]:.0%}", ha="center", fontsize=6.4, fontweight="bold"); ax.text(x[i] + w / 2, tol[i] + 0.018, f"{tol[i]:.0%}", ha="center", fontsize=6.4, fontweight="bold")
    ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=7.2); ax.set_ylim(0, 1.3); ax.set_yticks([0, 0.2, 0.4, 0.6, 0.8, 1.0])
    ax.set_title("Smart memory answers accepted\n(first attempt, provider errors excluded)", fontsize=8.6, pad=8); ax.legend(fontsize=7, frameon=False, loc="upper center", ncol=2); ax.grid(axis="y", alpha=0.25)
    fig.tight_layout(w_pad=1.6)
    save(fig, "f9_fixes.png")


# ---------------------------------------------------------------- 10. ladder
def fig_ladder():
    FS = "embeddinggemma-300m+arctic-embed-l-v2"
    stages = [("Lexical search only", ALL["local-only"]["rank"], GREY),
              ("nomic-embed v1.5\n(the Tinfoil preset's default)", ALL["nomic-v1.5"]["rank"], GREY),
              ("bge-m3 + Qwen3-0.6B fused\n(earlier model pair)", MODELS["bge-m3+qwen3-emb-0.6b"]["rank"], GREY),
              ("Snowflake Arctic v2\n(local, 8-bit)", ALL["arctic-embed-l-v2"]["rank"], TEAL),
              ("Gemma + Arctic → Qwen3-Reranker-4B\n(fully local pipeline)", PIPE_L[f"{FS}>>qwen3-rerank-4b@{FS}~0"]["rank"], TEAL),
              ("Voyage-4-large\n(hosted)", ALL["voyage-4-large"]["rank"], NAVY),
              ("Voyage-4-large → Voyage rerank-2.5\n(hosted pipeline)", PIPE_H["voyage-4-large>>voyage-rerank-2.5@voyage-4-large~0"]["rank"], NAVY)]
    fig, ax = plt.subplots(figsize=(9.2, 4.6))
    for i, (lab, r, color) in enumerate(stages[::-1]):
        m, lo, hi = mrr_ci(r)
        ax.barh(i, m, color=color, height=0.68)
        ax.plot([lo, hi], [i, i], color=CI, lw=2.0, marker="|", ms=6, mew=1.6, zorder=4)
        ax.text(min(hi + 0.008, 1.04), i, f"{m:.3f}", va="center", fontsize=9, fontweight="bold")
    ax.set_yticks(range(len(stages))); ax.set_yticklabels([s[0] for s in stages[::-1]], fontsize=8)
    ax.set_xlim(0, 1.1); ax.set_xlabel("MRR@10 over the 304 answerable queries of the personal-memory benchmark (8 personas; amber = 95% bootstrap CI)")
    from matplotlib.patches import Patch
    ax.legend(handles=[Patch(color=GREY, label="baseline / earlier setup"), Patch(color=TEAL, label="local (8-bit, on-device)"), Patch(color=NAVY, label="hosted (API)")], loc="upper right", fontsize=8, frameon=False)
    ax.set_title("From keyword search to a reranked multilingual memory pipeline"); ax.grid(axis="x", alpha=0.25)
    save(fig, "f10_ladder.png")


if __name__ == "__main__":
    for fn in (fig_architecture, fig_dataset, fig_leaderboard, fig_crossling, fig_prefix, fig_fade, fig_rerankers, fig_abstention, fig_fixes, fig_ladder):
        fn()
