#!/usr/bin/env python3
"""Tool environment for research agents: search / expand / select / stop over one world's chat archive.

Any agent that can run shell commands can drive it (a prompted LLM now, the trained controller later). The CLI keeps
per-question state on disk, enforces the budget, never prints gold fields, and logs what the agent was shown so cost
can be counted. Search uses the same engine as the single-shot baselines (retrieval.py), so a gap between agent and
baseline comes from the agent's choices, not from a better index.

  python3 -I env.py --run R questions --world w1        list question ids and texts (no gold)
  python3 -I env.py --run R start w1-q003               show the question and the budget
  python3 -I env.py --run R search w1-q003 "query text"
  python3 -I env.py --run R expand w1-q003 m01234
  python3 -I env.py --run R select w1-q003 m01234 m00456
  python3 -I env.py --run R stop w1-q003 --answer "..."
  python3 -I env.py --run R finalize                     -> work/runs/R/packs.jsonl (for score.py)

Budget per question: at most MAX_READS search/expand calls, a pack of at most PACK messages (only ids the agent was
shown), search shows SEARCH_K hits. Selecting is free; stop is final.
"""
import argparse, glob, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import retrieval  # noqa: E402
from baselines import RUNS, load_questions  # noqa: E402

MAX_READS, PACK, SEARCH_K = 8, 8, 5
NOW = "2026-09-30"


def state_path(run, qid):
    return os.path.join(RUNS, run, "state", f"{qid}.json")


def load_state(run, qid):
    p = state_path(run, qid)
    if not os.path.exists(p):
        sys.exit(f"{qid}: not started; run `start {qid}` first")
    return json.load(open(p))


def save_state(run, st):
    p = state_path(run, st["qid"])
    os.makedirs(os.path.dirname(p), exist_ok=True)
    # A unique temporary name: an agent may run two commands for one question at once.
    tmp = f"{p}.{os.getpid()}.tmp"
    json.dump(st, open(tmp, "w"), ensure_ascii=False, indent=1)
    os.replace(tmp, p)


def show(m, prefix=""):
    role = "" if m["role"] == "user" else " (assistant)"
    return f"{prefix}[{m['id']}] {m['ts'][:10]}{role}: {m['text']}"


def question(qid):
    q = next((q for q in load_questions() if q["id"] == qid), None)
    if q is None:
        sys.exit(f"unknown question {qid}")
    return q


def guard(st):
    if st["done"]:
        sys.exit(f"{st['qid']}: already stopped")


def log(st, action, args, shown, rejected=None):
    st["actions"].append({"action": action, "args": args, "shown": [m["id"] for m in shown],
                          "chars": sum(len(m["text"]) for m in shown), "t": round(time.time(), 1),
                          **({"rejected": rejected} if rejected else {})})


def refuse(run, st, action, args, why):
    """Rejected calls are logged too, so a run can be audited from its state files alone."""
    log(st, action, args, [], rejected=why)
    save_state(run, st)
    sys.exit(why)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("questions")
    s.add_argument("--world", required=True)
    for name in ("start", "search", "expand", "select", "stop"):
        p = sub.add_parser(name)
        p.add_argument("qid")
        if name == "search":
            p.add_argument("query")
        if name == "expand":
            p.add_argument("mid")
        if name == "select":
            p.add_argument("mids", nargs="+")
        if name == "stop":
            p.add_argument("--answer", default="")
    sub.add_parser("finalize")
    a = ap.parse_args()

    if a.cmd == "questions":
        for q in load_questions():
            if q["world"] == a.world:
                print(f"{q['id']}\t{q['question']}")
        return

    if a.cmd == "finalize":
        rows = []
        for p in sorted(glob.glob(os.path.join(RUNS, a.run, "state", "*.json"))):
            st = json.load(open(p))
            reads = [x for x in st["actions"] if x["action"] in ("search", "expand") and not x.get("rejected")]
            rows.append({"qid": st["qid"], "pack": st["pack"], "answer": st.get("answer", ""), "done": st["done"],
                         "shown": st["shown"],
                         "cost": {"reads": len(reads), "searches": sum(x["action"] == "search" for x in reads),
                                  "messages_shown": sum(len(x["shown"]) for x in reads),
                                  "chars_shown": sum(x["chars"] for x in reads),
                                  "rejected": sum(bool(x.get("rejected")) for x in st["actions"])}})
        with open(os.path.join(RUNS, a.run, "packs.jsonl"), "w") as fh:
            for r in rows:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(len(rows), "questions;", sum(r["done"] for r in rows), "stopped")
        return

    if a.cmd == "start":
        q = question(a.qid)
        p = state_path(a.run, a.qid)
        st = json.load(open(p)) if os.path.exists(p) else {
            "qid": a.qid, "world": q["world"], "actions": [], "pack": [], "shown": [], "done": False}
        save_state(a.run, st)
        print(f"Question ({a.qid}): {q['question']}\nToday is {NOW}; the archive ends today.\n"
              f"Budget: {MAX_READS - sum(x['action'] in ('search', 'expand') and not x.get('rejected') for x in st['actions'])} search/expand "
              f"calls left, evidence pack of at most {PACK} messages (now {len(st['pack'])}).")
        return

    st = load_state(a.run, a.qid)
    guard(st)
    engine = retrieval.Engine(st["world"])
    reads = sum(x["action"] in ("search", "expand") and not x.get("rejected") for x in st["actions"])

    if a.cmd in ("search", "expand"):
        args_ = [a.query] if a.cmd == "search" else [a.mid]
        if reads >= MAX_READS:
            refuse(a.run, st, a.cmd, args_, f"budget exhausted ({MAX_READS} search/expand calls); select and stop")
        if a.cmd == "search":
            retrieval.check_servers()
            shown = [engine.by_id[i] for i in engine.search(a.query, k=SEARCH_K)]
            log(st, "search", [a.query], shown)
        else:
            if a.mid not in st["shown"]:
                refuse(a.run, st, "expand", [a.mid], f"{a.mid} was not shown to you yet; expand only messages you have seen")
            if any(x["action"] == "expand" and x["args"] == [a.mid] and not x.get("rejected") for x in st["actions"]):
                refuse(a.run, st, "expand", [a.mid], f"{a.mid} is already expanded above; nothing new to show")
            shown = engine.session_neighbours(a.mid)
            log(st, "expand", [a.mid], shown)
        st["shown"] = sorted(set(st["shown"]) | {m["id"] for m in shown if m["role"] == "user"})
        save_state(a.run, st)
        for m in shown:
            print(show(m))
        print(f"-- {MAX_READS - reads - 1} search/expand calls left; pack {len(st['pack'])}/{PACK}")
        return

    if a.cmd == "select":
        # Ids shown in this question are added; the others are named and skipped, not the whole call.
        unseen = [m for m in a.mids if m not in st["shown"]]
        added = [m for m in a.mids if m in st["shown"] and m not in st["pack"]]
        if len(st["pack"]) + len(added) > PACK:
            refuse(a.run, st, "select", a.mids, f"pack would exceed {PACK} messages (now {len(st['pack'])})")
        st["pack"] += added
        log(st, "select", a.mids, [], rejected=f"not shown in this question: {' '.join(unseen)}" if unseen else None)
        save_state(a.run, st)
        if unseen:
            print(f"skipped (not shown in this question, or not a user message): {' '.join(unseen)}")
        print(f"pack {len(st['pack'])}/{PACK}: {' '.join(st['pack'])}")
        return

    if a.cmd == "stop":
        if not st["pack"]:
            print("note: the evidence pack is empty")
        st["done"] = True
        st["answer"] = a.answer
        log(st, "stop", [a.answer], [])
        save_state(a.run, st)
        print(f"stopped with pack {st['pack']}")


if __name__ == "__main__":
    main()
