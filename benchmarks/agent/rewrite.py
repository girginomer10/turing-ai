#!/usr/bin/env python3
"""LLM rewrite of fact-bearing turns and the fact-recoverability check (go/no-go criterion).

Family A (Claude, run as subagents under the subscription, or any chat model given rewrite_prompt.md) rewrites
template messages into natural chat; family B (GPT through `codex exec`) re-extracts facts from the text without
seeing the gold. A turn is recoverable when the extracted facts contain the gold fact. The same extractor also runs
on the template text as a control for the extractor itself.

Steps (run from benchmarks/agent):
  python3 -I rewrite.py select [--per-world 60 --batches 4]   -> work/rewrite/batches/batch_<k>.json
  (renderer writes work/rewrite/rendered/batch_<k>.json = [{"id", "text"}])
  python3 -I rewrite.py extract --surface rendered|template      -> work/rewrite/extract_<surface>/batch_<k>.json
  python3 -I rewrite.py score                                      -> work/rewrite/recoverability.json
"""
import argparse, glob, json, os, random, subprocess, sys, unicodedata
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from render import CITY_EN, CITY_TR, date_en  # noqa: E402
from retrieval import WORLDS, work_path  # noqa: E402

OUT = work_path("rewrite")

TYPE = {"city": "lives_in", "plan_city": "plans_move", "employer": "works_at", "lead": "leads_project",
        "deadline": "project_deadline", "event": "event"}


def load_world(wid):
    d = os.path.join(WORLDS, wid)
    w = json.load(open(os.path.join(d, "world.json")))
    msgs = [json.loads(l) for l in open(os.path.join(d, "messages.jsonl"))]
    return w, msgs


def fold(s):
    s = s.replace("İ", "i").replace("I", "ı").lower().replace("ı", "i")
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


def describe(f, w):
    """Human-readable gold fact handed to the renderer so it knows what must survive the rewrite."""
    P = {p["id"]: f"{p['first']} {p['last']}" for p in w["people"]}
    J = {j["id"]: j["name"] for j in w["projects"]}
    a, v = f["attr"], f["value"]
    if a in ("city", "plan_city"):
        return {"type": TYPE[a], "person": P[f["subject"]], "city": CITY_EN[v], "changed": f["version"] > 0}
    if a == "employer":
        return {"type": "works_at", "person": P[f["subject"]], "company": v, "changed": f["version"] > 0}
    if a == "lead":
        return {"type": "leads_project", "project": J[f["subject"]], "person": P[v], "changed": f["version"] > 0}
    if a == "deadline":
        return {"type": "project_deadline", "project": J[f["subject"]], "date": date_en(v), "changed": f["version"] > 0}
    if a == "member":
        return {"type": "joined_team" if v[1] == "join" else "left_team", "project": J[f["subject"]], "person": P[v[0]]}
    if a == "event":
        return {"type": "event", "activity": v["kind"], "date": date_en(v["date"]), "city": CITY_EN[v["city"]],
                "attendees": [P[x] for x in v["attendees"]], "project": J[v["project"]] if v["project"] else None}
    raise ValueError(a)


def cmd_select(args):
    rng = random.Random(11)
    items = []
    for d in sorted(glob.glob(os.path.join(WORLDS, "w*"))):
        wid = os.path.basename(d)
        w, msgs = load_world(wid)
        F = {f["id"]: f for f in w["facts"]}
        fm = [m for m in msgs if m["facts"]]
        # Stratify by language, then by fact type within it.
        quota = {"tr": round(args.per_world * 0.5), "en": round(args.per_world * 0.3)}
        quota["mix"] = args.per_world - quota["tr"] - quota["en"]
        for lang, k in quota.items():
            by_attr = defaultdict(list)
            for m in fm:
                if m["lang"] == lang:
                    by_attr[F[m["facts"][0]]["attr"]].append(m)
            for a in by_attr:
                rng.shuffle(by_attr[a])
            picked = []
            while len(picked) < k and any(by_attr.values()):
                for a in sorted(by_attr):
                    if by_attr[a] and len(picked) < k:
                        picked.append(by_attr[a].pop())
            for m in picked:
                items.append({"id": f"{wid}/{m['id']}", "lang": lang, "ts": m["ts"], "template_text": m["template_text"],
                              "facts": [describe(F[x], w) for x in m["facts"]]})
    rng.shuffle(items)
    os.makedirs(os.path.join(OUT, "batches"), exist_ok=True)
    for k in range(args.batches):
        json.dump(items[k::args.batches], open(os.path.join(OUT, "batches", f"batch_{k}.json"), "w"),
                  ensure_ascii=False, indent=1)
    print(len(items), "items;", dict(Counter(i["lang"] for i in items)), dict(Counter(i["facts"][0]["type"] for i in items)))


EXTRACT_PROMPT = """You extract facts from short chat messages a user wrote to an AI assistant. Each message has a
timestamp. For every message, list ONLY the facts the message itself states about named people and projects:

- lives_in: person, city (where the person lives now, per this message; a completed move counts)
- plans_move: person, city (a move that is only planned / considered, not done)
- works_at: person, company (the person's current employer per this message; NOT a company they left)
- leads_project: person, project (the person leads / took over the project)
- project_deadline: project, date (the project's current due date per this message, YYYY-MM-DD)
- joined_team / left_team: person, project
- event: attendees (names, not the user), city, date (YYYY-MM-DD; resolve "today", "yesterday", "dün", "bugün",
  "14 Mart" etc. against the message timestamp), activity (one word: dinner, coffee, meeting, conference, hike,
  concert, lunch, workshop), project (if one was discussed)

Write names exactly as they appear (keep surnames; drop words like "my cousin" / "kuzenim"). Use English city names.
Leave unused fields null. Messages may be Turkish, English or mixed. Do not guess beyond the text. Do not run any
commands or read any files; answer directly with JSON matching the schema.

Messages:
"""

SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["items"],
    "properties": {"items": {"type": "array", "items": {
        "type": "object", "additionalProperties": False, "required": ["id", "facts"],
        "properties": {"id": {"type": "string"}, "facts": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["type", "person", "project", "city", "company", "date", "attendees", "activity"],
            "properties": {
                "type": {"type": "string", "enum": ["lives_in", "plans_move", "works_at", "leads_project",
                                                    "project_deadline", "joined_team", "left_team", "event"]},
                "person": {"type": ["string", "null"]}, "project": {"type": ["string", "null"]},
                "city": {"type": ["string", "null"]}, "company": {"type": ["string", "null"]},
                "date": {"type": ["string", "null"]}, "attendees": {"type": "array", "items": {"type": "string"}},
                "activity": {"type": ["string", "null"]}}}}}}}}}


def cmd_extract(args):
    src = os.path.join(OUT, "rendered" if args.surface == "rendered" else "batches")
    dst = os.path.join(OUT, f"extract_{args.surface}")
    os.makedirs(dst, exist_ok=True)
    # The extractor runs in an empty directory with only the schema, so the gold batches are out of its reach.
    sandbox = os.path.join(OUT, "sandbox")
    os.makedirs(sandbox, exist_ok=True)
    schema_path = os.path.join(sandbox, "extract_schema.json")
    json.dump(SCHEMA, open(schema_path, "w"))
    for path in sorted(glob.glob(os.path.join(src, "batch_*.json"))):
        out = os.path.join(dst, os.path.basename(path))
        if os.path.exists(out):
            continue
        batch = json.load(open(path))
        meta = {b["id"]: b for b in json.load(open(os.path.join(OUT, "batches", os.path.basename(path))))}
        lines = []
        for b in batch:
            text = b["text"] if args.surface == "rendered" else b["template_text"]
            lines.append(json.dumps({"id": b["id"], "timestamp": meta[b["id"]]["ts"], "text": text}, ensure_ascii=False))
        prompt = EXTRACT_PROMPT + "\n".join(lines)
        raw = os.path.join(sandbox, os.path.basename(out) + ".raw")
        cmd = ["codex", "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-C", sandbox,
               "--output-schema", schema_path, "-o", raw, "-"]
        if args.model:
            cmd[2:2] = ["-m", args.model]
        print("extract", os.path.basename(path), len(batch), "items ...", flush=True)
        r = subprocess.run(cmd, input=prompt, text=True, capture_output=True, timeout=1800)
        if r.returncode != 0 or not os.path.exists(raw):
            print("codex failed:", r.returncode, r.stderr[-800:])
            continue
        data = json.load(open(raw))
        json.dump(data["items"], open(out, "w"), ensure_ascii=False, indent=1)
        os.replace(raw, out + ".raw")


# ---------------------------------------------------------------- scoring

CITY_KEY = {fold(n): k for k in CITY_EN for n in (CITY_EN[k], CITY_TR[k])}
CITY_KEY.update({"munchen": "munich", "wien": "vienna", "lisboa": "lisbon"})


def resolve_person(name, w):
    if not name:
        return None
    n = fold(name)
    hits = [p["id"] for p in w["people"] if fold(f"{p['first']} {p['last']}") in n]
    if len(hits) == 1:
        return hits[0]
    firsts = [p for p in w["people"] if fold(p["first"]) in n.split()]
    if len(firsts) == 1 and sum(1 for p in w["people"] if p["first"] == firsts[0]["first"]) == 1:
        return firsts[0]["id"]
    return None


def resolve_project(name, w):
    if not name:
        return None
    hits = [j["id"] for j in w["projects"] if fold(j["name"]) in fold(name)]
    return hits[0] if len(hits) == 1 else None


def matches(gold, ex, w):
    a, v = gold["attr"], gold["value"]
    t = ex["type"]
    if a in ("city", "plan_city"):
        return (t == TYPE[a] and resolve_person(ex["person"], w) == gold["subject"]
                and CITY_KEY.get(fold(ex["city"] or "")) == v)
    if a == "employer":
        return (t == "works_at" and resolve_person(ex["person"], w) == gold["subject"]
                and fold(ex["company"] or "") == fold(v))
    if a == "lead":
        return t == "leads_project" and resolve_project(ex["project"], w) == gold["subject"] and resolve_person(ex["person"], w) == v
    if a == "deadline":
        return t == "project_deadline" and resolve_project(ex["project"], w) == gold["subject"] and ex["date"] == v
    if a == "member":
        want = "joined_team" if v[1] == "join" else "left_team"
        return t == want and resolve_project(ex["project"], w) == gold["subject"] and resolve_person(ex["person"], w) == v[0]
    if a == "event":
        att = {resolve_person(x, w) for x in ex["attendees"] or []}
        return (t == "event" and att == set(v["attendees"]) and ex["date"] == v["date"]
                and CITY_KEY.get(fold(ex["city"] or "")) == v["city"] and fold(ex["activity"] or "") == v["kind"]
                and resolve_project(ex["project"], w) == v["project"])
    return False


def cmd_score(args):
    worlds, out = {}, {}
    for surface in ("template", "rendered"):
        rows = []
        for path in sorted(glob.glob(os.path.join(OUT, f"extract_{surface}", "batch_*.json"))):
            for item in json.load(open(path)):
                wid, mid = item["id"].split("/")
                if wid not in worlds:
                    worlds[wid] = load_world(wid)
                w, msgs = worlds[wid]
                F = {f["id"]: f for f in w["facts"]}
                m = next(x for x in msgs if x["id"] == mid)
                gold = [F[x] for x in m["facts"]]
                ok = all(any(matches(g, ex, w) for ex in item["facts"]) for g in gold)
                # A completed move extracted as a plan (or the reverse) is the error that would poison latest-value.
                rows.append({"id": item["id"], "lang": m["lang"], "attr": gold[0]["attr"], "ok": ok,
                             "extracted": item["facts"]})
        if not rows:
            continue
        agg = lambda key: {k: {"n": len(v), "recoverable": round(sum(r["ok"] for r in v) / len(v), 3)}
                           for k, v in sorted(_group(rows, key).items())}
        out[surface] = {"n": len(rows), "recoverable": round(sum(r["ok"] for r in rows) / len(rows), 3),
                        "by_lang": agg("lang"), "by_attr": agg("attr"),
                        "failures": [r["id"] for r in rows if not r["ok"]]}
        print(surface, out[surface]["n"], "recoverable", out[surface]["recoverable"], out[surface]["by_lang"])
    json.dump(out, open(os.path.join(OUT, "recoverability.json"), "w"), ensure_ascii=False, indent=1)


def _group(rows, key):
    g = defaultdict(list)
    for r in rows:
        g[r[key]].append(r)
    return g


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select")
    s.add_argument("--per-world", type=int, default=60)
    s.add_argument("--batches", type=int, default=4)
    e = sub.add_parser("extract")
    e.add_argument("--surface", choices=["rendered", "template"], required=True)
    e.add_argument("--model", default=None)
    sub.add_parser("score")
    args = ap.parse_args()
    {"select": cmd_select, "extract": cmd_extract, "score": cmd_score}[args.cmd](args)


if __name__ == "__main__":
    main()
