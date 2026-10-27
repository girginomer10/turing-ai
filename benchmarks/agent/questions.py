"""Question templates with computed answers and gold evidence (fact ids, mapped to message ids by the caller).

All answers are taken "now" = the archive's end date, so latest-value questions have stale versions as distractors.
Classes for the first go/no-go: latest_value, two_hop, aggregate (plus a small one_hop control that should saturate).
Questions are asked in Turkish or English independently of the language of the evidence messages.
"""
import random
from collections import Counter, defaultdict

from render import CITY_EN, CITY_TR, date_en, date_tr, gen, loc

ACT_TR = {"dinner": "akşam yemeği yediğim", "coffee": "kahve içtiğim", "meeting": "toplantı yaptığım",
          "conference": "konferansa gittiğim", "hike": "yürüyüşe çıktığım", "concert": "konsere gittiğim",
          "lunch": "öğle yemeği yediğim", "workshop": "atölye çalışması yaptığım"}
ACT_EN = {"dinner": "had dinner with", "coffee": "grabbed coffee with", "meeting": "had a meeting with",
          "conference": "went to a conference with", "hike": "went hiking with", "concert": "went to a concert with",
          "lunch": "had lunch with", "workshop": "ran a workshop with"}


def _city_answer(key):
    return {"type": "city", "value": key, "aliases": sorted({CITY_TR[key], CITY_EN[key]})}


def _answer(attr, value, w):
    if attr == "city":
        return _city_answer(value)
    if attr == "employer":
        return {"type": "company", "value": value, "aliases": [value]}
    if attr == "lead":
        p = w.person(value)
        unique = sum(1 for x in w.people if x.first == p.first) == 1
        return {"type": "person", "value": value, "aliases": [p.full] + ([p.first] if unique else [])}
    if attr == "deadline":
        return {"type": "date", "value": value, "aliases": [date_tr(value), date_en(value)]}
    raise ValueError(attr)


def _round_robin(items, key, n, rng):
    """Up to n items, cycling over template types so no single template dominates a class."""
    by_t = defaultdict(list)
    for item in items:
        by_t[key(item)].append(item)
    for t in by_t:
        rng.shuffle(by_t[t])
    picked = []
    while len(picked) < n and any(by_t.values()):
        for t in sorted(by_t):
            if by_t[t] and len(picked) < n:
                picked.append(by_t[t].pop())
    return picked


def current_team(w, jid):
    state = {}
    for f in sorted(w.versions(jid, "member"), key=lambda f: f.valid_from):
        state[f.value[0]] = f.value[1]
    return sorted(p for p, s in state.items() if s == "join")


def generate(w, seed, per_class=10, controls=5):
    rng = random.Random(seed * 104729 + 3)
    out = []

    def q(cls, template, tr, en, answer, facts, **extra):
        lang = rng.choice(["tr", "en"])
        out.append({"class": cls, "template": template, "lang": lang, "question": tr if lang == "tr" else en,
                    "question_tr": tr, "question_en": en, "answer": answer, "gold_facts": [f.id for f in facts],
                    **extra})

    people = {p.id: p for p in w.people}
    projects = {j["id"]: j["name"] for j in w.projects}

    # ---- latest_value: the attribute changed at least once
    cands = []
    for p in w.people:
        for attr in ("city", "employer"):
            if len(w.versions(p.id, attr)) >= 2:
                cands.append((p.id, attr))
    for jid in projects:
        for attr in ("lead", "deadline"):
            if len(w.versions(jid, attr)) >= 2:
                cands.append((jid, attr))
    for subj, attr in _round_robin(cands, lambda c: c[1], per_class, rng):
        f = w.latest(subj, attr)
        stale = [v.id for v in w.versions(subj, attr) if v.id != f.id]
        if attr in ("city", "employer"):
            n = people[subj].full
            tr, en = {"city": (f"{n} şu an hangi şehirde yaşıyor?", f"Which city does {n} live in now?"),
                      "employer": (f"{n} şu anda nerede çalışıyor?", f"Where does {n} work these days?")}[attr]
        else:
            j = projects[subj]
            tr, en = {"lead": (f"{j} projesini şu an kim yönetiyor?", f"Who currently leads the {j} project?"),
                      "deadline": (f"{j} projesi için en son açıklanan teslim tarihi ne?",
                                   f"What is the most recently announced deadline for {j}?")}[attr]
        q("latest_value", f"latest_{attr}", tr, en, _answer(attr, f.value, w), [f], stale_facts=stale)

    # ---- two_hop: the bridge entity is never named in the question
    pool = []
    for jid, j in projects.items():
        lead = w.latest(jid, "lead")
        pid = lead.value
        n_city = w.latest(pid, "city")
        pool.append(("lead_city", f"{j} projesinin şu anki lideri hangi şehirde yaşıyor?",
                     f"Which city does the current lead of {j} live in?", _city_answer(n_city.value), [lead, n_city], pid))
        emp = w.latest(pid, "employer")
        pool.append(("lead_employer", f"{j} projesini şu an yöneten kişi hangi şirkette çalışıyor?",
                     f"Which company does the person currently leading {j} work for?",
                     _answer("employer", emp.value, w), [lead, emp], pid))
    ever_led = defaultdict(set)
    for jid in projects:
        for v in w.versions(jid, "lead"):
            ever_led[v.value].add(jid)
    for jid, j in projects.items():
        lead = w.latest(jid, "lead")
        if ever_led[lead.value] == {jid}:
            n = people[lead.value].full
            dl = w.latest(jid, "deadline")
            pool.append(("led_project_deadline", f"{gen(n)} şu an liderliğini yaptığı proje için en son açıklanan teslim tarihi ne?",
                         f"What is the most recently announced deadline of the project {n} is leading now?",
                         _answer("deadline", dl.value, w), [lead, dl], jid))
    events = [f for f in w.facts if f.attr == "event"]
    sig = Counter((e.value["kind"], e.value["date"], e.value["city"]) for e in events)
    for e in events:
        ev = e.value
        if len(ev["attendees"]) != 1 or sig[(ev["kind"], ev["date"], ev["city"])] != 1:
            continue
        pid = ev["attendees"][0]
        emp = w.latest(pid, "employer")
        ctr, cen = CITY_TR[ev["city"]], CITY_EN[ev["city"]]
        pool.append(("event_person_employer",
                     f"{date_tr(ev['date'])} tarihinde {loc(ctr)} birlikte {ACT_TR[ev['kind']]} kişi şu an nerede çalışıyor?",
                     f"Where does the person I {ACT_EN[ev['kind']]} in {cen} on {date_en(ev['date'])} work now?",
                     _answer("employer", emp.value, w), [e, emp], pid))
    for t, tr, en, ans, facts, bridge in _round_robin(pool, lambda x: x[0], per_class, rng):
        q("two_hop", t, tr, en, ans, facts, bridge=bridge)

    # ---- aggregate: counting needs every supporting message, not just the best one
    agg = []
    per_year = defaultdict(list)
    for e in events:
        for a in e.value["attendees"]:
            per_year[(a, e.value["date"][:4])].append(e)
    for (pid, y), es in per_year.items():
        if 2 <= len(es) <= 6:
            n = people[pid].full
            agg.append(("count_meetings_year", f"{y} yılında {n} ile kaç kez bir araya geldim?",
                        f"How many times did I meet up with {n} in {y}?", len(es), es))
    now_city, moved_away = defaultdict(list), defaultdict(list)
    for p in w.people:
        latest = w.latest(p.id, "city")
        now_city[latest.value].append(latest)
        for key in {v.value for v in w.versions(p.id, "city")} - {latest.value}:
            moved_away[key].append(latest)
    for key, fs in now_city.items():
        if 2 <= len(fs) <= 5:
            agg.append(("count_city_now", f"Tanıdıklarımdan kaç kişi şu an {loc(CITY_TR[key])} yaşıyor?",
                        f"How many people I know live in {CITY_EN[key]} right now?", len(fs), fs + moved_away[key]))
    for jid, j in projects.items():
        team = current_team(w, jid)
        if 2 <= len(team) <= 6:
            agg.append(("count_team_now", f"{j} ekibine katılıp hâlâ ekipte olan kaç kişi var?",
                        f"How many people who joined the {j} team are still on it?", len(team), w.versions(jid, "member")))
    for t, tr, en, n, facts in _round_robin(agg, lambda x: x[0], per_class, rng):
        q("aggregate", t, tr, en, {"type": "count", "value": n, "aliases": [str(n)]}, facts)

    # ---- one_hop control: a single, never-changed value
    ctrl = [(p.id, a) for p in w.people for a in ("city", "employer") if len(w.versions(p.id, a)) == 1]
    rng.shuffle(ctrl)
    for pid, attr in ctrl[:controls]:
        f = w.latest(pid, attr)
        n = people[pid].full
        tr, en = {"city": (f"{n} şu an hangi şehirde yaşıyor?", f"Which city does {n} live in now?"),
                  "employer": (f"{n} şu anda nerede çalışıyor?", f"Where does {n} work these days?")}[attr]
        q("one_hop", f"control_{attr}", tr, en, _answer(attr, f.value, w), [f])
    return out
