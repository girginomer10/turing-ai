#!/usr/bin/env python3
"""Cross-family recoverability check: score Claude's extraction of the same 300 rewritten facts.

Most rewritten text was written by GPT and rewrite_archive_recovery.py extracts with GPT too, so the same 300 sampled
messages (work/rewrite_archive_rw/recovery/batches) were also extracted by Claude subagents reading the day-1
extractor instructions (recovery_claude/instructions.md); their outputs are in recovery_claude/out/. Scoring uses
the day-1 matcher (rewrite.matches) against the unchanged world graphs.

Run from benchmarks/agent:  AGENT_SURFACE=rw python3 -I rewrite_archive_recovery_claude.py
"""
import glob, json, os, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from retrieval import SURFACE, WORLDS  # noqa: E402
from rewrite import matches  # noqa: E402

BASE = os.path.join(HERE, "work", "rewrite_archive_rw")


def main():
    if SURFACE != "rw":
        sys.exit("Use AGENT_SURFACE=rw")
    inputs = {i["id"] for p in glob.glob(os.path.join(BASE, "recovery", "batches", "*.json")) for i in json.load(open(p))}
    got = {}
    for p in sorted(glob.glob(os.path.join(BASE, "recovery_claude", "out", "*.json"))):
        for item in json.load(open(p))["items"]:
            if item["id"] in got:
                sys.exit(f"duplicate id {item['id']}")
            got[item["id"]] = item["facts"]
    if set(got) != inputs:
        sys.exit(f"coverage mismatch: missing {len(inputs - set(got))}, extra {len(set(got) - inputs)}")
    worlds, msgs = {}, {}
    rows = []
    for mid_full, facts in sorted(got.items()):
        w, mid = mid_full.split("/")
        if w not in worlds:
            worlds[w] = json.load(open(os.path.join(WORLDS, w, "world.json")))
            msgs[w] = {m["id"]: m for m in map(json.loads, open(os.path.join(WORLDS, w, "messages.jsonl")))}
        F = {f["id"]: f for f in worlds[w]["facts"]}
        m = msgs[w][mid]
        gold = [F[x] for x in m["facts"]]
        ok = all(any(matches(g, ex, worlds[w]) for ex in facts) for g in gold)
        rows.append({"id": mid_full, "lang": m["lang"], "attr": gold[0]["attr"], "ok": ok})
    out = {"extractor": "claude-sonnet subagents", "n": len(rows),
           "recoverable": round(sum(r["ok"] for r in rows) / len(rows), 3)}
    for key in ("lang", "attr"):
        g = defaultdict(list)
        for r in rows:
            g[r[key]].append(r["ok"])
        out["by_" + key] = {k: {"n": len(v), "recoverable": round(sum(v) / len(v), 3)} for k, v in sorted(g.items())}
    out["failures"] = [r["id"] for r in rows if not r["ok"]]
    json.dump(out, open(os.path.join(BASE, "recovery_claude", "score.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "failures"}, indent=1))
    print("failures:", out["failures"])


if __name__ == "__main__":
    main()
