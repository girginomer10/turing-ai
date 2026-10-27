#!/usr/bin/env python3
"""Merge persona files into work/dataset.json, validate them and report lexical-overlap QC.

QC rationale: a 'paraphrase' or 'cross_lingual' query that shares many content stems with its gold item is
secretly a keyword query and would flatter lexical retrieval. The overlap statistics below make that auditable.
"""
import glob, json, os, re, sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
os.makedirs(WORK, exist_ok=True)

KINDS = {"topic", "event", "message", "document"}
LANGS = {"tr", "en", "mixed"}
QTYPES = ["direct", "paraphrase", "cross_lingual", "hard_negative", "unanswerable"]
STOP = set("""a an the and or of to in on at for with from by is are was were be been it its this that these those i me my we our you your
he she they them his her their as but if so not no do does did have has had will would can could should about what which who whom when where why how
ve veya ile bir bu şu o ben beni benim biz bizim sen senin için gibi da de mi mı mu mü ne nerede nasıl kim hangi kaç ama çok daha en var yok
olan olarak mı mi idi""".split())
FOLD = str.maketrans("çğıöşüâîû", "cgiosuaiu")


def stems(text):
    text = text.replace("İ", "i").replace("I", "ı").lower().translate(FOLD)
    out = set()
    for w in re.findall(r"[a-z0-9]+", text):
        if w in STOP or len(w) < 3:
            continue
        out.add(w[:5])
    return out


def load():
    items, queries, personas = [], [], []
    for path in sorted(glob.glob(os.path.join(HERE, "data", "persona_*.json")), key=lambda p: int(re.findall(r"\d+", os.path.basename(p))[0])):
        d = json.load(open(path))
        personas.append(d["persona"])
        for it in d["items"]:
            it["persona"] = d["persona"]
            items.append(it)
        for q in d["queries"]:
            q["persona"] = d["persona"]
            queries.append(q)
    return personas, items, queries


def validate(personas, items, queries):
    errs = []
    ids = Counter(i["id"] for i in items)
    errs += [f"duplicate item id {k}" for k, v in ids.items() if v > 1]
    qids = Counter(q["id"] for q in queries)
    errs += [f"duplicate query id {k}" for k, v in qids.items() if v > 1]
    byid = {i["id"]: i for i in items}
    for i in items:
        if i["kind"] not in KINDS: errs.append(f"{i['id']}: bad kind {i['kind']}")
        if i["lang"] not in LANGS: errs.append(f"{i['id']}: bad lang {i['lang']}")
        if not i["text"].strip(): errs.append(f"{i['id']}: empty text")
        if not i.get("container"): errs.append(f"{i['id']}: no container")
    for q in queries:
        if q["type"] not in QTYPES: errs.append(f"{q['id']}: bad type {q['type']}")
        if q["lang"] not in {"tr", "en"}: errs.append(f"{q['id']}: bad lang")
        for g in q["gold"]:
            if g not in byid: errs.append(f"{q['id']}: unknown gold {g}")
            elif byid[g]["persona"] != q["persona"]: errs.append(f"{q['id']}: cross-persona gold")
        if q["type"] == "unanswerable" and q["gold"]: errs.append(f"{q['id']}: unanswerable with gold")
        if q["type"] != "unanswerable" and len(q["gold"]) != 1: errs.append(f"{q['id']}: needs exactly one gold")
        if q["type"] == "cross_lingual" and q["gold"] and byid[q["gold"][0]]["lang"] == q["lang"]:
            errs.append(f"{q['id']}: cross_lingual but same language as gold")
    return errs


def main():
    personas, items, queries = load()
    errs = validate(personas, items, queries)
    for e in errs[:60]:
        print("ERROR", e)
    byid = {i["id"]: i for i in items}
    gold_ids = {g for q in queries for g in q["gold"]}
    lines = ["# Dataset QC\n", f"{len(personas)} personas, {len(items)} items, {len(queries)} queries, {len(errs)} validation errors.\n"]
    lines.append("| persona | items | queries | topics | events | messages | documents | never-gold items |\n|---|---|---|---|---|---|---|---|")
    for p in personas:
        its = [i for i in items if i["persona"] == p]
        k = Counter(i["kind"] for i in its)
        ng = sum(1 for i in its if i["id"] not in gold_ids)
        lines.append(f"| {p} | {len(its)} | {sum(1 for q in queries if q['persona']==p)} | {k['topic']} | {k['event']} | {k['message']} | {k['document']} | {ng} ({ng/len(its):.0%}) |")
    lines.append("\n| query type | n | tr | en | mean Jaccard(query, gold) | share with >=2 shared stems | share with 0 shared stems |\n|---|---|---|---|---|---|---|")
    qc = {}
    for t in QTYPES:
        qs = [q for q in queries if q["type"] == t]
        if t == "unanswerable":
            lines.append(f"| {t} | {len(qs)} | {sum(q['lang']=='tr' for q in qs)} | {sum(q['lang']=='en' for q in qs)} | n/a | n/a | n/a |")
            continue
        jac, two, zero = [], 0, 0
        for q in qs:
            a, b = stems(q["text"]), stems(byid[q["gold"][0]]["text"] + " " + byid[q["gold"][0]].get("title", ""))
            inter = len(a & b)
            jac.append(inter / max(1, len(a | b)))
            two += inter >= 2; zero += inter == 0
        qc[t] = dict(n=len(qs), jaccard=sum(jac)/len(jac), ge2=two/len(qs), zero=zero/len(qs))
        lines.append(f"| {t} | {len(qs)} | {sum(q['lang']=='tr' for q in qs)} | {sum(q['lang']=='en' for q in qs)} | {qc[t]['jaccard']:.3f} | {qc[t]['ge2']:.0%} | {qc[t]['zero']:.0%} |")
    lang = Counter(i["lang"] for i in items)
    lines.append(f"\nItem languages: {dict(lang)}. Gold-item kinds: {dict(Counter(byid[q['gold'][0]]['kind'] for q in queries if q['gold']))}.")
    json.dump({"personas": personas, "items": items, "queries": queries}, open(os.path.join(WORK, "dataset.json"), "w"), ensure_ascii=False)
    open(os.path.join(WORK, "qc.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
