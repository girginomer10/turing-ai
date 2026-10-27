#!/usr/bin/env python3
"""Sweep event-fade policies with counterfactual aging and pick one on DEV personas, report on TEST personas.

Every event is shifted older by 0/30/90/365 days (text unchanged), so the same queries are asked when the answer is a
fresh event, a month-old event, a quarter-old event, and a year-old event. Lasting topics, messages and documents do
not age. A policy is good if it finds old events without hurting queries whose answer is not an event.
Run from benchmarks/memory after embed.py.  Output: work/fade.md, work/fade.json
"""
import json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
BIN = os.path.join(HERE, "Bench", ".build", "release", "MemoryBench")
CONFIGS = ["local-only", "bge-m3+qwen3-emb-0.6b"]
SHIFTS = [0, 30, 90, 365]
# name -> MB_FADE spec "halfLifeDays:floor:protectedRanks:protectedWeight"
POLICIES = {"legacy 14d/floor .15": "14:0.15"}
for h in (14, 45, 180):
    for f in (0.15, 0.4, 0.7, 1.0):
        if (h, f) != (14, 0.15):
            POLICIES[f"{h}d/floor {f:g}"] = f"{h}:{f}"
for h, f, k, w in ((14, 0.15, 1, 0.85), (14, 0.15, 3, 0.85), (14, 0.15, 3, 0.7), (45, 0.4, 3, 0.85), (14, 0.15, 5, 0.85)):
    POLICIES[f"{h}d/floor {f:g} + shield top-{k} @{w:g}"] = f"{h}:{f}:{k}:{w}"

ds = json.load(open(os.path.join(WORK, "dataset.json")))
queries = ds["queries"]
items = {i["id"]: i for i in ds["items"]}
personas = ds["personas"]
persona = np.array([q["persona"] for q in queries])
answerable = np.array([q["type"] != "unanswerable" for q in queries])
gold_kind = np.array([items[q["gold"][0]]["kind"] if q["gold"] else "-" for q in queries])
DEV = np.isin(persona, personas[0::2])
TEST = ~DEV
event_q = answerable & (gold_kind == "event")
other_q = answerable & (gold_kind != "event")


def run(policy_spec, shift, tag):
    env = dict(os.environ, MB_FADE=policy_spec, MB_EVENT_SHIFT=str(shift), MB_STORES="per-persona", MB_CONFIGS=",".join(CONFIGS))
    subprocess.run([BIN, WORK, tag], env=env, check=True, stdout=subprocess.DEVNULL)
    r = json.load(open(os.path.join(WORK, f"results.{tag}.json")))["stores"]["per-persona"]
    os.remove(os.path.join(WORK, f"results.{tag}.json"))
    return {c: {"rank": np.array(r[c]["rank"]), "inj": np.array(r[c]["injected"])} for c in CONFIGS}


def rr(r): return np.where(r > 0, 1.0 / np.maximum(r, 1), 0.0)


res = {}
for name, spec in POLICIES.items():
    for s in SHIFTS:
        res[(name, s)] = run(spec, s, "fade")
    print("done", name, flush=True)

def mrr(name, shift, cfg, mask, split):
    return rr(res[(name, shift)][cfg]["rank"])[mask & split].mean()

CFG = "bge-m3+qwen3-emb-0.6b"
L = ["# Event fade policy sweep\n",
     f"Config: {CFG}. Events shifted older by {SHIFTS} days (counterfactual aging). Event-answer queries: {int(event_q.sum())} "
     f"(DEV {int((event_q & DEV).sum())}, TEST {int((event_q & TEST).sum())}); other answerable queries: {int(other_q.sum())}.\n",
     "Selection on DEV personas (p1,p3,p5,p7): maximise mean event-query MRR over the four shifts, subject to the other-query MRR "
     "(mean over shifts) not dropping more than 0.01 below the legacy policy. Reported on TEST personas (p2,p4,p6,p8).\n"]
legacy = "legacy 14d/floor .15"
base_other_dev = np.mean([mrr(legacy, s, CFG, other_q, DEV) for s in SHIFTS])
rows = []
for name in POLICIES:
    ev_dev = np.mean([mrr(name, s, CFG, event_q, DEV) for s in SHIFTS])
    ot_dev = np.mean([mrr(name, s, CFG, other_q, DEV) for s in SHIFTS])
    ev_test = [mrr(name, s, CFG, event_q, TEST) for s in SHIFTS]
    ot_test = np.mean([mrr(name, s, CFG, other_q, TEST) for s in SHIFTS])
    rows.append(dict(name=name, ev_dev=ev_dev, ot_dev=ot_dev, ev_test=ev_test, ot_test=ot_test, ok=ot_dev >= base_other_dev - 0.01))
chosen = max((r for r in rows if r["ok"]), key=lambda r: r["ev_dev"])
L.append("| policy | event MRR DEV (mean of shifts) | other MRR DEV | guardrail | " + " | ".join(f"TEST event MRR +{s}d" for s in SHIFTS) + " | TEST other MRR |")
L.append("|---|---|---|---|" + "---|" * (len(SHIFTS) + 1))
for r in sorted(rows, key=lambda r: -r["ev_dev"]):
    mark = " ◀ chosen" if r is chosen else ""
    L.append(f"| {r['name']}{mark} | {r['ev_dev']:.3f} | {r['ot_dev']:.3f} | {'ok' if r['ok'] else 'FAIL'} | " + " | ".join(f"{v:.3f}" for v in r["ev_test"]) + f" | {r['ot_test']:.3f} |")
L.append(f"\nChosen on DEV: **{chosen['name']}** (spec `{POLICIES[chosen['name']]}`).")

# Paired comparison on TEST personas: chosen vs legacy and vs no fade (two-stage bootstrap: persona, then query)
RNG = np.random.default_rng(20261026)
B = 4000


def groups(mask):
    return [np.where(mask & (persona == p))[0] for p in personas if (mask & (persona == p)).any()]


def paired(a, b, mask):
    gs = groups(mask)
    d = a - b
    means = []
    for _ in range(B):
        pick = RNG.integers(0, len(gs), size=len(gs))
        idx = np.concatenate([RNG.choice(gs[k], size=len(gs[k]), replace=True) for k in pick])
        means.append(d[idx].mean())
    lo, hi = np.percentile(means, [2.5, 97.5])
    return d[np.concatenate(gs)].mean(), lo, hi


NOFADE = "14d/floor 1"
L.append("\n## Chosen policy vs legacy and vs no fade, TEST personas, paired (two-stage bootstrap over 4 personas, so intervals are wide)\n")
L.append("| subset | chosen − legacy ΔMRR [95% CI] | chosen − no fade ΔMRR [95% CI] |\n|---|---|---|")
cn = chosen["name"]
for label, mask, shift in [(f"event answers, events aged +{s}d", event_q & TEST, s) for s in SHIFTS] + [(f"other answers, events aged +{s}d", other_q & TEST, s) for s in (0, 365)]:
    a = rr(res[(cn, shift)][CFG]["rank"])
    d1 = paired(a, rr(res[(legacy, shift)][CFG]["rank"]), mask)
    d2 = paired(a, rr(res[(NOFADE, shift)][CFG]["rank"]), mask)
    L.append(f"| {label} | {d1[0]:+.3f} [{d1[1]:+.3f}, {d1[2]:+.3f}] | {d2[0]:+.3f} [{d2[1]:+.3f}, {d2[2]:+.3f}] |")
json.dump(dict(chosen=chosen["name"], spec=POLICIES[chosen["name"]], rows=rows), open(os.path.join(WORK, "fade.json"), "w"), indent=1, default=float)
open(os.path.join(WORK, "fade.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
