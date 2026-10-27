"""Typed world graph for the memory-agent benchmark: people, projects and events with versioned facts.

Everything here is programmatic and seeded, so every question's answer and gold evidence can be computed rather than
labelled. A world is the archive owner's life over ~33 months: people they know (with deliberately duplicated first
names), projects whose lead, deadline and team change, and dated events (dinners, meetings, trips) with attendees.
Each attribute is a list of versions; every version is later stated in exactly one user message (see render.py).
Unrealised plans ("thinking of moving to X") are stored as distractor facts that never change state.
"""
import datetime as dt
import random
from dataclasses import dataclass, field, asdict

START = dt.date(2024, 1, 1)
END = dt.date(2026, 9, 30)

FIRST = ["Elif", "Zeynep", "Mert", "Can", "Ayşe", "Deniz", "Burak", "Ece", "Kaan", "Selin", "Emre", "Cem", "Defne",
         "Ozan", "Naz", "Barış", "İrem", "Onur", "Melis", "Tolga", "Gizem", "Umut", "Ceren", "Kerem", "Pınar", "Arda",
         "Seda", "Efe", "Duygu", "Yiğit", "Lukas", "Sofia", "Marco", "Hannah", "Daniel", "Lena"]
LAST = ["Kaya", "Yılmaz", "Demir", "Şahin", "Çelik", "Aydın", "Öztürk", "Arslan", "Doğan", "Koç", "Kurt", "Özdemir",
        "Aksoy", "Polat", "Erdem", "Tekin", "Güneş", "Bulut", "Keskin", "Ünal", "Weber", "Rossi", "Novak", "Berg"]
# (key, Turkish name, English name)
CITIES = [("istanbul", "İstanbul", "Istanbul"), ("ankara", "Ankara", "Ankara"), ("izmir", "İzmir", "Izmir"),
          ("bursa", "Bursa", "Bursa"), ("antalya", "Antalya", "Antalya"), ("eskisehir", "Eskişehir", "Eskisehir"),
          ("berlin", "Berlin", "Berlin"), ("amsterdam", "Amsterdam", "Amsterdam"), ("london", "Londra", "London"),
          ("munich", "Münih", "Munich"), ("lisbon", "Lizbon", "Lisbon"), ("vienna", "Viyana", "Vienna")]
COMPANIES = ["Mavi Enerji", "Kuzey Lojistik", "Nova Bank", "Lumen Labs", "Ferro Robotics", "Delta Sağlık",
             "Orbit Games", "Yeşil Gıda", "Brightline Consulting", "Akdeniz Turizm", "Başak Tarım", "Halcyon Studio"]
PROJECTS = ["Martı", "Kestane", "Poyraz", "Lodos", "Safir", "Zümrüt", "Orion", "Vega", "Kuzgun", "Sardunya",
            "Helios", "Tundra"]
# Relations are unique per person among people sharing a first name, so a mention like "my cousin Elif" stays
# resolvable; fact messages still use the full name for those people (see render.py).
RELATIONS = ["colleague", "university_friend", "cousin", "neighbour", "gym_friend", "school_friend", "client",
             "flatmate", "former_colleague", "climbing_friend", "manager", "friend"]
EVENT_KINDS = ["dinner", "coffee", "meeting", "conference", "hike", "concert", "lunch", "workshop"]


@dataclass
class Fact:
    id: str
    subject: str          # entity id: person "p03", project "j02", event "e14"
    attr: str             # city | employer | lead | deadline | member | event | plan_city
    value: object         # city key, company, person id, ISO date, (person id, "join"|"leave"), event dict
    valid_from: str       # ISO date the state took effect
    version: int          # 0 for the initial value
    stated_on: str = ""   # ISO date of the message that states it (set when scheduling)


@dataclass
class Person:
    id: str
    first: str
    last: str
    relation: str

    @property
    def full(self):
        return f"{self.first} {self.last}"


@dataclass
class World:
    seed: int
    owner: str
    people: list = field(default_factory=list)
    projects: list = field(default_factory=list)   # dicts {id, name}
    facts: list = field(default_factory=list)

    def person(self, pid):
        return next(p for p in self.people if p.id == pid)

    def project(self, jid):
        return next(j for j in self.projects if j["id"] == jid)

    def versions(self, subject, attr):
        return sorted((f for f in self.facts if f.subject == subject and f.attr == attr), key=lambda f: f.valid_from)

    def latest(self, subject, attr, at=None):
        vs = [f for f in self.versions(subject, attr) if at is None or f.valid_from <= at]
        return vs[-1] if vs else None

    def to_json(self):
        return {"seed": self.seed, "owner": self.owner, "people": [asdict(p) for p in self.people],
                "projects": self.projects, "facts": [asdict(f) for f in self.facts]}


def _rand_date(rng, lo, hi):
    return lo + dt.timedelta(days=rng.randint(0, max(0, (hi - lo).days)))


def _change_dates(rng, n, lo=START, hi=END):
    """n sorted state-change dates; the first is the initial value's date, later ones at least 45 days apart."""
    while True:
        ds = sorted(_rand_date(rng, lo, hi) for _ in range(n))
        ds[0] = min(ds[0], lo + dt.timedelta(days=rng.randint(0, 200)))
        if all((b - a).days >= 45 for a, b in zip(ds, ds[1:])):
            return ds


def _versions_count(rng, weights=(0.25, 0.45, 0.30)):
    return rng.choices([1, 2, 3], weights=weights)[0]


def build_world(seed, n_people=30, n_projects=8, n_events=60):
    rng = random.Random(seed)
    w = World(seed=seed, owner="owner")
    nid = iter(range(10_000))

    def fid():
        return f"f{next(nid):04d}"

    # People: draw first names so that three first names are shared by two people each.
    firsts = rng.sample(FIRST, n_people - 3)
    firsts += rng.sample(firsts, 3)
    rng.shuffle(firsts)
    used_full = set()
    for i, first in enumerate(firsts):
        taken = {p.relation for p in w.people if p.first == first}
        rel = rng.choice([r for r in RELATIONS if r not in taken])
        while True:
            last = rng.choice(LAST)
            if (first, last) not in used_full:
                used_full.add((first, last))
                break
        w.people.append(Person(id=f"p{i:02d}", first=first, last=last, relation=rel))

    city_keys = [c[0] for c in CITIES]
    for p in w.people:
        for attr, pool in (("city", city_keys), ("employer", COMPANIES)):
            ds = _change_dates(rng, _versions_count(rng))
            vals = rng.sample(pool, len(ds))
            for v, (d, val) in enumerate(zip(ds, vals)):
                w.facts.append(Fact(fid(), p.id, attr, val, d.isoformat(), v))
        # Unrealised plan after the latest move: a hard distractor for latest-value questions.
        if rng.random() < 0.25:
            last_city = w.latest(p.id, "city")
            after = dt.date.fromisoformat(last_city.valid_from) + dt.timedelta(days=20)
            if after < END:
                target = rng.choice([c for c in city_keys if c != last_city.value])
                w.facts.append(Fact(fid(), p.id, "plan_city", target, _rand_date(rng, after, END).isoformat(), 0))

    # Projects: lead and deadline are versioned; team membership is a join/leave log.
    pids = [p.id for p in w.people]
    for j, name in enumerate(rng.sample(PROJECTS, n_projects)):
        jid = f"j{j:02d}"
        w.projects.append({"id": jid, "name": name})
        start = _rand_date(rng, START, END - dt.timedelta(days=360))
        ds = _change_dates(rng, _versions_count(rng), start, END)
        for v, (d, lead) in enumerate(zip(ds, rng.sample(pids, len(ds)))):
            w.facts.append(Fact(fid(), jid, "lead", lead, d.isoformat(), v))
        ds = _change_dates(rng, _versions_count(rng), start, END)
        for v, d in enumerate(ds):
            deadline = d + dt.timedelta(days=rng.randint(60, 240))
            w.facts.append(Fact(fid(), jid, "deadline", deadline.isoformat(), d.isoformat(), v))
        members = rng.sample(pids, rng.randint(3, 6))
        for m in members:
            jd = _rand_date(rng, start, END - dt.timedelta(days=60))
            w.facts.append(Fact(fid(), jid, "member", [m, "join"], jd.isoformat(), 0))
            if rng.random() < 0.25:
                ld = _rand_date(rng, jd + dt.timedelta(days=30), END)
                w.facts.append(Fact(fid(), jid, "member", [m, "leave"], ld.isoformat(), 1))

    # Events: attendee popularity is skewed so a few people recur often enough for count questions.
    weights = [1.0 / (r + 1) ** 0.8 for r in range(len(pids))]
    order = rng.sample(pids, len(pids))
    for e in range(n_events):
        d = _rand_date(rng, START, END)
        k = rng.choices([1, 2, 3], weights=(0.6, 0.3, 0.1))[0]
        att = []
        while len(att) < k:
            p = rng.choices(order, weights=weights)[0]
            if p not in att:
                att.append(p)
        kind = rng.choice(EVENT_KINDS)
        proj = rng.choice(w.projects)["id"] if kind in ("meeting", "workshop") or rng.random() < 0.2 else None
        ev = {"kind": kind, "date": d.isoformat(), "attendees": att, "city": rng.choice(city_keys), "project": proj}
        w.facts.append(Fact(fid(), f"e{e:02d}", "event", ev, d.isoformat(), 0))

    w.facts.sort(key=lambda f: f.valid_from)
    return w
