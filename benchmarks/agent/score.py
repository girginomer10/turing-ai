#!/usr/bin/env python3
"""Evidence scores for every method in work/runs/: recall of gold messages in the pack, at an equal pack budget.

Per question: recall = |pack ∩ gold| / |gold|; complete = every gold message is in the pack; stale_included = the pack
also holds a superseded version of a latest-value fact (the agent prompt asks for it, so it is not a defect). Per
method and class: means, a bootstrap 95% interval over questions (B = 2000) and, against a reference method (default
(a), the strongest single-shot baseline), the paired difference in recall with its interval.

Agent runs also report: cost (searches, messages and characters shown, rejected calls); shown_recall = gold among
every message the agent was shown (what it found, selected or not); the agent's own answer checked programmatically
against the computed answer (lenient: the right value appears in the answer); and matched_reads = the reference
baseline's recall at a depth equal to the messages the agent was shown (capped at its ranked depth), so "reads more"
and "researches better" can be told apart. Output: work/runs/scores.json and a printed table.

Run from benchmarks/agent:  python3 -I score.py [--ref a_hybrid_rerank] [--budget 8]
"""
import argparse, datetime as dt, glob, json, os, random, re, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from baselines import RUNS, load_questions  # noqa: E402
from render import MONTH_EN, MONTH_TR  # noqa: E402
from retrieval import fold  # noqa: E402

CLASSES = ["latest_value", "two_hop", "aggregate", "one_hop"]


def boot(xs, rng, b=2000):
    if not xs:
        return [None, None]
    means = sorted(sum(rng.choice(xs) for _ in xs) / len(xs) for _ in range(b))
    return [round(means[int(0.025 * b)], 3), round(means[int(0.975 * b)], 3)]


NUMBER_WORDS = {w: i for i, ws in enumerate([["zero", "sifir"], ["one", "once", "bir"], ["two", "twice", "iki"],
                                               ["three", "thrice", "uc"], ["four", "dort"], ["five", "bes"],
                                               ["six", "alti"], ["seven", "yedi"], ["eight", "sekiz"],
                                               ["nine", "dokuz"], ["ten", "on"]]) for w in ws}


COUNT_WORDS = {"kisi", "kez", "kere", "defa", "times", "people", "person", "persons", "meetups", "members", "uye"}


def answer_ok(q, answer):
    a = fold(answer or "")
    ans = q["answer"]
    if ans["type"] == "count":
        # The count is the number next to a counting word ("3 kişi", "2 kez", "three times"); failing that, the
        # first number that is not part of a date (years and "30 Eylül" are skipped).
        toks = re.findall(r"[a-z0-9]+", a)
        val = lambda t: int(t) if t.isdigit() else NUMBER_WORDS.get(t)
        months = {fold(m) for m in MONTH_TR + MONTH_EN}
        for t, nxt in zip(toks, toks[1:] + [""]):
            if val(t) is not None and nxt in COUNT_WORDS:
                return val(t) == ans["value"]
        for i, t in enumerate(toks):
            nxt = toks[i + 1] if i + 1 < len(toks) else ""
            prev = toks[i - 1] if i else ""
            if val(t) is None or (t.isdigit() and len(t) == 4) or nxt in months or prev in months:
                continue
            return val(t) == ans["value"]
        return False
    if ans["type"] == "date":
        d = dt.date.fromisoformat(ans["value"])
        months = {fold(MONTH_TR[d.month - 1]), fold(MONTH_EN[d.month - 1])}
        # Messages may omit the year (same year as the chat), so day + month is enough unless the answer names a
        # different year.
        years = set(re.findall(r"(?<!\d)(20\d\d)(?!\d)", a))
        return (ans["value"] in a or (any(m in a for m in months) and re.search(rf"(?<!\d){d.day}(?!\d)", a) is not None
                                      and (not years or str(d.year) in years)))
    return any(fold(x) in a for x in ans["aliases"])


def per_question(q, pack, budget):
    pack = pack[:budget]
    gold = set(q["gold_messages"])
    hit = len(gold & set(pack))
    return {"recall": hit / len(gold), "complete": float(hit == len(gold)),
            "stale_included": float(bool(set(q.get("stale_messages", [])) & set(pack))), "pack_size": len(pack)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="a_hybrid_rerank")
    ap.add_argument("--budget", type=int, default=8)
    args = ap.parse_args()
    rng = random.Random(0)
    qs = {q["id"]: q for q in load_questions()}
    methods = {}
    for d in sorted(glob.glob(os.path.join(RUNS, "*", "packs.jsonl"))):
        name = os.path.basename(os.path.dirname(d))
        methods[name] = {r["qid"]: r for r in map(json.loads, open(d))}

    out = {}
    for name, rows in methods.items():
        res = {"by_class": {}, "n": len(rows)}
        missing = sorted(set(qs) - set(rows))
        if missing:
            res["missing"] = len(missing)
        for cls in CLASSES + ["go_classes"]:
            ids = [i for i in rows if (qs[i]["class"] in ("latest_value", "two_hop", "aggregate")
                                       if cls == "go_classes" else qs[i]["class"] == cls)]
            pq = [per_question(qs[i], rows[i]["pack"], args.budget) for i in ids]
            if not pq:
                continue
            r = {k: round(sum(p[k] for p in pq) / len(pq), 3) for k in ("recall", "complete", "stale_included", "pack_size")}
            if all("shown" in rows[i] for i in ids):
                r["shown_recall"] = round(sum(len(set(qs[i]["gold_messages"]) & set(rows[i]["shown"]))
                                              / len(qs[i]["gold_messages"]) for i in ids) / len(ids), 3)
            if all("answer" in rows[i] for i in ids):
                r["answer_ok"] = round(sum(answer_ok(qs[i], rows[i]["answer"]) for i in ids) / len(ids), 3)
            ref = methods.get(args.ref, {})
            if all("cost" in rows[i] for i in ids) and all("ranked" in ref.get(i, {}) for i in ids):
                depth = lambda i: max(1, min(rows[i]["cost"]["messages_shown"], len(ref[i]["ranked"])))
                r["matched_reads_ref_recall"] = round(sum(per_question(qs[i], ref[i]["ranked"], depth(i))["recall"]
                                                          for i in ids) / len(ids), 3)
            r["n"] = len(pq)
            r["recall_ci"] = boot([p["recall"] for p in pq], rng)
            if name != args.ref and args.ref in methods:
                diffs = [per_question(qs[i], rows[i]["pack"], args.budget)["recall"]
                         - per_question(qs[i], methods[args.ref][i]["pack"], args.budget)["recall"]
                         for i in ids if i in methods[args.ref]]
                r["diff_vs_ref"] = round(sum(diffs) / len(diffs), 3)
                r["diff_ci"] = boot(diffs, rng)
            res["by_class"][cls] = r
        # Depth curve for ranked baselines.
        if all("ranked" in r for r in rows.values()):
            res["recall_at"] = {}
            for k in (1, 2, 4, 8, 12, 16, 20):
                pq = [per_question(qs[i], rows[i]["ranked"], k)["recall"] for i in rows if qs[i]["class"] != "one_hop"]
                res["recall_at"][k] = round(sum(pq) / len(pq), 3)
        cost = [r["cost"] for r in rows.values() if "cost" in r]
        if cost:
            res["cost"] = {k: round(sum(c[k] for c in cost) / len(cost), 1) for k in cost[0]}
        out[name] = res

    json.dump(out, open(os.path.join(RUNS, "scores.json"), "w"), indent=1)
    print(f"evidence recall at budget {args.budget} (complete = all gold in pack); diff vs {args.ref}")
    print(f"{'method':24s} " + " ".join(f"{c[:12]:>22s}" for c in CLASSES))
    for name, res in out.items():
        cells = []
        for c in CLASSES:
            r = res["by_class"].get(c)
            if not r:
                cells.append(f"{'-':>22s}")
                continue
            d = f" {r['diff_vs_ref']:+.2f}" if "diff_vs_ref" in r else ""
            cells.append(f"{r['recall']:.2f}/{r['complete']:.2f}{d:>7s} (n{r['n']})".rjust(22))
        print(f"{name:24s} " + " ".join(cells))
    for name, res in out.items():
        if "recall_at" in res:
            print(f"{name:24s} recall@k (non-control):", res["recall_at"])
        if "cost" in res:
            print(f"{name:24s} cost per question:", res["cost"])


if __name__ == "__main__":
    main()
