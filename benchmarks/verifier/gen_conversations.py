"""Generate the fixed pilot pack of short personal conversations (Turkish / English / code-switched).

The generator is a non-Claude family (default: Gemma 4 31B on DeepInfra) so that neither the extractors nor the
later verifier share a family with the conversation author. Scenarios are sampled with a fixed seed from persona
archetypes and memory phenomena (relationships, places, plans vs facts, negations, time scope, corrections,
encounters vs ownership, explicit forget requests, noise turns). Output: data/conversations.jsonl and a generation
log in data/generation_log.md. Re-running skips conversations already on disk.

Run from benchmarks/verifier:  python -I gen_conversations.py [--count 100] [--model di:google/gemma-4-31B-it]
"""
import argparse, datetime as dt, hashlib, json, os, random, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import llm  # noqa: E402

DATA = os.path.join(HERE, "data")
NS = uuid.UUID("9b1f1a6e-2c57-4c2e-9d0a-5d2f3c1e7b40")

PERSONAS = [
    "a university student in Istanbul", "a software engineer in Berlin", "a nurse in Izmir", "a freelance illustrator in Lisbon",
    "a high-school teacher in Ankara", "a startup founder in London", "a retired civil servant in Antalya", "a PhD student in Amsterdam",
    "a pharmacist in Bursa", "a chef who recently moved to Rotterdam", "a lawyer in Eskisehir", "a logistics planner in Mersin",
    "a musician in Paris", "a dentist in Gaziantep", "a product manager in Munich", "a parent of two in Konya",
    "an architect in Trabzon", "a flight attendant based in Istanbul", "a nurse doing shifts in Vienna", "a translator in Edirne",
    "a physiotherapist in Samsun", "a data analyst in Dublin", "a bookshop owner in Kadikoy", "a motorcycle courier in Izmir",
]
PHENOMENA = {
    "relationship": "facts about OTHER people (sister, partner, friend, parent, roommate): their city, job, habits, health; the user must not share these attributes",
    "place_time": "where the user lived BEFORE versus where they live NOW, with explicit time words (last year, since March, until 2024)",
    "plan_vs_fact": "a plan or intention (thinking of moving, might switch jobs, maybe adopt) that has NOT happened, stated clearly as a plan",
    "negation": "an explicit negation or a quitting statement (not vegetarian, don't drink coffee anymore, no longer work there)",
    "correction": "the user corrects something said EARLIER in the same conversation (actually it was my brother, not my cousin; I meant Tuesday)",
    "encounter_vs_ownership": "an encounter or event (found kittens, borrowed a friend's car, visited a dog shelter) that does NOT imply ownership or commitment",
    "resolution": "an earlier event in the conversation gets a resolution later (the kittens were rehomed, the exam is over, the car was returned)",
    "forget_request": "the user explicitly asks the assistant to forget or stop remembering one thing mentioned earlier",
    "noise": "turns with NO personal information: generic questions, a recipe, a translation request, small talk about weather",
    "credential_like": "the user pastes something that looks like a password or an API key while asking for help (use an obviously fake value)",
    "ambiguous_pronoun": "a sentence where the subject is ambiguous without context (she got the job; he moved out) and only context tells who",
    "conditional": "a conditional or hypothetical (if I get the visa I'll move; I would adopt a dog if my flat allowed it)",
}
LANG_MODES = [("tr", 40), ("en", 35), ("mixed", 25)]

SYSTEM = (
    "You write realistic chat transcripts between a person and an AI assistant for a research dataset about personal memory. "
    "Return ONLY a JSON object, no prose, no code fence. The person is fictional; invent names, places and details freely but keep "
    "them internally consistent. Keep user messages natural, short to medium (one to four sentences), as people really type: "
    "occasional typos, no bullet lists. Assistant replies must be brief (one or two sentences) and must never state new facts about "
    "the person. Do not use the words 'remember' or 'memory' unless the scenario asks for a forget request."
)

TEMPLATE = """Write one conversation.

Person: {persona}.
Language: {lang_rule}
Number of user turns: {turns} (the assistant answers after each user turn, so {turns} user turns and {turns} assistant turns, alternating, user first).
The conversation must naturally contain these phenomena (spread across different user turns, do not label them):
{phenomena}
Also include at least two ordinary user turns with real durable facts about the person (job, city, a preference, a family member), stated plainly.

Output JSON exactly like this:
{{"turns":[{{"role":"user","text":"..."}},{{"role":"assistant","text":"..."}}, ...]}}
"""

LANG_RULES = {
    "tr": "Turkish only (natural everyday Turkish, Turkish characters).",
    "en": "English only.",
    "mixed": "Turkish and English code-switched the way bilingual people in Turkey text: mostly Turkish with English words, phrases and some full English sentences mixed in.",
}


def scenarios(count, seed):
    rng = random.Random(seed)
    modes = [m for m, n in LANG_MODES for _ in range(n)]
    rng.shuffle(modes)
    modes = (modes * (count // len(modes) + 1))[:count]
    out = []
    keys = list(PHENOMENA)
    for i in range(count):
        persona = PERSONAS[i % len(PERSONAS)]
        k = rng.choice([2, 3, 3, 4])
        chosen = rng.sample(keys, k)
        if "resolution" in chosen and "encounter_vs_ownership" not in chosen:
            chosen.append("encounter_vs_ownership")
        turns = rng.choice([8, 9, 10, 11, 12, 13, 14])
        out.append(dict(conversation_id=f"c{i + 1:03d}", persona=persona, lang=modes[i], phenomena=chosen, turns=turns))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--seed", type=int, default=20261024)
    ap.add_argument("--model", default="di:google/gemma-4-31B-it")
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()
    os.makedirs(DATA, exist_ok=True)
    path = os.path.join(DATA, "conversations.jsonl")
    done = set()
    if os.path.exists(path):
        done = {json.loads(l)["conversation_id"] for l in open(path, encoding="utf-8") if l.strip()}
    todo = [s for s in scenarios(a.count, a.seed) if s["conversation_id"] not in done]
    base = dt.datetime(2026, 9, 1, 9, 0, tzinfo=dt.timezone.utc)
    prompt_hash = hashlib.sha256((SYSTEM + TEMPLATE).encode()).hexdigest()[:16]

    def work(s):
        user = TEMPLATE.format(persona=s["persona"], lang_rule=LANG_RULES[s["lang"]], turns=s["turns"],
                               phenomena="\n".join(f"- {PHENOMENA[p]}" for p in s["phenomena"]))
        for attempt in range(3):
            r = llm.call(a.model, SYSTEM, user, extra={"temperature": 0.9})
            if r.get("error"):
                return dict(s, error=r["error"], cost=r.get("cost", 0.0))
            try:
                turns = json.loads(llm.strip_fence(r["text"]))["turns"]
                assert isinstance(turns, list) and len(turns) >= 4
                assert all(t.get("role") in ("user", "assistant") and isinstance(t.get("text"), str) and t["text"].strip() for t in turns)
                assert turns[0]["role"] == "user"
            except Exception:
                continue
            idx = int(s["conversation_id"][1:])
            t0 = base + dt.timedelta(days=idx % 50, hours=idx % 9)
            out_turns = []
            for j, t in enumerate(turns):
                mid = str(uuid.uuid5(NS, f"{s['conversation_id']}/{j}"))
                out_turns.append(dict(id=mid, role=t["role"], text=t["text"].strip(),
                                      createdAt=(t0 + dt.timedelta(minutes=3 * j)).strftime("%Y-%m-%dT%H:%M:%SZ")))
            return dict(s, model=a.model, prompt_hash=prompt_hash, generated_at=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        cost=r.get("cost", 0.0), tokens_in=r.get("tokens_in"), tokens_out=r.get("tokens_out"), attempts=attempt + 1, turns=out_turns)
        return dict(s, error="no valid JSON after 3 attempts", cost=0.0)

    import concurrent.futures as cf
    n_ok, n_err, cost = 0, 0, 0.0
    with open(path, "a", encoding="utf-8") as f, cf.ThreadPoolExecutor(a.workers) as ex:
        for r in ex.map(work, todo):
            cost += r.get("cost", 0.0)
            if r.get("error"):
                n_err += 1; print("ERR", r["conversation_id"], r["error"], flush=True); continue
            f.write(json.dumps(r, ensure_ascii=False) + "\n"); f.flush(); n_ok += 1
    with open(os.path.join(DATA, "generation_log.md"), "a", encoding="utf-8") as log:
        log.write(f"- {dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d %H:%M')}Z: model `{a.model}`, seed {a.seed}, prompt sha256[:16] `{prompt_hash}` "
                  f"(SYSTEM + TEMPLATE in gen_conversations.py), temperature 0.9; {n_ok} conversations written, {n_err} failed, "
                  f"reported cost ${cost:.4f}.\n")
    print(f"done: {n_ok} ok, {n_err} failed, cost ${cost:.4f}, phase spent ${llm.phase_spent():.4f}")


if __name__ == "__main__":
    main()
