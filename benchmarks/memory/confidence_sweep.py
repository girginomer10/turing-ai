#!/usr/bin/env python3
"""Free re-analysis of the stored Smart-memory judge answers (work/llm/B/*.jsonl, no API calls): what happens to
'answer selected' and to false injection on unanswerable queries if the app keeps only entries whose confidence is
at least a selection bar? The prompt asks for >= 0.75; bars above it are a post-filter in the decoder, so a higher bar can
only remove selections: false injection cannot rise and answers selected cannot rise, by construction. The question is
the size of the trade.

Rule fixed before looking at TEST: the highest bar in the grid at which no judge loses more than 2 points of
answers selected on the DEV personas (p1,p3,p5,p7), relative to 0.75. TEST personas (p2,p4,p6,p8) report it.
All six judges are scored. First attempts only, provider errors excluded. Answers rejected by the strict decoder are re-read
with the tolerant decoder from their stored text (truncated to 400 characters; undecodable ones are left out and counted).
Output: work/confidence_sweep.md. Run: python3 confidence_sweep.py"""
import glob, json, os, re, uuid

HERE = os.path.dirname(os.path.abspath(__file__)); WORK = os.path.join(HERE, "work")
ds = json.load(open(os.path.join(WORK, "dataset.json"))); Q, items = ds["queries"], ds["items"]
idx = {it["id"]: k for k, it in enumerate(items)}
gold = [{idx[g] for g in q["gold"]} for q in Q]
DEV = {"p1", "p3", "p5", "p7"}
BARS = [0.75, 0.80, 0.85, 0.90, 0.95]


def pseudo(item_id):
    return str(uuid.uuid5(uuid.UUID("5d1d6e4a-79d1-4a63-8c33-0e0d0c6f9a11"), item_id)).upper()


def tolerant(raw, allowed):
    """hosted_eval.tolerant, but returning every known entry with its confidence (the 0.75 floor is applied here)."""
    text = re.sub(r"^```(?:json)?", "", (raw or "").strip()).strip()
    start = min([i for i in (text.find("{"), text.find("[")) if i >= 0], default=-1)
    if start < 0: return None
    try: value, _ = json.JSONDecoder().raw_decode(text[start:])
    except ValueError: return None
    rel = value.get("relevant") if isinstance(value, dict) else value
    if not isinstance(rel, list): return None
    picked, unknown, below = {}, 0, 0
    for e in rel:
        if not (isinstance(e, dict) and isinstance(e.get("id"), str) and isinstance(e.get("confidence"), (int, float))): return None
        if e["id"] not in allowed: unknown += 1; continue
        if not 0.75 <= e["confidence"] <= 1: below += 1; continue
        picked[e["id"]] = max(picked.get(e["id"], 0), e["confidence"])
    if not picked and unknown > 0 and below == 0: return None
    return picked


def load(f):
    first = {}
    for line in open(f):
        r = json.loads(line); first.setdefault(r["q"], r)
    out, dropped = {}, 0
    for q, r in first.items():
        if r.get("error"): continue
        if r["valid"]:
            out[q] = [(i, c) for i, c in r["selected"]]
        else:
            allowed = {pseudo(items[k]["id"]): k for k in r["candidates"]}
            t = tolerant(r.get("raw"), set(allowed))
            if t is None: dropped += 1; continue
            out[q] = [(allowed[k], c) for k, c in t.items()]
    return out, dropped


def stats(sel, keep, bar):
    ans = [q for q in sel if gold[q] and keep(q)]; un = [q for q in sel if not gold[q] and keep(q)]
    hit = sum(1 for q in ans if gold[q] & {i for i, c in sel[q] if c >= bar})
    fa = sum(1 for q in un if any(c >= bar for _, c in sel[q]))
    return hit, len(ans), fa, len(un)


judges = {os.path.basename(f)[:-6]: load(f) for f in sorted(glob.glob(os.path.join(WORK, "llm", "B", "*.jsonl")))}
parts = {"DEV": lambda q: Q[q]["persona"] in DEV, "TEST": lambda q: Q[q]["persona"] not in DEV}
L = ["# Confidence-bar sweep on stored Smart-memory answers (embedding pool, setting B, all six judges, tolerant decoding)", "",
     "Cells: answer selected / unanswerable queries with anything selected (k/n). A higher bar can only remove selections, by construction.", ""]
loss = {b: 0.0 for b in BARS}
for part, keep in parts.items():
    L += [f"## {part} personas", "", "| judge | " + " | ".join(f"bar {b:.2f}" for b in BARS) + " | undecodable answers left out |", "|---|" + "---|" * (len(BARS) + 1)]
    for name, (sel, dropped) in judges.items():
        cells = []
        base_hit = None
        for b in BARS:
            h, na, fa, nu = stats(sel, keep, b)
            base_hit = h / na if base_hit is None else base_hit
            cells.append(f"{h / na:.3f} / {fa / nu:.0%} ({fa}/{nu})")
            if part == "DEV": loss[b] = max(loss[b], base_hit - h / na)
        L.append(f"| {name} | " + " | ".join(cells) + f" | {dropped} |")
    L.append("")
chosen = max(b for b in BARS if loss[b] <= 0.02 + 1e-9)
L += [f"DEV rule (largest answer-selected loss of any judge, relative to 0.75): " + ", ".join(f"{b:.2f}: {loss[b]:.3f}" for b in BARS) + f". Highest bar within 2 points: **{chosen:.2f}**.", ""]
L += ["## Pooled over the six judges, TEST personas", "", "| bar | answers selected | unanswerable (judge, query) pairs with anything selected |", "|---|---|---|"]
for b in BARS:
    H = NA = FA = NU = 0
    for name, (sel, _) in judges.items():
        h, na, fa, nu = stats(sel, parts["TEST"], b); H += h; NA += na; FA += fa; NU += nu
    L.append(f"| {b:.2f} | {H / NA:.3f} ({H}/{NA}) | {FA / NU:.0%} ({FA}/{NU}) |")
open(os.path.join(WORK, "confidence_sweep.md"), "w").write("\n".join(L) + "\n"); print("\n".join(L))
