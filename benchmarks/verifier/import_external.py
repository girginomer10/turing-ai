#!/usr/bin/env python3
"""Parse the raw conversation batches written by external chat models (data/raw/*.txt) into data/conversations.jsonl.

The batches are JSON Lines, but the models make small mistakes (Gemini leaves inner quotes unescaped), so each conversation is parsed
with a tolerant pattern instead of json.loads. The generating model's `traps` field is kept as `claimed_traps`: it is the model's own
claim about what it planted, not a label, and must never be shown to annotators. Timestamps are derived from the per-turn `day`
offsets with a fixed seed so runs are reproducible.

Run from benchmarks/verifier:  python -I import_external.py
"""
import collections, datetime as dt, glob, hashlib, json, os, re, statistics, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "data", "raw")
OUT = os.path.join(HERE, "data", "conversations.jsonl")
NS = uuid.UUID("7d3a9a1e-5f0b-4c7e-8a55-2b9c4d6e1f30")
FAMILIES = {  # file prefix -> (family code, model name as the owner stated it)
    "chatgpt": ("gpt", "ChatGPT GPT 6 Astra Pro"), "gemini": ("gem", "Gemini 4 Argon"),
    "claude": ("cla", "Claude Opus 5.5"), "grok": ("grk", "Grok"),
}
TURN = re.compile(r'\{"role":"(user|assistant)","day":(\d+),"text":"(.*?)"\}(?=,\{"role"|\],"traps")', re.S)


def unescape(raw):
    try:
        return json.loads('"' + raw + '"')
    except ValueError:
        return raw.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def parse_line(line):
    persona = re.search(r'"persona":"(.*?)","lang"', line)
    lang = re.search(r'"lang":"(tr|en|mixed)"', line)
    body = line[line.index('"turns":['):]
    turns = [{"role": r, "day": int(d), "text": unescape(t).strip()} for r, d, t in TURN.findall(body)]
    traps = []
    m = re.search(r'"traps":(\[.*\])\}\s*$', line)
    if m:
        try: traps = json.loads(m.group(1))
        except ValueError: pass
    return (persona.group(1) if persona else ""), (lang.group(1) if lang else ""), turns, traps


def main():
    rows, problems = [], []
    counters = collections.Counter()
    for path in sorted(glob.glob(os.path.join(RAW, "*.txt"))):
        name = os.path.basename(path)
        prefix = name.split("_")[0]
        if prefix not in FAMILIES:
            print("skip", name); continue
        fam, model = FAMILIES[prefix]
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line.startswith('{"persona"'): continue
            if '"traps":' not in line or not line.rstrip().endswith('}'):
                problems.append((name, 'truncated conversation skipped')); continue
            persona, lang, turns, traps = parse_line(line)
            counters[fam] += 1
            cid = f"{fam}{counters[fam]:03d}"
            roles = [t["role"] for t in turns]
            if not turns or roles[0] != "user" or any(a == b for a, b in zip(roles, roles[1:])):
                problems.append((cid, "roles do not alternate user/assistant from a user turn"))
            if sum(r == "user" for r in roles) < 8:
                problems.append((cid, f"only {sum(r == 'user' for r in roles)} user turns"))
            seed = int(hashlib.sha256(cid.encode()).hexdigest(), 16)
            start = dt.datetime(2026, 1, 5, 8, 0) + dt.timedelta(days=seed % 200, minutes=(seed // 200) % 600)
            seen_day, k, out = None, 0, []
            for t in turns:
                if t["day"] != seen_day: seen_day, k = t["day"], 0
                when = start + dt.timedelta(days=t["day"], minutes=3 * k); k += 1
                out.append({"id": str(uuid.uuid5(NS, f"{cid}-{len(out)}")), "role": t["role"], "text": t["text"],
                            "createdAt": when.strftime("%Y-%m-%dT%H:%M:%SZ")})
            rows.append({"conversation_id": cid, "family": fam, "model_label": model, "source_file": name, "persona": persona, "lang": lang,
                         "phenomena": [], "claimed_traps": traps, "turns": out})
    with open(OUT, "w", encoding="utf-8") as f:
        for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
    # ---- aggregate report (no annotator-facing data)
    print(f"wrote {len(rows)} conversations -> {OUT}")
    for fam in sorted({r["family"] for r in rows}):
        rs = [r for r in rows if r["family"] == fam]
        users = [t["text"] for r in rs for t in r["turns"] if t["role"] == "user"]
        langs = collections.Counter(r["lang"] for r in rs)
        print(f"  {fam}: {len(rs)} conversations, {len(users)} user messages, median {statistics.median(len(u) for u in users):.0f} chars, langs {dict(langs)}")
    norm = collections.Counter(re.sub(r"\W+", " ", t["text"].lower()).strip() for r in rows for t in r["turns"] if t["role"] == "user")
    dup = {k: v for k, v in norm.items() if v > 1 and len(k) > 12}
    print(f"  user messages repeated across conversations (>12 chars): {sum(dup.values())} occurrences of {len(dup)} distinct texts")
    personas = collections.Counter(r["persona"] for r in rows)
    print("  duplicate personas:", sum(1 for v in personas.values() if v > 1))
    print("  problems:", problems if problems else "none")


if __name__ == "__main__":
    main()
