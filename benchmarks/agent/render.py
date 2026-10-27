"""Template rendering of a world into a dated chat archive (Turkish / English / code-switched).

Every fact version becomes exactly one user message in a session that also holds acknowledgements and small talk;
the rest of the archive is noise sessions (recipes, code questions, translations) and name-mention distractors that
talk about a person or project without changing any state. Messages carry the ids of the facts they state; those ids
are gold labels for evaluation and must never be shown to a retriever or controller.

Template text is the deterministic floor. An LLM rewrite of fact-bearing turns (rewrite.py) replaces `text` and keeps
`template_text`, so the same world can be evaluated on either surface.
"""
import datetime as dt
import random

from world import CITIES, END, START

CITY_TR = {k: tr for k, tr, _ in CITIES}
CITY_EN = {k: en for k, _, en in CITIES}
MONTH_TR = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"]
MONTH_EN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
            "November", "December"]
REL_TR = {"colleague": "iş arkadaşım", "university_friend": "üniversiteden arkadaşım", "cousin": "kuzenim",
          "neighbour": "komşum", "gym_friend": "spor salonundan arkadaşım", "school_friend": "lise arkadaşım",
          "client": "müşterim", "flatmate": "eski ev arkadaşım", "former_colleague": "eski iş arkadaşım",
          "climbing_friend": "tırmanış arkadaşım", "manager": "yöneticim", "friend": "arkadaşım"}
REL_EN = {"colleague": "my colleague", "university_friend": "my friend from university", "cousin": "my cousin",
          "neighbour": "my neighbour", "gym_friend": "my gym buddy", "school_friend": "my old school friend",
          "client": "my client", "flatmate": "my old flatmate", "former_colleague": "my former colleague",
          "climbing_friend": "my climbing partner", "manager": "my manager", "friend": "my friend"}
EVENT_TR = {"dinner": "akşam yemeği yedik", "coffee": "kahve içtik", "meeting": "toplantı yaptık",
            "conference": "bir konferansa gittik", "hike": "yürüyüşe çıktık", "concert": "konsere gittik",
            "lunch": "öğle yemeği yedik", "workshop": "bir atölye çalışması yaptık"}
EVENT_EN = {"dinner": "had dinner with {n}", "coffee": "grabbed coffee with {n}", "meeting": "had a meeting with {n}",
            "conference": "went to a conference with {n}", "hike": "went hiking with {n}",
            "concert": "went to a concert with {n}", "lunch": "had lunch with {n}", "workshop": "ran a workshop with {n}"}
EVENT_MIX = {"dinner": "dinner'a çıktık", "coffee": "coffee içtik", "meeting": "bir meeting yaptık",
             "conference": "conference'a gittik", "hike": "hiking yaptık", "concert": "concert'e gittik",
             "lunch": "lunch yedik", "workshop": "workshop yaptık"}

# ---------------------------------------------------------------- Turkish suffixes for proper nouns

VOWELS = "aeıioöuü"


def _lower_tr(s):
    return s.replace("I", "ı").replace("İ", "i").lower()


SILENT_H = {"hannah"}


def _harmony(word):
    w = _lower_tr(word)
    if w.split()[-1] in SILENT_H:
        w = w[:-1]
    last = next((c for c in reversed(w) if c in VOWELS), "e")
    back = last in "aıou"
    rounded = last in "oöuü"
    ends_vowel = w[-1] in VOWELS
    voiceless = w[-1] in "fstkçşhp"
    return back, rounded, ends_vowel, voiceless


def _four(back, rounded):
    return {(True, False): "ı", (False, False): "i", (True, True): "u", (False, True): "ü"}[(back, rounded)]


def loc(n):
    b, _, _, vl = _harmony(n)
    return f"{n}'{'t' if vl else 'd'}{'a' if b else 'e'}"


def abl(n):
    b, _, _, vl = _harmony(n)
    return f"{n}'{'t' if vl else 'd'}{'a' if b else 'e'}n"


def dat(n):
    b, _, ev, _ = _harmony(n)
    return f"{n}'{'y' if ev else ''}{'a' if b else 'e'}"


def acc(n):
    b, r, ev, _ = _harmony(n)
    return f"{n}'{'y' if ev else ''}{_four(b, r)}"


def gen(n):
    b, r, ev, _ = _harmony(n)
    return f"{n}'{'n' if ev else ''}{_four(b, r)}n"


def ins(n):
    b, _, ev, _ = _harmony(n)
    return f"{n}'{'y' if ev else ''}l{'a' if b else 'e'}"


def de(n):
    b, _, _, _ = _harmony(n)
    return f"{n} {'da' if b else 'de'}"


def date_tr(iso):
    d = dt.date.fromisoformat(iso)
    return f"{d.day} {MONTH_TR[d.month - 1]} {d.year}"


def date_en(iso):
    d = dt.date.fromisoformat(iso)
    return f"{d.day} {MONTH_EN[d.month - 1]} {d.year}"


# ---------------------------------------------------------------- fact sentences


class Renderer:
    def __init__(self, world, rng):
        self.w = world
        self.rng = rng
        firsts = [p.first for p in world.people]
        self.dup_first = {f for f in firsts if firsts.count(f) > 1}

    def pref(self, pid, lang):
        """Person reference: full name, bare first name (only when unambiguous), or relation + full name."""
        p = self.w.person(pid)
        r = self.rng.random()
        if r < 0.25:
            rel = (REL_EN if lang == "en" else REL_TR)[p.relation]
            return f"{rel} {p.full}"
        if r < 0.55 and p.first not in self.dup_first:
            return p.first
        return p.full

    def city(self, key, lang):
        return CITY_EN[key] if lang == "en" else CITY_TR[key]

    def when(self, event_iso, stated_iso, lang):
        gap = (dt.date.fromisoformat(stated_iso) - dt.date.fromisoformat(event_iso)).days
        d = dt.date.fromisoformat(event_iso)
        if lang == "en":
            return {0: "Today", 1: "Yesterday"}.get(gap, f"On {d.day} {MONTH_EN[d.month - 1]}")
        return {0: "Bugün", 1: "Dün"}.get(gap, f"{d.day} {loc(MONTH_TR[d.month - 1])}")

    def sentence(self, f, lang):
        w, c = self.w, self.rng.choice
        prev = None
        if f.version > 0:
            prev = next(v for v in w.versions(f.subject, f.attr) if v.version == f.version - 1)
        if f.attr in ("city", "employer", "plan_city"):
            p = self.pref(f.subject, lang)
        else:
            j = w.project(f.subject)["name"] if f.subject.startswith("j") else None

        if f.attr == "city":
            ct = self.city(f.value, lang)
            old = self.city(prev.value, lang) if prev else None
            if lang == "tr":
                opts = ([f"{p} {loc(ct)} yaşıyor bu arada.", f"{p} {loc(ct)} oturuyor, oraya gidersem uğrarım.",
                         f"{gen(p)} evi {loc(ct)}, geçen gün telefonda konuştuk."] if not prev else
                        [f"{p} {dat(ct)} taşındı, yeni evi çok güzelmiş.", f"{p} {abl(old)} {dat(ct)} taşınmış, yeni duydum.",
                         f"{p} artık {loc(ct)} yaşıyor.", f"Haberin var mı, {p} sonunda {dat(ct)} yerleşti."])
            elif lang == "en":
                opts = ([f"{p} lives in {ct}, by the way.", f"{p} is based in {ct} these days."] if not prev else
                        [f"{p} moved to {ct}, apparently the new place is great.",
                         f"{p} just relocated from {old} to {ct}.", f"{p} lives in {ct} now."])
            else:
                opts = ([f"Btw {p} {loc(ct)} yaşıyor.", f"{p} {loc(ct)} based, oraya gidersem uğrarım."] if not prev else
                        [f"{p} {dat(ct)} move etti, yeni ev super nice.", f"Btw {p} artık {loc(ct)} yaşıyor."])
            return c(opts)

        if f.attr == "plan_city":
            ct = self.city(f.value, lang)
            return c({"tr": [f"{p} {dat(ct)} taşınmayı düşünüyor ama henüz karar vermedi.",
                             f"{p} belki {dat(ct)} taşınırım diyor, kesin değil."],
                      "en": [f"{p} is thinking about moving to {ct}, nothing decided yet.",
                             f"{p} might move to {ct} at some point, not sure."],
                      "mix": [f"{p} {dat(ct)} move etmeyi düşünüyor, ama not sure yet."]}[lang])

        if f.attr == "employer":
            co, old = f.value, (prev.value if prev else None)
            if lang == "tr":
                opts = ([f"{p} {loc(co)} çalışıyor.", f"{p} şu sıralar {loc(co)} çalışıyor, işinden memnun."] if not prev else
                        [f"{p} {abl(old)} ayrılıp {loc(co)} başladı.", f"{p} yeni işe geçti: {co}.",
                         f"{p} artık {loc(co)} çalışıyor."])
            elif lang == "en":
                opts = ([f"{p} works at {co}.", f"{p} has been at {co} for a while and likes it."] if not prev else
                        [f"{p} left {old} and started at {co}.", f"{p} has a new job at {co}.", f"{p} works at {co} now."])
            else:
                opts = ([f"{p} {loc(co)} çalışıyor, pretty happy there."] if not prev else
                        [f"{p} {loc(co)} başladı, new job vibes.", f"{p} {abl(old)} quit etti, şimdi {loc(co)}."])
            return c(opts)

        if f.attr == "lead":
            p = self.pref(f.value, lang)
            old = self.pref(prev.value, lang) if prev else None
            if lang == "tr":
                opts = ([f"{j} projesinin lideri {p}.", f"{j} projesini {p} yönetiyor."] if not prev else
                        [f"{j} projesini artık {p} yönetiyor, {old} başka bir projeye geçti.",
                         f"{j} ekibinde liderlik değişti, yeni lider {p}.", f"{p}, {j} projesinin liderliğini devraldı."])
            elif lang == "en":
                opts = ([f"{p} is leading the {j} project.", f"{j} is run by {p}."] if not prev else
                        [f"{p} took over {j} from {old}.", f"The new lead on {j} is {p}."])
            else:
                opts = ([f"{j} projesinin lead'i {p}."] if not prev else
                        [f"{j} projesinde lead artık {p}.", f"{p} {j} projesini take over etti."])
            return c(opts)

        if f.attr == "deadline":
            if lang == "tr":
                d = date_tr(f.value)
                opts = ([f"{j} projesinin teslim tarihi {d}.", f"{j} için son tarih {d} olarak belirlendi."] if not prev else
                        [f"{j} projesinin teslim tarihi değişti, yeni tarih {d}.", f"{j} için yeni son tarih {d}."])
            elif lang == "en":
                d = date_en(f.value)
                opts = ([f"The {j} deadline is {d}.", f"{j} is due on {d}."] if not prev else
                        [f"{j} got pushed, the new deadline is {d}.", f"{j} moved again, now due {d}."])
            else:
                d = date_en(f.value)
                opts = ([f"{j} deadline: {d}, biraz tight."] if not prev else
                        [f"{j} deadline değişti, yeni tarih {d}.", f"{j} yine push'landı, yeni deadline {d}."])
            return c(opts)

        if f.attr == "member":
            pid, move = f.value
            p = self.pref(pid, lang)
            if lang == "tr":
                opts = ([f"{de(p)} {j} ekibine katıldı.", f"{j} ekibine yeni biri geldi: {p}."] if move == "join" else
                        [f"{p} {j} ekibinden ayrıldı.", f"{p} artık {j} projesinde değil."])
            elif lang == "en":
                opts = ([f"{p} joined the {j} team.", f"{j} has a new team member: {p}."] if move == "join" else
                        [f"{p} left the {j} team.", f"{p} is no longer on {j}."])
            else:
                opts = ([f"{p} {j} team'ine join etti."] if move == "join" else [f"{p} {j} team'inden çıktı."])
            return c(opts)

        if f.attr == "event":
            ev = f.value
            refs = [self.pref(a, lang) for a in ev["attendees"]]
            ct = self.city(ev["city"], lang)
            when = self.when(ev["date"], f.stated_on, lang)
            proj = w.project(ev["project"])["name"] if ev["project"] else None
            if lang == "en":
                names = refs[0] if len(refs) == 1 else ", ".join(refs[:-1]) + " and " + refs[-1]
                s = f"{when} I {EVENT_EN[ev['kind']].format(n=names)} in {ct}."
                return s + (f" We talked about {proj}." if proj else "")
            withp = ins(refs[0]) if len(refs) == 1 else ", ".join(refs[:-1]) + " ve " + refs[-1] + " ile"
            act = (EVENT_TR if lang == "tr" else EVENT_MIX)[ev["kind"]]
            s = f"{when} {withp} {loc(ct)} {act}."
            if proj:
                s += f" {acc(proj)} konuştuk." if lang == "tr" else f" {proj} update'lerini konuştuk."
            return s
        raise ValueError(f.attr)


# ---------------------------------------------------------------- small talk, noise, distractors

PREFIX = {"tr": ["", "", "Aklıma gelmişken, ", "Bugün bir haber aldım: ", "Not alır mısın: "],
          "en": ["", "", "Quick update: ", "Oh, and ", "Note for later: "],
          "mix": ["", "", "Quick update: ", "Aklıma gelmişken, "]}
# Event sentences open with a time word (Bugün, Yesterday, 14 Mart'ta), so only a colon-style prefix fits.
EVENT_PREFIX = {"tr": ["", "", "Not alır mısın: "], "en": ["", "", "Note for later: "], "mix": ["", "", "Not alır mısın: "]}
# Replies that share the acknowledgement pool, so an "ack" does not identify a fact turn.
FOLLOW = {"tr": ["Başka eklemek istediğin bir şey var mı?", "Bununla ilgili yardımcı olabileceğim bir şey olursa söyle."],
          "en": ["Anything else you want to add?", "Let me know if I can help with anything related."],
          "mix": ["Başka bir şey var mı?", "Let me know if I can help."]}
# Personal small talk with no fact about anyone; answered with the same short acknowledgements as fact turns.
CHATTER = {"tr": ["Bugün çok yorgunum.", "Bu hafta inanılmaz yoğun geçti.", "Sonunda okuduğum kitabı bitirdim.",
                  "Hava bugün çok güzel.", "Sabah koşuya çıktım, iyi geldi.", "Akşam film izleyeceğim galiba."],
           "en": ["I'm so tired today.", "This week has been crazy busy.", "Finally finished the book I was reading.",
                  "The weather is lovely today.", "Went for a run this morning, felt good."],
           "mix": ["Bugün çok tired hissediyorum.", "Bu hafta super busy geçti.", "Sabah run'a çıktım, iyi geldi."]}
ACK = {"tr": ["Güzel haber!", "Not ettim.", "Anladım, umarım her şey yolunda gider.", "Tamam, kaydettim.",
              "Vay, bu önemli bir değişiklik.", "Anladım. Başka bir şey var mı?"],
       "en": ["Good to know!", "Noted.", "Got it, hope it all goes well.", "Thanks for the update.",
              "That's a big change.", "Understood. Anything else?"],
       "mix": ["Not ettim!", "Got it.", "Anladım, good luck to them.", "Tamam, noted."]}
OPENERS = {"tr": [("Selam, nasılsın?", "İyiyim, teşekkürler! Sana nasıl yardımcı olabilirim?"),
                  ("Günaydın!", "Günaydın! Bugün ne yapıyoruz?"),
                  ("Biraz sohbet edelim mi?", "Tabii, dinliyorum.")],
           "en": [("Hey, how's it going?", "All good! What can I help you with?"),
                  ("Morning!", "Good morning! What's on your mind?")],
           "mix": [("Selam, quick question var.", "Tabii, sor bakalım."), ("Hey, müsait misin?", "Evet, buyur.")]}

FOODS_TR = ["mercimek çorbası", "menemen", "karnıyarık", "fırında makarna", "zeytinyağlı fasulye", "humus", "kısır"]
FOODS_EN = ["banana bread", "a quick pasta", "shakshuka", "lentil soup", "a chickpea curry", "pancakes"]
TECH = ["Python", "SQL", "JavaScript", "Swift", "Excel", "regex", "bash"]
TOPICS_TR = ["zaman yönetimi", "uyku düzeni", "bütçe yapmak", "İngilizce pratiği", "sunum hazırlamak", "koşuya başlamak"]
TOPICS_EN = ["time management", "sleep habits", "budgeting", "learning Spanish", "public speaking", "starting to run"]
PLACES_TR = ["Kapadokya", "Karadeniz", "Ege kıyıları", "Roma", "Prag", "Kaş"]
PLACES_EN = ["Cappadocia", "Rome", "Prague", "the Black Sea coast", "Porto", "Kyoto"]


def noise_exchange(rng, lang):
    c = rng.choice
    if lang == "en":
        k = rng.randrange(6)
        if k == 0:
            f = c(FOODS_EN)
            return [(f"Can you give me a simple recipe for {f}?", f"Sure, here's an easy version of {f}: start with the basics, keep the heat moderate and taste as you go.")]
        if k == 1:
            t = c(TECH)
            return [(f"How do I remove duplicates from a list in {t}?", f"In {t} the usual approach is to keep a set of seen values and skip repeats; I can show a snippet if you like.")]
        if k == 2:
            t = c(TOPICS_EN)
            return [(f"Any tips on {t}?", f"For {t}, start small, be consistent and track progress weekly.")]
        if k == 3:
            p = c(PLACES_EN)
            return [(f"What should I see in {p} if I only have two days?", f"In {p}, pick one neighbourhood per day and leave room for wandering.")]
        if k == 4:
            return [("Translate 'see you next week' into Turkish.", "'Haftaya görüşürüz.'")]
        return [("What's a good way to stay focused while working from home?", "A fixed start time, a separate desk and short breaks help most people.")]
    if lang == "mix":
        k = rng.randrange(4)
        if k == 0:
            t = c(TECH)
            return [(f"{loc(t)} bir list'ten duplicate'leri nasıl silerim?", f"{loc(t)} en basit yol görülen değerleri bir set'te tutmak.")]
        if k == 1:
            f = c(FOODS_TR)
            return [(f"Akşam {f} yapacağım, quick tips?", f"{f} için malzemeleri önceden hazırla, ateşi orta tut.")]
        if k == 2:
            return [("Bu cümleyi daha professional yazar mısın: 'toplantıyı erteleyelim'", "'Toplantıyı ileri bir tarihe almamızı önerebilir miyim?'")]
        t = c(TOPICS_TR)
        return [(f"{t} konusunda bir weekly plan önerir misin?", f"{t} için haftada üç kısa oturumla başla, sonra artır.")]
    k = rng.randrange(6)
    if k == 0:
        f = c(FOODS_TR)
        return [(f"{f} tarifi verir misin?", f"Tabii, {f} için temel malzemelerle başla, kısık ateşte pişir ve tadına bakarak ilerle.")]
    if k == 1:
        t = c(TECH)
        return [(f"{t} ile bir dosyadaki satırları nasıl sayarım?", f"{t} ile dosyayı satır satır okuyup bir sayaç artırabilirsin; istersen örnek yazayım.")]
    if k == 2:
        t = c(TOPICS_TR)
        return [(f"{t} için önerin var mı?", f"{t} için küçük adımlarla başla, düzenli ol ve haftalık takip et.")]
    if k == 3:
        p = c(PLACES_TR)
        return [(f"{p} için iki günlük bir gezi planı yapar mısın?", f"{p} için her güne bir bölge seç, akşamları serbest bırak.")]
    if k == 4:
        return [("'Haftaya görüşürüz' İngilizce nasıl denir?", "'See you next week.'")]
    return [("Evden çalışırken odaklanmak için ne yapmalıyım?", "Sabit bir başlangıç saati, ayrı bir masa ve kısa molalar çoğu kişiye iyi gelir.")]


def mention_distractor(rng, r, lang):
    """A turn that names a person or project but states no fact about them."""
    w = r.w
    if rng.random() < 0.6:
        pid = rng.choice(w.people).id
        p = r.pref(pid, lang)
        opts = {"tr": [(f"{gen(p)} doğum günü yaklaşıyor, hediye önerin var mı?", "Kitap, deneyim hediyesi ya da sevdiği bir hobiyle ilgili bir şey iyi olabilir."),
                       (f"{dat(p)} kısa bir teşekkür mesajı yazar mısın?", "Elbette: 'Desteğin için çok teşekkür ederim, çok işime yaradı.'"),
                       (f"{p} bana bir kitap önerdi ama adını unuttum, roman öneri listesi verir misin?", "Tabii, birkaç farklı türden roman önerebilirim.")],
                "en": [(f"{p}'s birthday is coming up, any gift ideas?", "A book, an experience voucher or something tied to a hobby usually works."),
                       (f"Can you draft a short thank-you note to {p}?", "Of course: 'Thanks so much for your help, it made a real difference.'")],
                "mix": [(f"{dat(p)} bir thank you mesajı yazar mısın?", "Tabii: 'Desteğin için çok teşekkürler!'")]}[lang]
        return rng.choice(opts), {"kind": "person", "id": pid}
    j = rng.choice(w.projects)
    n = j["name"]
    opts = {"tr": [(f"{n} toplantısı için gündem maddeleri önerir misin?", "Durum özeti, riskler, sonraki adımlar ve sorumlular iyi bir başlangıç olur."),
                   (f"{n} sunumu için bir başlık bul.", f"'{n}: Neredeyiz, nereye gidiyoruz?' nasıl olur?")],
            "en": [(f"Suggest an agenda for the {n} sync.", "Status, blockers, decisions needed and owners for next steps."),
                   (f"Give me a catchy title for the {n} slides.", f"How about '{n}: where we are and what's next'?")],
            "mix": [(f"{n} meeting için agenda önerir misin?", "Status, riskler, next steps ve owner'lar.")]}[lang]
    return rng.choice(opts), {"kind": "project", "id": j["id"]}


# ---------------------------------------------------------------- archive assembly


def _lang(rng, mix):
    return rng.choices(["tr", "en", "mix"], weights=mix)[0]


def _ts(day, minute):
    return dt.datetime.combine(day, dt.time(0, 0)) + dt.timedelta(minutes=minute)


def build_archive(world, seed, target_messages=2000, lang_mix=(0.55, 0.30, 0.15)):
    rng = random.Random(seed * 7919 + 1)
    style = random.Random(seed * 7919 + 2)  # reply styling only; never shifts the main stream
    r = Renderer(world, rng)
    end = END

    # When is each fact stated? A few days after it happens; events stay in the same calendar year.
    for f in world.facts:
        d = dt.date.fromisoformat(f.valid_from)
        off = rng.choice([0, 0, 1, 1, 2, 3, 5]) if f.attr == "event" else rng.randint(0, 20)
        s = min(d + dt.timedelta(days=off), end)
        if s.year != d.year:
            s = d
        f.stated_on = s.isoformat()

    # Fact sessions: one or two facts each.
    facts = sorted(world.facts, key=lambda f: (f.stated_on, f.id))
    sessions, i = [], 0
    while i < len(facts):
        group = [facts[i]]
        if i + 1 < len(facts) and rng.random() < 0.35:
            nxt = facts[i + 1]
            if (dt.date.fromisoformat(nxt.stated_on) - dt.date.fromisoformat(facts[i].stated_on)).days <= 3:
                group.append(nxt)
        i += len(group)
        day = dt.date.fromisoformat(max(f.stated_on for f in group))
        for f in group:  # relative time words ("dün") are relative to the session's day
            f.stated_on = day.isoformat()
        sessions.append({"day": day, "facts": group})

    def fact_session(s):
        lang = _lang(rng, lang_mix)
        turns = []
        if rng.random() < 0.4:
            turns.append((*rng.choice(OPENERS[lang]), [], None))
        for f in s["facts"]:
            sent = r.sentence(f, lang)
            pre = rng.choice((EVENT_PREFIX if f.attr == "event" else PREFIX)[lang])
            if pre and sent.startswith("Btw "):
                sent = sent[4:]
            if pre and sent.startswith("Haberin"):
                pre = ""
            text = pre + sent
            ack = rng.choice(ACK[lang])
            x = style.random()
            if x < 0.3:
                ack = style.choice(FOLLOW[lang])
            elif x < 0.6:
                ack = ack + " " + style.choice(FOLLOW[lang])
            turns.append((text, ack, [f.id], None))
            if rng.random() < 0.4:
                u, a = noise_exchange(rng, lang)[0]
                turns.append((*noise_pair(u, a, lang), [], None))
        return lang, turns

    def noise_pair(u, a, lang):
        # Noise must look like fact turns from the assistant's side: some become small talk answered with a bare
        # acknowledgement or follow-up, many replies open with one.
        x = style.random()
        if x < 0.4:
            return style.choice(CHATTER[lang]), style.choice(ACK[lang] if style.random() < 0.7 else FOLLOW[lang])
        if x < 0.7:
            return u, style.choice(ACK[lang]) + " " + a
        return u, a

    def noise_session():
        lang = _lang(rng, lang_mix)
        turns = []
        for _ in range(rng.randint(1, 3)):
            if rng.random() < 0.15:
                (u, a), tag = mention_distractor(rng, r, lang)
                if style.random() < 0.35:
                    a = style.choice(ACK[lang]) + " " + a
                turns.append((u, a, [], tag))
            else:
                u, a = noise_exchange(rng, lang)[0]
                turns.append((*noise_pair(u, a, lang), [], None))
        return lang, turns

    rendered = []
    for s in sessions:
        lang, turns = fact_session(s)
        rendered.append((s["day"], lang, turns))
    n_msgs = sum(2 * len(t) for _, _, t in rendered)
    while n_msgs < target_messages:
        day = START + dt.timedelta(days=rng.randint(0, (end - START).days))
        lang, turns = noise_session()
        rendered.append((day, lang, turns))
        n_msgs += 2 * len(turns)

    rendered.sort(key=lambda x: x[0])
    messages, sess_out = [], []
    cursor = dt.datetime(1970, 1, 1)
    for si, (day, lang, turns) in enumerate(rendered):
        sid = f"s{si:04d}"
        # Same-day sessions follow each other instead of overlapping.
        minute = rng.randint(7 * 60, 22 * 60)
        start = max(_ts(day, minute), cursor + dt.timedelta(minutes=rng.randint(5, 90)))
        minute = int((start - _ts(day, 0)).total_seconds() // 60)
        mids = []
        for u, a, fids, tag in turns:
            for role, text, fl in (("user", u, fids), ("assistant", a, [])):
                mid = f"m{len(messages):05d}"
                ts = min(_ts(day, minute), _ts(day, 23 * 60 + 59))
                m = {"id": mid, "session": sid, "ts": ts.isoformat(timespec="minutes"), "role": role,
                     "lang": lang, "text": text, "template_text": text, "facts": fl}
                if tag and role == "user":
                    m["distractor"] = tag
                messages.append(m)
                mids.append(mid)
                minute += rng.randint(1, 4)
        cursor = min(_ts(day, minute), _ts(day, 23 * 60 + 59))
        sess_out.append({"id": sid, "day": day.isoformat(), "lang": lang, "messages": mids})
    return messages, sess_out
