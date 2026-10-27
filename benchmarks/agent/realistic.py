#!/usr/bin/env python3
"""Realistic chat surface: whole sessions written as chat around the same worlds and questions.

The template and rewritten surfaces keep one fact per message with the full name in it. Here a writer model
(Claude, so that it is a different family from the GPT agent, answer model and extractor) writes complete
multi-turn sessions from a programmatic plan:
- facts are woven into conversations that have another purpose, with 1-3 facts per session;
- about 40 % of person facts are split: the person is named in one user message and the fact comes later through
  a pronoun or Turkish pro-drop, so the gold evidence is both messages;
- recent events use relative dates (today, yesterday, a weekday), older ones day and month as in the template;
- every non-fact session is a written chat on a real topic, some mentioning a person or project without a fact;
- assistant replies are written too.
The worlds, questions and answers stay identical; only the gold message ids are recomputed from the writer's
per-message annotations (`conveys`, `names`), which a GPT extractor then checks at session level.

  python3 -I realistic.py plan [--per-batch 25]   -> work/realistic/specs.json, batches/batch_<k>.json
  (writer: realistic_prompt.md + one batch -> work/realistic/out/batch_<k>.json)
  python3 -I realistic.py build                   -> validates, writes work/worlds_real/ (AGENT_SURFACE=real)
  python3 -I realistic.py extract [--jobs 5]      -> GPT session-level extraction (codex, empty sandbox)
  python3 -I realistic.py score                   -> work/realistic/recoverability.json
"""
import argparse, datetime as dt, glob, json, os, random, re, shutil, subprocess, sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from render import CITY_EN, CITY_TR, MONTH_EN, date_en  # noqa: E402
from retrieval import fold  # noqa: E402

SRC = os.path.join(HERE, "work", "worlds")
OUT = os.path.join(HERE, "work", "realistic")
DST = os.path.join(HERE, "work", "worlds_real")
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

PERSONAS = {
    "w1": "software developer in their late twenties; casual, quick messages, some typos, asks for code help often",
    "w2": "product manager; mixes English work words into Turkish, uses lists, a bit hurried",
    "w3": "PhD student; longer reflective messages, polite, sometimes anxious about deadlines",
    "w4": "graphic designer; short lowercase messages, emoji now and then, dry humour",
    "w5": "management consultant; tidy sentences, asks for drafts and summaries, plans a lot",
}
TOPICS = [
    "debugging a Python KeyError in a data script", "writing a SQL query with a GROUP BY", "a regex for phone numbers",
    "setting up a Git branch workflow", "a slow laptop and what to clean up", "a weekly meal-prep plan",
    "a vegetarian dinner recipe for guests", "how to make menemen properly", "sourdough starter problems",
    "back pain from sitting all day", "trouble sleeping and screen time", "starting to run 5k",
    "a gym routine for three days a week", "budgeting a monthly salary", "whether to pay off a credit card first",
    "a weekend trip idea for themselves", "packing list for a rainy holiday", "learning Spanish with an app",
    "improving English pronunciation", "a book recommendation after finishing a novel", "a film for a quiet evening",
    "drafting an email to the landlord about a broken heater", "preparing for a job interview question",
    "rewriting a LinkedIn summary", "summarising a long article", "translating a short paragraph",
    "a statistics homework question about medians", "how compound interest works", "keeping a balcony plant alive",
    "a cat that stopped eating its usual food", "choosing a new phone", "cleaning a stained white shirt",
    "planning a productive Sunday", "a difficult conversation with a neighbour about noise",
    "writing a birthday card message", "ideas for a hobby to start", "making slides look cleaner",
    "a spreadsheet formula that returns #N/A", "understanding an electricity bill", "meditation for beginners",
]
MENTION_KINDS = {
    "person": ["asks for a gift idea for them", "asks for help drafting a short message to them",
               "asks how to reply to a message they sent", "asks for a restaurant suggestion to recommend to them"],
    "project": ["asks for help with slides about the project", "asks for an agenda for a project sync",
                "asks for a name for a project document", "asks how to phrase a status update for the project"],
}
PERSON_ATTRS = ("city", "plan_city", "employer", "member", "lead")


def load(wid):
    d = os.path.join(SRC, wid)
    w = json.load(open(os.path.join(d, "world.json")))
    qs = [json.loads(l) for l in open(os.path.join(d, "questions.jsonl"))]
    return w, qs


def name_rule(person, dup):
    full = f"{person['first']} {person['last']}"
    if person["first"] in dup:
        return {"name": "full", "person": full}
    return {"name": "first", "person": full, "first_name_ok": person["first"]}


def when_rule(event_date, session_date):
    gap = (session_date - event_date).days
    if gap == 0:
        return "today (relative wording such as 'today' / 'bugün')"
    if gap == 1:
        return "yesterday (relative wording such as 'yesterday' / 'dün')"
    if gap <= 6:
        return (f"{WEEKDAYS[event_date.weekday()]} {gap} days before the session (say the weekday, e.g. "
                f"'on {WEEKDAYS[event_date.weekday()]}' / 'geçen {WEEKDAYS[event_date.weekday()]}' in the session language)")
    year = "" if event_date.year == session_date.year else f" and the year {event_date.year}"
    return f"day and month: {event_date.day} {MONTH_EN[event_date.month - 1]}{year}"


def date_rule(iso, session_date):
    d = dt.date.fromisoformat(iso)
    year = "" if d.year == session_date.year else f" {d.year} (include the year)"
    return f"{d.day} {MONTH_EN[d.month - 1]}{year}" if year else f"{d.day} {MONTH_EN[d.month - 1]} (year optional)"


def fact_spec(f, w, people, projects, dup, session_date, rng):
    a, v = f["attr"], f["value"]
    prev = None
    if f["version"] > 0:
        prev = next(x for x in w["facts"] if x["subject"] == f["subject"] and x["attr"] == a and x["version"] == f["version"] - 1)
    spec = {"fact_id": f["id"]}
    if a in ("city", "plan_city", "employer"):
        p = people[f["subject"]]
        spec.update(name_rule(p, dup))
        if a == "city":
            spec["state"] = (f"lives in {CITY_EN[v]} (Turkish: {CITY_TR[v]})" if not prev else
                             f"has moved to {CITY_EN[v]} (Turkish: {CITY_TR[v]}); they used to live in {CITY_EN[prev['value']]} (mentioning that is optional)")
        elif a == "plan_city":
            spec["state"] = f"is only considering moving to {CITY_EN[v]} (Turkish: {CITY_TR[v]}); nothing is decided"
        else:
            spec["state"] = (f"works at {v}" if not prev else
                             f"has a new job at {v}; they used to work at {prev['value']} (mentioning that is optional)")
    elif a == "lead":
        p = people[v]
        spec.update(name_rule(p, dup))
        spec["project"] = projects[f["subject"]]
        spec["state"] = (f"leads the {projects[f['subject']]} project" if not prev else
                         f"has become the new lead of the {projects[f['subject']]} project (do not say anything about the previous lead)")
    elif a == "member":
        p = people[v[0]]
        spec.update(name_rule(p, dup))
        spec["project"] = projects[f["subject"]]
        spec["state"] = (f"joined the {projects[f['subject']]} team" if v[1] == "join" else f"left the {projects[f['subject']]} team")
    elif a == "deadline":
        spec["project"] = projects[f["subject"]]
        spec["state"] = (f"the {projects[f['subject']]} project's deadline is {date_rule(v, session_date)}" if not prev else
                         f"the {projects[f['subject']]} project's deadline has changed; the new deadline is {date_rule(v, session_date)}")
        spec["name"] = "none"
    elif a == "event":
        ev = v
        att = [people[x] for x in ev["attendees"]]
        spec["attendees"] = [name_rule(x, dup) for x in att]
        spec["state"] = (f"the user had a {ev['kind']} with {', '.join(x['first'] + ' ' + x['last'] for x in att)} in "
                         f"{CITY_EN[ev['city']]} (Turkish: {CITY_TR[ev['city']]})"
                         + (f", and they talked about the {projects[ev['project']]} project" if ev["project"] else ""))
        spec["when"] = when_rule(dt.date.fromisoformat(ev["date"]), session_date)
    spec["split"] = a in PERSON_ATTRS + ("event",) and rng.random() < 0.4
    return spec


def cmd_plan(args):
    rng = random.Random(2026)
    specs = []
    for d in sorted(glob.glob(os.path.join(SRC, "w*"))):
        wid = os.path.basename(d)
        w, _ = load(wid)
        people = {p["id"]: p for p in w["people"]}
        projects = {j["id"]: j["name"] for j in w["projects"]}
        firsts = Counter(p["first"] for p in w["people"])
        dup = {f for f, n in firsts.items() if n > 1}
        facts = sorted(w["facts"], key=lambda f: (f["stated_on"], f["id"]))
        groups, i = [], 0
        while i < len(facts):
            g = [facts[i]]
            while (len(g) < 3 and i + len(g) < len(facts) and rng.random() < 0.45 and
                   (dt.date.fromisoformat(facts[i + len(g)]["stated_on"]) - dt.date.fromisoformat(g[0]["stated_on"])).days <= 4):
                g.append(facts[i + len(g)])
            i += len(g)
            groups.append(g)
        n_fact_msgs = 0
        for k, g in enumerate(groups):
            day = dt.date.fromisoformat(max(f["stated_on"] for f in g))
            lang = rng.choices(["tr", "en", "mix"], weights=(0.55, 0.30, 0.15))[0]
            turns = rng.randint(len(g) + 1, len(g) + 3)
            n_fact_msgs += 2 * turns
            specs.append({"session_id": f"{wid}-f{k:03d}", "world": wid, "date": f"{day.isoformat()} ({WEEKDAYS[day.weekday()]})",
                          "lang": lang, "persona": PERSONAS[wid], "user_turns": turns,
                          "facts": [fact_spec(f, w, people, projects, dup, day, rng) for f in g]})
        # Topic sessions fill the archive to roughly 2,000 messages per world.
        n_topic = max(0, (2000 - n_fact_msgs) // 6)
        start, end = dt.date(2024, 1, 1), dt.date(2026, 9, 30)
        for k in range(n_topic):
            day = start + dt.timedelta(days=rng.randint(0, (end - start).days))
            item = {"session_id": f"{wid}-t{k:03d}", "world": wid, "date": f"{day.isoformat()} ({WEEKDAYS[day.weekday()]})",
                    "lang": rng.choices(["tr", "en", "mix"], weights=(0.55, 0.30, 0.15))[0], "persona": PERSONAS[wid],
                    "user_turns": rng.randint(2, 4), "topic": rng.choice(TOPICS)}
            if rng.random() < 0.3:
                if rng.random() < 0.6:
                    p = rng.choice(w["people"])
                    item["mention"] = {**name_rule(p, dup), "how": rng.choice(MENTION_KINDS["person"])}
                else:
                    j = rng.choice(w["projects"])
                    item["mention"] = {"project": j["name"], "how": rng.choice(MENTION_KINDS["project"])}
            specs.append(item)
    os.makedirs(os.path.join(OUT, "batches"), exist_ok=True)
    json.dump(specs, open(os.path.join(OUT, "specs.json"), "w"), ensure_ascii=False, indent=1)
    order = specs[:]
    random.Random(7).shuffle(order)
    for old in glob.glob(os.path.join(OUT, "batches", "*.json")):
        os.remove(old)
    nb = 0
    for nb, i in enumerate(range(0, len(order), args.per_batch)):
        json.dump(order[i:i + args.per_batch], open(os.path.join(OUT, "batches", f"batch_{nb:03d}.json"), "w"),
                  ensure_ascii=False, indent=1)
    c = Counter(s["world"] for s in specs)
    print(len(specs), "sessions in", nb + 1, "batches;", dict(c), "; fact sessions",
          sum("facts" in s for s in specs), "; split facts", sum(f["split"] for s in specs for f in s.get("facts", [])),
          "of", sum(len(s.get("facts", [])) for s in specs))


# ---------------------------------------------------------------- validation and build


def present(text, needle):
    return fold(needle) in fold(text)


def check_session(spec, out):
    """Problems with one written session (empty list = accepted)."""
    probs = []
    turns = out.get("turns") or []
    if not turns or turns[0]["role"] != "user":
        probs.append("must start with a user turn")
    for t in turns:
        if t["role"] not in ("user", "assistant") or not t.get("text", "").strip():
            probs.append("bad turn")
        if t["role"] == "assistant" and (t.get("conveys") or t.get("names")):
            probs.append("assistant turn annotated")
    users = [(i, t) for i, t in enumerate(turns) if t["role"] == "user"]
    want = {f["fact_id"]: f for f in spec.get("facts", [])}
    for fid, f in want.items():
        conv = [i for i, t in users if fid in (t.get("conveys") or [])]
        names = [i for i, t in users if fid in (t.get("names") or [])]
        if not conv:
            probs.append(f"{fid} not conveyed")
            continue
        text = " ".join(turns[i]["text"] for i in conv + names)
        people = f.get("attendees") or ([f] if f.get("person") else [])
        for p in people:
            ok = present(text, p["person"]) or (p.get("first_name_ok") and present(text, p["first_name_ok"]))
            if not ok:
                probs.append(f"{fid} name missing ({p['person']})")
        if f.get("project") and not present(text, f["project"]):
            probs.append(f"{fid} project missing ({f['project']})")
        if f["split"]:
            if not names:
                probs.append(f"{fid} split but no names turn")
            elif min(names) >= min(conv):
                probs.append(f"{fid} names turn not before the fact")
    extra = {x for _, t in users for x in (t.get("conveys") or []) + (t.get("names") or [])} - set(want)
    if extra:
        probs.append(f"unknown fact ids {sorted(extra)}")
    return probs


def load_outputs():
    outs = {}
    for p in sorted(glob.glob(os.path.join(OUT, "out", "batch_*.json"))):
        for s in json.load(open(p)):
            outs[s["session_id"]] = s
    return outs


def cmd_build(args):
    specs = {s["session_id"]: s for s in json.load(open(os.path.join(OUT, "specs.json")))}
    outs = load_outputs()
    missing = sorted(set(specs) - set(outs))
    problems = {sid: check_session(specs[sid], outs[sid]) for sid in outs if sid in specs}
    bad = {k: v for k, v in problems.items() if v}
    json.dump({"missing": missing, "problems": bad}, open(os.path.join(OUT, "validation.json"), "w"), indent=1, ensure_ascii=False)
    print(f"{len(outs)}/{len(specs)} sessions written; {len(bad)} with problems; {len(missing)} missing")
    for sid, p in list(bad.items())[:10]:
        print("  ", sid, p[:3])
    if missing or bad:
        if not args.partial:
            sys.exit("not building: fix or re-render the sessions above (or pass --partial for a pilot)")
    rng = random.Random(5)
    for d in sorted(glob.glob(os.path.join(SRC, "w*"))):
        wid = os.path.basename(d)
        w, qs = load(wid)
        sess = sorted((s for sid, s in specs.items() if s["world"] == wid and sid in outs and not bad.get(sid)),
                      key=lambda s: (s["date"], s["session_id"]))
        if not sess:
            continue
        messages, sessions, conveys, names = [], [], defaultdict(set), defaultdict(set)
        cursor = None
        for k, s in enumerate(sess):
            day = dt.date.fromisoformat(s["date"][:10])
            t = dt.datetime.combine(day, dt.time(0)) + dt.timedelta(minutes=rng.randint(8 * 60, 21 * 60))
            if cursor and cursor.date() == day:
                t = max(t, cursor + dt.timedelta(minutes=rng.randint(10, 120)))
            t = min(t, dt.datetime.combine(day, dt.time(23, 0)))
            sid = f"s{k:04d}"
            ids = []
            for turn in outs[s["session_id"]]["turns"]:
                mid = f"m{len(messages):05d}"
                lang = s["lang"]
                facts = list(turn.get("conveys") or []) if turn["role"] == "user" else []
                nm = list(turn.get("names") or []) if turn["role"] == "user" else []
                messages.append({"id": mid, "session": sid, "ts": min(t, dt.datetime.combine(day, dt.time(23, 59))).isoformat(timespec="minutes"),
                                 "role": turn["role"], "lang": lang, "text": turn["text"].strip(), "facts": facts, "names": nm,
                                 "source_session": s["session_id"]})
                for f in facts:
                    conveys[f].add(mid)
                for f in nm:
                    names[f].add(mid)
                ids.append(mid)
                t += dt.timedelta(minutes=rng.randint(1, 4))
            cursor = t
            sessions.append({"id": sid, "day": day.isoformat(), "lang": s["lang"], "messages": ids, "source_session": s["session_id"]})
        out_dir = os.path.join(DST, wid)
        os.makedirs(out_dir, exist_ok=True)
        shutil.copy(os.path.join(d, "world.json"), out_dir)
        with open(os.path.join(out_dir, "messages.jsonl"), "w") as fh:
            for m in messages:
                fh.write(json.dumps(m, ensure_ascii=False) + "\n")
        json.dump(sessions, open(os.path.join(out_dir, "sessions.json"), "w"), ensure_ascii=False)
        dropped = 0
        with open(os.path.join(out_dir, "questions.jsonl"), "w") as fh:
            for q in qs:
                need = [f for f in q["gold_facts"]]
                if any(f not in conveys for f in need):
                    dropped += 1
                    continue
                q = dict(q)
                q["gold_messages"] = sorted(set().union(*(conveys[f] | names[f] for f in need)))
                if "stale_facts" in q:
                    q["stale_messages"] = sorted(set().union(*(conveys[f] for f in q["stale_facts"] if f in conveys)) if q["stale_facts"] else set())
                fh.write(json.dumps(q, ensure_ascii=False) + "\n")
        print(f"{wid}: {len(messages)} messages in {len(sessions)} sessions; {len(qs) - dropped}/{len(qs)} questions kept")


# ---------------------------------------------------------------- GPT session-level check

EXTRACT = """You read chat sessions between a user and their AI assistant (Turkish, English or mixed). Each session has a
date and numbered turns. List ONLY the facts the USER states in the session about named people and projects:

- lives_in: person, city (where the person lives now; a completed move counts)
- plans_move: person, city (a move only planned or considered)
- works_at: person, company (current employer; not a company they left)
- leads_project: person, project
- project_deadline: project, date (YYYY-MM-DD)
- joined_team / left_team: person, project
- event: attendees (names, not the user), city, date (YYYY-MM-DD; resolve "today", "yesterday", weekdays, "dün",
  "geçen cuma", "14 Mart" against the session date), activity (one word: dinner, coffee, meeting, conference,
  hike, concert, lunch, workshop), project (if one was discussed)

Resolve pronouns and dropped subjects to the person they refer to and write full names when the session gives them
(otherwise the first name). Use English city names. For each fact give `turns`: the numbers of ALL user turns
needed to establish it (the one naming the person and the one stating the fact). Leave unused fields null. Do not
guess beyond the text. Do not run commands or read files.

Sessions:
"""

SCHEMA = {"type": "object", "additionalProperties": False, "required": ["sessions"],
          "properties": {"sessions": {"type": "array", "items": {
              "type": "object", "additionalProperties": False, "required": ["session_id", "facts"],
              "properties": {"session_id": {"type": "string"}, "facts": {"type": "array", "items": {
                  "type": "object", "additionalProperties": False,
                  "required": ["type", "person", "project", "city", "company", "date", "attendees", "activity", "turns"],
                  "properties": {
                      "type": {"type": "string", "enum": ["lives_in", "plans_move", "works_at", "leads_project",
                                                          "project_deadline", "joined_team", "left_team", "event"]},
                      "person": {"type": ["string", "null"]}, "project": {"type": ["string", "null"]},
                      "city": {"type": ["string", "null"]}, "company": {"type": ["string", "null"]},
                      "date": {"type": ["string", "null"]}, "attendees": {"type": "array", "items": {"type": "string"}},
                      "activity": {"type": ["string", "null"]}, "turns": {"type": "array", "items": {"type": "integer"}}}}}}}}}}


def session_text(spec, out):
    lines = [f"=== session {spec['session_id']} | date {spec['date']}"]
    for i, t in enumerate(out["turns"]):
        lines.append(f"[{i}] {t['role']}: {t['text']}")
    return "\n".join(lines)


def run_extract_batch(path):
    dst = path.replace(os.sep + "xbatches" + os.sep, os.sep + "xout" + os.sep)
    if os.path.exists(dst):
        return "skip"
    sandbox = os.path.join(OUT, "sandbox")
    prompt = EXTRACT + open(path).read()
    raw = os.path.join(sandbox, os.path.basename(path) + ".raw")
    r = subprocess.run(["codex", "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-C", sandbox,
                        "--output-schema", os.path.join(sandbox, "schema.json"), "-o", raw, "-"],
                       input=prompt, text=True, capture_output=True, timeout=1800)
    if r.returncode != 0 or not os.path.exists(raw):
        return f"fail {r.returncode}"
    json.dump(json.load(open(raw))["sessions"], open(dst, "w"), ensure_ascii=False, indent=1)
    os.remove(raw)
    return "ok"


def cmd_extract(args):
    specs = {s["session_id"]: s for s in json.load(open(os.path.join(OUT, "specs.json")))}
    outs = load_outputs()
    for sub in ("xbatches", "xout", "sandbox"):
        os.makedirs(os.path.join(OUT, sub), exist_ok=True)
    json.dump(SCHEMA, open(os.path.join(OUT, "sandbox", "schema.json"), "w"))
    ids = sorted(sid for sid in outs if sid in specs)
    random.Random(3).shuffle(ids)
    for k in range(0, len(ids), args.per_call):
        p = os.path.join(OUT, "xbatches", f"x{k // args.per_call:04d}.txt")
        if not os.path.exists(p):
            open(p, "w").write("\n\n".join(session_text(specs[s], outs[s]) for s in ids[k:k + args.per_call]))
    paths = sorted(glob.glob(os.path.join(OUT, "xbatches", "*.txt")))
    with ThreadPoolExecutor(args.jobs) as ex:
        res = list(ex.map(run_extract_batch, paths))
    print(Counter(r.split()[0] for r in res))


def cmd_score(args):
    from rewrite import matches, resolve_person  # noqa: E402
    specs = {s["session_id"]: s for s in json.load(open(os.path.join(OUT, "specs.json")))}
    outs = load_outputs()
    got = {}
    for p in glob.glob(os.path.join(OUT, "xout", "*.txt")):
        for s in json.load(open(p)):
            got[s["session_id"]] = s["facts"]
    worlds = {}
    rows, spurious, ev_agree = [], [], []
    for sid, facts in got.items():
        spec = specs[sid]
        wid = spec["world"]
        if wid not in worlds:
            worlds[wid] = json.load(open(os.path.join(SRC, wid, "world.json")))
        w = worlds[wid]
        F = {f["id"]: f for f in w["facts"]}
        used = set()
        for fs in spec.get("facts", []):
            g = F[fs["fact_id"]]
            hits = [k for k, ex in enumerate(facts) if matches(g, ex, w)]
            ok = bool(hits)
            gold_turns = {i for i, t in enumerate(outs[sid]["turns"]) if fs["fact_id"] in (t.get("conveys") or []) + (t.get("names") or [])}
            if ok:
                used.update(hits)
                # Does the extractor's evidence cover every user turn the writer annotated for this fact?
                ev_agree.append(float(gold_turns <= set(facts[hits[0]]["turns"])))
            lang = spec["lang"]
            rows.append({"session": sid, "fact": fs["fact_id"], "attr": g["attr"], "lang": lang, "split": fs["split"], "ok": ok})
        for k, ex in enumerate(facts):
            if k not in used:
                spurious.append({"session": sid, "topic_session": "topic" in spec, "extracted": ex})
    agg = lambda key: {k: {"n": len(v), "recoverable": round(sum(v) / len(v), 3)}
                       for k, v in sorted({kk: [r["ok"] for r in rows if r[key] == kk] for kk in {r[key] for r in rows}}.items())}
    out = {"sessions_checked": len(got), "facts": len(rows),
           "recoverable": round(sum(r["ok"] for r in rows) / max(1, len(rows)), 3),
           "by_lang": agg("lang"), "by_attr": agg("attr"), "by_split": agg("split"),
           "evidence_turns_covered": round(sum(ev_agree) / max(1, len(ev_agree)), 3),
           "extra_extractions": len(spurious), "extra_in_topic_sessions": sum(s["topic_session"] for s in spurious),
           "failures": [r for r in rows if not r["ok"]], "extras": spurious}
    json.dump(out, open(os.path.join(OUT, "recoverability.json"), "w"), ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in out.items() if k not in ("failures", "extras")}, indent=1))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--per-batch", type=int, default=25)
    b = sub.add_parser("build")
    b.add_argument("--partial", action="store_true")
    e = sub.add_parser("extract")
    e.add_argument("--jobs", type=int, default=5)
    e.add_argument("--per-call", type=int, default=8)
    sub.add_parser("score")
    args = ap.parse_args()
    {"plan": cmd_plan, "build": cmd_build, "extract": cmd_extract, "score": cmd_score}[args.cmd](args)


if __name__ == "__main__":
    main()
