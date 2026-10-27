#!/usr/bin/env python3
"""Draw the retrieval ladder from work/models.json (written by models_eval.py) -> figures/ladder.png"""
import json, os, textwrap
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
rows = json.load(open(os.path.join(HERE, "work", "models.json")))["ladder"]
os.makedirs(os.path.join(HERE, "figures"), exist_ok=True)
fig, ax = plt.subplots(figsize=(10, 5.2), constrained_layout=True)
rows = rows[::-1]
labels = ["\n".join(textwrap.wrap(r["label"], 46)) for r in rows]
vals = [r["mrr"] for r in rows]
err = [[r["mrr"] - r["lo"] for r in rows], [r["hi"] - r["mrr"] for r in rows]]
colors = ["#2a6f97" if "reranker" in r["label"] else ("#61a5c2" if "best" in r["label"] else "#b0bec5") for r in rows]
ax.barh(labels, vals, xerr=err, color=colors, ecolor="#37474f", capsize=3, height=0.62)
for y, r in enumerate(rows):
    ax.text(min(r["hi"] + 0.012, 1.0), y, f"{r['mrr']:.3f}", va="center", ha="left", fontsize=9.5, color="#263238", fontweight="bold")
ax.set_xlim(0, 1.12)
ax.set_xlabel("MRR@10, synthetic personal-memory benchmark\n(360 queries, 8 personas, 95% bootstrap CI)")
ax.set_title("From keyword search to a reranked multilingual memory pipeline", fontsize=12)
ax.grid(axis="x", alpha=0.25)
for side in ("top", "right"):
    ax.spines[side].set_visible(False)
fig.savefig(os.path.join(HERE, "figures", "ladder.png"), dpi=170)
print("wrote figures/ladder.png")
