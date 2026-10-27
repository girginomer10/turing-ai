#!/usr/bin/env python3
"""Compare blind annotator answers (work/audit/audit_<p>.json) with the authored gold labels."""
import json, os
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
ds = json.load(open(os.path.join(WORK, "dataset.json")))
items = {i["id"]: i for i in ds["items"]}
rows, disagreements = [], []
for p in ds["personas"]:
    audit = json.load(open(os.path.join(WORK, "audit", f"audit_{p}.json")))["answers"]
    for q in (q for q in ds["queries"] if q["persona"] == p):
        a = audit[q["id"]]
        best, also = a["best"], set(a.get("also", []))
        gold = q["gold"][0] if q["gold"] else None
        if gold is None:
            agree = best is None
            kind = "unanswerable-agree" if agree else "unanswerable-annotator-found-answer"
        else:
            agree = best == gold
            kind = "agree" if agree else ("agree-via-also" if gold in also else ("annotator-null" if best is None else "different-item"))
        rows.append((q["id"], q["type"], gold, best, agree, kind, a.get("confidence")))
        if not agree:
            disagreements.append(dict(id=q["id"], type=q["type"], query=q["text"], gold=gold, annotator=best, kind=kind,
                                      gold_text=items[gold]["text"] if gold else None, annotator_text=items[best]["text"] if best else None))
n = len(rows)
exact = sum(r[4] for r in rows)
ans = [r for r in rows if r[2] is not None]
una = [r for r in rows if r[2] is None]
# binary answerable agreement and Cohen's kappa
a_gold = [r[2] is not None for r in rows]
a_ann = [r[3] is not None for r in rows]
po = sum(x == y for x, y in zip(a_gold, a_ann)) / n
pg, pa = sum(a_gold) / n, sum(a_ann) / n
pe = pg * pa + (1 - pg) * (1 - pa)
kappa = (po - pe) / (1 - pe) if pe < 1 else 1.0
L = ["# Blind re-annotation audit\n",
     f"Four independent annotator agents saw each persona's store and queries with no labels and no query types.\n",
     f"* Exact agreement on the answering item: **{exact}/{n} = {exact/n:.1%}**",
     f"* Answerable queries: {sum(r[4] for r in ans)}/{len(ans)} = {sum(r[4] for r in ans)/len(ans):.1%} agree; unanswerable: {sum(r[4] for r in una)}/{len(una)} = {sum(r[4] for r in una)/len(una):.1%} agree",
     f"* Cohen's kappa on answerable-vs-unanswerable: {kappa:.3f}\n",
     "| query type | n | agreement |\n|---|---|---|"]
by = defaultdict(list)
for r in rows: by[r[1]].append(r[4])
for t, v in by.items(): L.append(f"| {t} | {len(v)} | {sum(v)/len(v):.1%} |")
L.append(f"\nDisagreements by kind: {dict(Counter(d['kind'] for d in disagreements))}\n")
json.dump(disagreements, open(os.path.join(WORK, "audit_disagreements.json"), "w"), ensure_ascii=False, indent=1)
open(os.path.join(WORK, "audit.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
for d in disagreements:
    print(f"\n[{d['id']} {d['type']}] {d['query']}\n  GOLD: {d['gold']} {str(d['gold_text'])[:170]}\n  ANN : {d['annotator']} {str(d['annotator_text'])[:170]}")
