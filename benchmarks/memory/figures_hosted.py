#!/usr/bin/env python3
"""Plot the abstention frontier from work/hosted.json -> figures/abstention.png"""
import json, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
fr = json.load(open(os.path.join(HERE, "work", "hosted.json")))["frontier"]
fig, ax = plt.subplots(figsize=(8.6, 5.6), constrained_layout=True)
series = {}
for name, tau, gold, false, items in fr["rerankers"]:
    series.setdefault(name, []).append((false * 100, gold * 100, tau))
colors = {"voyage-rerank-2.5": "#1b6ca8", "di-qwen3-rerank-8b": "#2e8b57", "di-qwen3-rerank-4b": "#8fbc8f", "voyage-rerank-2.5-lite": "#9bbfdc", "di-nemotron-rerank-8b": "#b08968", "cohere-rerank-v4-pro": "#8e44ad", "cohere-rerank-v3.5": "#c39bd3"}
for name, pts in series.items():
    pts.sort()
    ax.plot([p[0] for p in pts], [p[1] for p in pts], "-o", ms=4.5, lw=1.2, color=colors.get(name, "#888"), label=f"{name} (threshold sweep)")
offsets = [(-8, 14), (8, 12), (10, -16), (8, -4), (-60, -18), (-30, 22)]
for k, (name, tau, gold, false, items) in enumerate(sorted(fr["llm"], key=lambda r: (r[3], -r[2]))):
    ax.scatter([false * 100], [gold * 100], marker="*", s=170, color="#c0392b", zorder=5)
    short = name.replace("or_", "").replace("oa_", "").replace("anthropic_", "").replace("google_", "").replace("qwen_", "")
    ax.annotate(short, (false * 100, gold * 100), textcoords="offset points", xytext=offsets[k % len(offsets)], fontsize=8, color="#7b241c",
                arrowprops=dict(arrowstyle="-", color="#c0392b", lw=0.6))
ax.scatter([], [], marker="*", s=130, color="#c0392b", label="LLM judge (Smart memory prompt)")
ax.set_xlabel("Unanswerable queries where anything is still injected (%)  ← better")
ax.set_ylabel("Answerable queries whose answer is injected (%)  ↑ better")
ax.set_title("Abstention: LLM judges say 'nothing helps' far better than score thresholds", fontsize=11)
ax.set_xlim(-2, 102); ax.set_ylim(76, 103)
ax.grid(alpha=0.25)
for side in ("top", "right"): ax.spines[side].set_visible(False)
ax.legend(fontsize=8, loc="lower right")
os.makedirs(os.path.join(HERE, "figures"), exist_ok=True)
fig.savefig(os.path.join(HERE, "figures", "abstention.png"), dpi=170)
print("wrote figures/abstention.png")
