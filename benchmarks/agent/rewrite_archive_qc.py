#!/usr/bin/env python3
"""Mechanical QC for one owner-supplied archive rewrite batch; never generates or repairs text.

AGENT_SURFACE=rw /opt/homebrew/bin/python3 -I rewrite_archive_qc.py \
  --batch batch_000 --input work/rewrite_archive_rw/manual/gemini_batch_000_v1.json

Checks exact ID coverage/order, unchanged text and named-entity specificity. Reports token Jaccard and length.
Passing these checks is not semantic equivalence or the separate 300-message recoverability gate.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import statistics
import sys
import unicodedata

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from retrieval import SURFACE, fold  # noqa: E402
from rewrite_archive import OUT, SOURCE, digest, read_json, validate_rows, write_json  # noqa: E402
from world import CITIES, COMPANIES  # noqa: E402


def mention(text, name):
    """Case-insensitive full tokens; apostrophe suffixes keep Turkish proper names intact."""
    text = unicodedata.normalize("NFC", text).casefold()
    name = unicodedata.normalize("NFC", name).casefold()
    return re.search(r"(?<!\w)" + re.escape(name) + r"(?!\w)", text) is not None


def tokens(text):
    return set(re.findall(r"\w+", fold(text)))


def metrics(before, after):
    left, right = tokens(before), tokens(after)
    return {"jaccard": len(left & right) / len(left | right) if left | right else 1.0,
            "template_chars": len(before), "rewrite_chars": len(after),
            "char_ratio": len(after) / max(1, len(before)), "identical": before == after}


def names_in(item, world, message, rewritten):
    before = item["template_text"]
    people = {f"{p['first']} {p['last']}": p for p in world["people"]}
    relevant = {f.get("person") for f in item["facts"] if f.get("person")}
    relevant |= {p for f in item["facts"] for p in f.get("attendees", [])}
    if message.get("distractor", {}).get("kind") == "person":
        person = next(p for p in world["people"] if p["id"] == message["distractor"]["id"])
        relevant.add(f"{person['first']} {person['last']}")
    # This also retains previous leads named in a change sentence, not only the current gold person.
    relevant |= {name for name in people if mention(before, name)}
    required, errors = set(), []
    for full in sorted(relevant):
        first = people[full]["first"]
        if mention(before, full):
            required.add(full)
        elif mention(before, first):
            required.add(first)
            if mention(rewritten, full):
                errors.append({"kind": "expanded_first_name", "name": full})
        else:
            errors.append({"kind": "source_person_unresolved", "name": full})
    catalogue = set(COMPANIES) | {n for _, tr, en in CITIES for n in (tr, en)}
    catalogue |= {p["name"] for p in world["projects"]}
    required |= {name for name in catalogue if mention(before, name)}
    for name in sorted(required):
        if not mention(rewritten, name):
            errors.append({"kind": "missing_name", "name": name})
    for name in sorted(catalogue | set(people)):
        if mention(rewritten, name) and not mention(before, name):
            errors.append({"kind": "added_known_name", "name": name})
    return sorted(required), errors


def summary(rows):
    return {"n": len(rows), "mean_jaccard": round(statistics.mean(r["jaccard"] for r in rows), 4),
            "median_jaccard": round(statistics.median(r["jaccard"] for r in rows), 4),
            "identical": sum(r["identical"] for r in rows),
            "mean_template_chars": round(statistics.mean(r["template_chars"] for r in rows), 1),
            "mean_rewrite_chars": round(statistics.mean(r["rewrite_chars"] for r in rows), 1),
            "mean_char_ratio": round(statistics.mean(r["char_ratio"] for r in rows), 3)}


def grouped(rows, key):
    groups = defaultdict(list)
    for row in rows:
        groups[row[key]].append(row)
    return {name: summary(group) for name, group in sorted(groups.items())}


def day_one_reference():
    """Recalculate the old cooperative rewrite with the same tokenizer, where files exist."""
    old = HERE / "work" / "rewrite"
    rows = []
    for path in sorted((old / "rendered").glob("batch_*.json")):
        source = old / "batches" / path.name
        if not source.exists():
            continue
        expected = {x["id"]: x for x in read_json(source)}
        for item in read_json(path):
            rows.append(metrics(expected[item["id"]]["template_text"], item["text"]))
    return summary(rows) if rows else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch", required=True)
    parser.add_argument("--input", required=True, type=Path)
    args = parser.parse_args()
    if SURFACE != "rw":
        parser.error("Use AGENT_SURFACE=rw")
    if not re.fullmatch(r"batch_\d{3}", args.batch):
        parser.error("Batch must have the form batch_000")
    source = OUT / "batches" / (args.batch + ".json")
    manifest = read_json(OUT / "manifest.json")
    if digest(source) != manifest["batch_sha256"][source.name]:
        raise ValueError("Source batch hash differs from the export manifest")
    for relative, sha in manifest["source_sha256"].items():
        if digest(SOURCE / relative) != sha:
            raise ValueError(f"Original archive drift: {relative}")
    batch = read_json(source)
    rendered = validate_rows(read_json(args.input), batch)
    worlds, messages, rows = {}, {}, []
    for item, rewrite in zip(batch, rendered):
        wid, mid = item["id"].split("/")
        if wid not in worlds:
            worlds[wid] = read_json(SOURCE / wid / "world.json")
            messages[wid] = {m["id"]: m for m in map(json.loads, (SOURCE / wid / "messages.jsonl").read_text().splitlines())}
        required, errors = names_in(item, worlds[wid], messages[wid][mid], rewrite["text"])
        rows.append({"id": item["id"], "lang": item["lang"], "kind": item["kind"],
                     "fact_type": item["facts"][0]["type"] if item["facts"] else "distractor",
                     **metrics(item["template_text"], rewrite["text"]), "required_names": required,
                     "name_errors": errors})
    report = {"input": str(args.input.resolve()), "input_sha256": digest(args.input),
              "batch_sha256": digest(source), "coverage": "exact, unique and in original order",
              "mechanical_pass": all(not row["name_errors"] and not row["identical"] for row in rows),
              "all": summary(rows), "by_lang": grouped(rows, "lang"), "by_kind": grouped(rows, "kind"),
              "by_fact_type": grouped(rows, "fact_type"), "day_one_same_tokenizer": day_one_reference(),
              "semantic_review": "separate; not determined by this script",
              "recoverability_gate": "not run", "items": rows}
    output = OUT / "qc" / (args.input.stem + ".mechanical.json")
    write_json(output, report)
    print(json.dumps({k: v for k, v in report.items() if k != "items"}, ensure_ascii=False, indent=1))
    for row in rows:
        if row["name_errors"]:
            print(row["id"], row["name_errors"])
    print("Report:", output)
    if not report["mechanical_pass"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
