#!/usr/bin/env python3
"""Generate seeded worlds, their template-rendered chat archives and the go/no-go question set.

Output per world in work/worlds/w<seed>/: world.json (graph, gold), messages.jsonl (archive; `facts` and
`distractor` fields are gold and must be stripped before anything retrieves over it), sessions.json and
questions.jsonl (gold facts mapped to message ids). work/worlds/summary.json holds the counts and QC checks.

Run from benchmarks/agent:  python3 -I make_worlds.py [--worlds 5] [--messages 2000] [--per-class 10]
"""
import argparse, json, os, sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import questions, render, world  # noqa: E402

OUT = os.path.join(HERE, "work", "worlds")


def qc(w, messages, qs):
    """Structural checks; any failure is a generator bug, not noise."""
    by_fact = Counter(f for m in messages for f in m["facts"])
    problems = []
    for f in w.facts:
        if by_fact[f.id] != 1:
            problems.append(f"fact {f.id} stated {by_fact[f.id]} times")
    ts = [m["ts"] for m in messages]
    if ts != sorted(ts):
        problems.append("messages are not in time order")
    fact_msg = {f: m for m in messages for f in m["facts"]}
    for q in qs:
        for fid in q["gold_facts"]:
            if fid not in fact_msg:
                problems.append(f"question gold fact {fid} has no message")
    # Each versioned attribute must be stated in version order.
    for f in w.facts:
        if f.version > 0:
            prev = next(v for v in w.versions(f.subject, f.attr) if v.version == f.version - 1)
            if fact_msg[prev.id]["ts"] >= fact_msg[f.id]["ts"]:
                problems.append(f"{f.id} stated before its previous version {prev.id}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--worlds", type=int, default=5)
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--messages", type=int, default=2000)
    ap.add_argument("--per-class", type=int, default=10)
    args = ap.parse_args()

    summary = {"worlds": []}
    for seed in range(args.first_seed, args.first_seed + args.worlds):
        w = world.build_world(seed)
        messages, sessions = render.build_archive(w, seed, target_messages=args.messages)
        qs = questions.generate(w, seed, per_class=args.per_class)
        fact_msg = {f: m["id"] for m in messages for f in m["facts"]}
        for i, q in enumerate(qs):
            q["id"] = f"w{seed}-q{i:03d}"
            q["world"] = f"w{seed}"
            q["gold_messages"] = sorted({fact_msg[f] for f in q["gold_facts"]})
            if "stale_facts" in q:
                q["stale_messages"] = sorted({fact_msg[f] for f in q["stale_facts"]})
        problems = qc(w, messages, qs)

        d = os.path.join(OUT, f"w{seed}")
        os.makedirs(d, exist_ok=True)
        json.dump(w.to_json(), open(os.path.join(d, "world.json"), "w"), ensure_ascii=False, indent=1)
        json.dump(sessions, open(os.path.join(d, "sessions.json"), "w"), ensure_ascii=False)
        with open(os.path.join(d, "messages.jsonl"), "w") as fh:
            for m in messages:
                fh.write(json.dumps(m, ensure_ascii=False) + "\n")
        with open(os.path.join(d, "questions.jsonl"), "w") as fh:
            for q in qs:
                fh.write(json.dumps(q, ensure_ascii=False) + "\n")

        fact_sessions = {m["session"] for m in messages if m["facts"]}
        s = {"world": f"w{seed}", "messages": len(messages), "sessions": len(sessions),
             "noise_session_share": round(1 - len(fact_sessions) / len(sessions), 3),
             "fact_messages": sum(1 for m in messages if m["facts"]),
             "distractor_messages": sum(1 for m in messages if m.get("distractor")),
             "facts_by_attr": dict(Counter(f.attr for f in w.facts)),
             "lang": dict(Counter(m["lang"] for m in messages if m["role"] == "user")),
             "questions": dict(Counter(q["class"] for q in qs)),
             "templates": dict(Counter(q["template"] for q in qs)),
             "gold_per_question": dict(Counter(q["class"] + ":" + str(len(q["gold_messages"])) for q in qs)),
             "problems": problems}
        summary["worlds"].append(s)
        print(f"w{seed}: {s['messages']} msgs, {s['sessions']} sessions, {s['fact_messages']} fact msgs, "
              f"questions {s['questions']}, problems {len(problems)}")
        for p in problems[:5]:
            print("   ", p)
    tot = Counter()
    for s in summary["worlds"]:
        tot.update(s["questions"])
    summary["questions_total"] = dict(tot)
    json.dump(summary, open(os.path.join(OUT, "summary.json"), "w"), ensure_ascii=False, indent=1)
    print("total questions:", dict(tot))


if __name__ == "__main__":
    main()
