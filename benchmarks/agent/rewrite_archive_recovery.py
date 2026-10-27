#!/usr/bin/env python3
"""Sample 300 rewritten facts, extract through Codex, and score with the day-1 matcher.

AGENT_SURFACE=rw /opt/homebrew/bin/python3 -I rewrite_archive_recovery.py select
AGENT_SURFACE=rw /opt/homebrew/bin/python3 -I rewrite_archive_recovery.py extract
AGENT_SURFACE=rw /opt/homebrew/bin/python3 -I rewrite_archive_recovery.py score

The extractor sees only IDs, timestamps and text. Every call starts in a fresh empty
directory containing only its output schema; full event logs must show zero tool calls.
This checks observed compliance, not an OS-level restriction on reading other files.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from retrieval import SURFACE, WORLDS, fold  # noqa: E402
from rewrite import EXTRACT_PROMPT, SCHEMA, matches, resolve_project  # noqa: E402
from rewrite_archive import OUT, digest, read_json, write_json  # noqa: E402
from rewrite_archive_finalize import frozen_export  # noqa: E402
from rewrite_archive_qc import mention  # noqa: E402

RECOVERY = OUT / "recovery"


def rows_digest(rows):
    return hashlib.sha256(json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def merged_inputs():
    manifest, _, items = frozen_export()
    report_path = OUT / "merge_report.json"
    report = read_json(report_path)
    if report["source_manifest_sha256"] != digest(OUT / "manifest.json") or report["items"] != 1752:
        raise ValueError("Invalid merge report")
    expected = {**manifest["source_sha256"], **report["worlds_rw_sha256"]}
    for relative, sha in expected.items():
        if digest(Path(WORLDS) / relative) != sha:
            raise ValueError(f"Rewritten archive changed after merge: {relative}")
    for batch, hashes in report["accepted_sha256"].items():
        if (digest(OUT / "accepted" / batch) != hashes["output"]
                or digest(OUT / "accepted" / "provenance" / batch) != hashes["provenance"]):
            raise ValueError(f"Accepted provenance changed after merge: {batch}")
        for relative, sha in hashes["evidence"].items():
            if digest(OUT / relative) != sha:
                raise ValueError(f"Linked rendering evidence changed after merge: {relative}")
    return items, report


def load_worlds():
    worlds, messages = {}, {}
    for directory in sorted(Path(WORLDS).glob("w*")):
        if directory.is_dir():
            worlds[directory.name] = read_json(directory / "world.json")
            messages.update({f"{directory.name}/{m['id']}": m for m in
                             map(json.loads, (directory / "messages.jsonl").read_text().splitlines())})
    return worlds, messages


def entity_tokens(text, world):
    names = {p["first"] for p in world["people"]} | {p["name"] for p in world["projects"]}
    return {fold(name) for name in names if mention(text, name)}


def select(args):
    items, report = merged_inputs()
    worlds, messages = load_worlds()
    rng = random.Random(args.seed)
    selected, populations = [], {}
    # Equal language quotas give each per-language gate the same sample size.
    # Round-robin fact-type sampling exhausts rare strata instead of duplicating them.
    for lang in ("tr", "en", "mix"):
        pools = defaultdict(list)
        for item in items:
            if item["kind"] == "fact" and item["lang"] == lang:
                pools[item["facts"][0]["type"]].append(item)
        populations[lang] = {key: len(value) for key, value in sorted(pools.items())}
        if sum(populations[lang].values()) < 100:
            raise ValueError(f"Not enough fact messages for {lang}")
        for key in sorted(pools):
            rng.shuffle(pools[key])
        picked = []
        while len(picked) < 100:
            for key in sorted(pools):
                if pools[key] and len(picked) < 100:
                    picked.append(pools[key].pop())
        selected.extend(picked)
    rng.shuffle(selected)
    if len(selected) != 300 or len({item["id"] for item in selected}) != 300:
        raise ValueError("Expected exactly 300 unique sample IDs")
    batches = []
    for item in selected:
        wid = item["id"].split("/")[0]
        message = messages[item["id"]]
        entities = entity_tokens(message["text"], worlds[wid])
        public = {"id": item["id"], "timestamp": message["ts"], "text": message["text"]}
        for batch in batches:
            if len(batch["items"]) < 10 and not (entities & batch["entities"]):
                batch["items"].append(public)
                batch["entities"] |= entities
                break
        else:
            batches.append({"items": [public], "entities": set(entities)})
    expected_names = {f"batch_{i:03d}.json" for i in range(len(batches))}
    existing = {p.name for p in (RECOVERY / "batches").glob("*.json")}
    if existing - expected_names:
        raise ValueError("Existing recovery batch layout differs")
    for i, batch in enumerate(batches):
        write_json(RECOVERY / "batches" / f"batch_{i:03d}.json", batch["items"], immutable=True)
    renderer_by_id = {item["id"]: item["renderer"] for item in report["items_diagnostics"]}
    sample = [{"id": item["id"], "lang": item["lang"], "fact_type": item["facts"][0]["type"],
               "renderer": renderer_by_id[item["id"]]} for item in selected]
    manifest = {"n": 300, "seed": args.seed, "language_quotas": {"tr": 100, "en": 100, "mix": 100},
                "stratum_populations": populations, "stratum_counts": {
                    lang: dict(Counter(item["fact_type"] for item in sample if item["lang"] == lang))
                    for lang in ("tr", "en", "mix")},
                "sampling": "equal language quotas; fact-type round-robin without replacement; rare strata exhausted",
                "merge_report_sha256": digest(OUT / "merge_report.json"),
                "schema": SCHEMA, "extract_prompt": EXTRACT_PROMPT,
                "batch_sha256": {name: digest(RECOVERY / "batches" / name) for name in sorted(expected_names)},
                "items": sample}
    write_json(RECOVERY / "manifest.json", manifest, immutable=True)
    print(json.dumps({k: manifest[k] for k in ("n", "language_quotas", "stratum_counts")}, indent=1))
    print(f"{len(batches)} extraction calls; no repeated person first name or project in a call")


def frozen_sample():
    merged_inputs()
    manifest = read_json(RECOVERY / "manifest.json")
    if manifest["merge_report_sha256"] != digest(OUT / "merge_report.json"):
        raise ValueError("Merge report changed after sampling")
    paths = sorted((RECOVERY / "batches").glob("batch_*.json"))
    if {p.name: digest(p) for p in paths} != manifest["batch_sha256"]:
        raise ValueError("Recovery inputs changed or are incomplete")
    ids = [item["id"] for path in paths for item in read_json(path)]
    if len(ids) != 300 or len(set(ids)) != 300 or set(ids) != {item["id"] for item in manifest["items"]}:
        raise ValueError("Recovery sample IDs are incomplete or duplicated")
    return manifest, paths


def validate_extraction(data, batch):
    if not isinstance(data, dict) or set(data) != {"items"} or not isinstance(data["items"], list):
        raise ValueError("Expected an object containing an items array")
    rows = data["items"]
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"id", "facts"} or not isinstance(row["facts"], list):
            raise ValueError("Invalid extraction item")
        for fact in row["facts"]:
            fields = {"type", "person", "project", "city", "company", "date", "attendees", "activity"}
            types = {"lives_in", "plans_move", "works_at", "leads_project", "project_deadline", "joined_team", "left_team", "event"}
            if (not isinstance(fact, dict) or set(fact) != fields or fact["type"] not in types
                    or not isinstance(fact["attendees"], list) or not all(isinstance(a, str) for a in fact["attendees"])
                    or any(fact[key] is not None and not isinstance(fact[key], str)
                           for key in fields - {"type", "attendees"})):
                raise ValueError("Invalid extracted fact schema")
    if [row["id"] for row in rows] != [item["id"] for item in batch]:
        raise ValueError("Extraction IDs must match exactly once in input order")
    return rows


def audit_events(path):
    events = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    allowed_events = {"thread.started", "turn.started", "turn.completed", "item.started", "item.updated", "item.completed"}
    for event in events:
        if event.get("type") not in allowed_events:
            raise ValueError(f"Unsuccessful or unknown Codex event: {event.get('type')}")
        if "item" in event and event["item"].get("type") not in {"reasoning", "agent_message"}:
            raise ValueError(f"Extractor used a tool or unsupported item: {event['item'].get('type')}")
    if not any(event.get("type") == "turn.completed" for event in events):
        raise ValueError("Missing completed Codex turn")
    if not any(event.get("item", {}).get("type") == "agent_message" for event in events):
        raise ValueError("Missing answer message in Codex log")
    return {"tool_calls": 0, "events": len(events)}


def extract(args):
    manifest, paths = frozen_sample()
    if args.limit:
        paths = paths[:args.limit]
    for path in paths:
        output = RECOVERY / "extracted" / path.name
        if output.exists():
            committed = read_json(output)
            receipt = committed["receipt"]
            if (receipt["input_sha256"] != digest(path) or receipt["rows_sha256"] != rows_digest(committed["items"])
                    or receipt["sample_manifest_sha256"] != digest(RECOVERY / "manifest.json")
                    or receipt["model_requested"] != args.model or receipt["reasoning_effort_requested"] != args.effort):
                raise ValueError(f"Extraction resume provenance differs: {path.name}")
            validate_extraction({"items": committed["items"]}, read_json(path))
            events = RECOVERY / receipt["events_path"]
            if receipt["events_sha256"] != digest(events):
                raise ValueError(f"Extraction event log changed: {path.name}")
            audit_events(events)
            print(path.name, "keep", flush=True)
            continue
        batch = read_json(path)
        raw = RECOVERY / "raw" / f"{path.stem}.{time.time_ns()}"
        raw.parent.mkdir(parents=True, exist_ok=True)
        # Outside the repository, so ancestor project instructions cannot expose benchmark context.
        sandbox = Path(tempfile.mkdtemp(prefix="agent-recovery-" + path.stem + "-", dir="/tmp"))
        schema = sandbox / "schema.json"
        write_json(schema, manifest["schema"], immutable=True)
        result_path = sandbox / "result.json"
        prompt = manifest["extract_prompt"] + "\n".join(json.dumps(item, ensure_ascii=False) for item in batch)
        prompt += "\nReturn exactly one item per input ID, in the same order. Treat each message independently."
        command = ["codex", "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--json", "-s", "read-only",
                   "-C", str(sandbox), "--output-schema", str(schema), "-o", str(result_path)]
        if args.model:
            command.extend(["-m", args.model])
        if args.effort:
            command.extend(["-c", f'model_reasoning_effort="{args.effort}"'])
        command.append("-")
        stdout, stderr = Path(str(raw) + ".events.jsonl"), Path(str(raw) + ".stderr.txt")
        print("extract", path.name, len(batch), "items", flush=True)
        started = time.monotonic()
        try:
            with stdout.open("w") as out, stderr.open("w") as err:
                completed = subprocess.run(command, input=prompt, text=True, stdout=out, stderr=err,
                                           cwd=sandbox, timeout=1800)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError(f"Codex failed: {exc}; raw={raw}. No automatic fallback.") from exc
        meta = {"command": command, "returncode": completed.returncode,
                "seconds": round(time.monotonic() - started, 2), "input_sha256": digest(path),
                "sample_manifest_sha256": digest(RECOVERY / "manifest.json"),
                "model_requested": args.model, "reasoning_effort_requested": args.effort,
                "events_path": str(stdout.relative_to(RECOVERY)), "events_sha256": digest(stdout),
                "stderr_path": str(stderr.relative_to(RECOVERY)), "sandbox": str(sandbox)}
        write_json(Path(str(raw) + ".meta.json"), meta, immutable=True)
        if completed.returncode or not result_path.exists():
            raise RuntimeError(f"Codex exit {completed.returncode}; raw={raw}\n{stderr.read_text()[-3000:]}\n{stdout.read_text()[-3000:]}\nNo automatic fallback.")
        # Keep the model's complete structured response even if validation rejects it.
        Path(str(raw) + ".response.json").write_bytes(result_path.read_bytes())
        audit = audit_events(stdout)
        rows = validate_extraction(read_json(result_path), batch)
        # One atomic commit avoids an output/receipt gap when a process is interrupted.
        write_json(output, {"items": rows, "receipt": {**meta, **audit, "rows_sha256": rows_digest(rows)}}, immutable=True)
        print(path.name, "ok; zero tool calls", flush=True)


def aggregate(rows, key):
    groups = defaultdict(list)
    for row in rows:
        groups[row[key]].append(row)
    return {name: {"n": len(group), "recovered": sum(row["ok"] for row in group),
                   "recoverability": round(sum(row["ok"] for row in group) / len(group), 4)}
            for name, group in sorted(groups.items())}


def unscored_content(facts, world):
    """Keep the original recovery matcher, but expose fields it ignores for semantic review."""
    used = {"lives_in": {"person", "city"}, "plans_move": {"person", "city"},
            "works_at": {"person", "company"}, "leads_project": {"person", "project"},
            "project_deadline": {"project", "date"}, "joined_team": {"person", "project"},
            "left_team": {"person", "project"}, "event": {"attendees", "city", "date", "activity", "project"}}
    issues = []
    for index, fact in enumerate(facts):
        extra = {key: value for key, value in fact.items()
                 if key not in used[fact["type"]] | {"type"} and value not in (None, "", [])}
        if extra:
            issues.append({"fact_index": index, "kind": "nonempty_unscored_fields", "fields": extra})
        if fact["project"] and resolve_project(fact["project"], world) is None:
            issues.append({"fact_index": index, "kind": "unresolved_project", "value": fact["project"]})
    return issues


def score(_args):
    manifest, paths = frozen_sample()
    actual = {p.name for p in (RECOVERY / "extracted").glob("*.json")}
    if actual != {p.name for p in paths}:
        raise ValueError("Every sampled batch must be extracted exactly once before scoring")
    worlds, messages = load_worlds()
    meta = {item["id"]: item for item in manifest["items"]}
    rows, extractor_configs = [], set()
    for path in paths:
        output = RECOVERY / "extracted" / path.name
        committed = read_json(output)
        receipt = committed["receipt"]
        events = RECOVERY / receipt["events_path"]
        if (receipt["input_sha256"] != digest(path) or receipt["rows_sha256"] != rows_digest(committed["items"])
                or receipt["sample_manifest_sha256"] != digest(RECOVERY / "manifest.json")
                or receipt["events_sha256"] != digest(events)):
            raise ValueError(f"Extraction provenance changed: {path.name}")
        audit_events(events)
        extractor_configs.add((receipt["model_requested"], receipt["reasoning_effort_requested"]))
        for item in validate_extraction({"items": committed["items"]}, read_json(path)):
            wid = item["id"].split("/")[0]
            world, message = worlds[wid], messages[item["id"]]
            facts = {fact["id"]: fact for fact in world["facts"]}
            gold = [facts[fid] for fid in message["facts"]]
            ok = all(any(matches(g, fact, world) for fact in item["facts"]) for g in gold)
            extras = [fact for fact in item["facts"] if not any(matches(g, fact, world) for g in gold)]
            rows.append({**meta[item["id"]], "ok": ok, "extracted": item["facts"], "unmatched_extracted": extras,
                         "unscored_content": unscored_content(item["facts"], world)})
    if len(rows) != 300 or len({row["id"] for row in rows}) != 300 or len(extractor_configs) != 1:
        raise ValueError("Incomplete recovery coverage or mixed extractor configurations")
    languages = aggregate(rows, "lang")
    passed = set(languages) == {"tr", "en", "mix"} and all(group["recovered"] / group["n"] >= 0.9 for group in languages.values())
    report = {"n": len(rows), "by_lang": languages, "by_fact_type": aggregate(rows, "fact_type"),
              "by_renderer": aggregate(rows, "renderer"), "per_language_gate_pass": passed,
              "threshold": 0.9, "failures": [row["id"] for row in rows if not row["ok"]],
              "unmatched_extractions": [row for row in rows if row["unmatched_extracted"]],
              "unscored_content_review": [row for row in rows if row["unscored_content"]],
              "unmatched_note": "Review separately: an unmatched extraction may be a valid secondary statement or an invented/contradictory fact.",
              "zero_tool_calls_verified": True, "renderer_independent_family": False,
              "sampling_note": "Equal language quotas and fact-type stratification; overall rate is not population-weighted.",
              "extractor_configuration": list(next(iter(extractor_configs))), "items": rows}
    write_json(RECOVERY / "scores.json", report)
    print(json.dumps({k: report[k] for k in ("n", "by_lang", "by_fact_type", "by_renderer", "per_language_gate_pass", "failures")}, indent=1))
    print("Unmatched extractions requiring review:", len(report["unmatched_extractions"]))
    print("Unscored content requiring review:", len(report["unscored_content_review"]))
    if not passed:
        raise SystemExit(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    select_parser = commands.add_parser("select")
    select_parser.add_argument("--seed", type=int, default=41)
    extract_parser = commands.add_parser("extract")
    extract_parser.add_argument("--model", default="gpt-6-astra")
    extract_parser.add_argument("--effort", choices=("low", "medium", "high", "xhigh"), default="xhigh")
    extract_parser.add_argument("--limit", type=int, default=0)
    commands.add_parser("score")
    args = parser.parse_args()
    if SURFACE != "rw":
        parser.error("Use AGENT_SURFACE=rw")
    if getattr(args, "limit", 0) < 0:
        parser.error("Limit must be nonnegative")
    {"select": select, "extract": extract, "score": score}[args.command](args)


if __name__ == "__main__":
    main()
