#!/usr/bin/env python3
"""Validate all reviewed rewrites and merge text only into the fixed copied worlds.

AGENT_SURFACE=rw /opt/homebrew/bin/python3 -I rewrite_archive_finalize.py [--check-only]

Requires complete accepted batches and their provenance. Original archives and every field
other than message text are immutable. Re-running a completed or interrupted merge is safe.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from retrieval import SURFACE, WORLDS  # noqa: E402
from rewrite_archive import OUT, SOURCE, PROMPT, digest, read_json, source_manifest, validate_rows, write_json  # noqa: E402
from rewrite_archive_qc import grouped, metrics, names_in, summary  # noqa: E402


def frozen_export():
    manifest = read_json(OUT / "manifest.json")
    if source_manifest() != manifest["source_sha256"]:
        raise ValueError("Original archive changed after export")
    if digest(PROMPT) != manifest["prompt_sha256"]:
        raise ValueError("Original export prompt changed")
    paths = sorted((OUT / "batches").glob("batch_*.json"))
    if {path.name: digest(path) for path in paths} != manifest["batch_sha256"]:
        raise ValueError("Exported batches changed or are incomplete")
    items = [item for path in paths for item in read_json(path)]
    if [item["id"] for item in items] != manifest["ids"] or len(items) != 1752:
        raise ValueError("Export coverage differs from the frozen 1,752 IDs")
    if len({item["id"] for item in items}) != len(items):
        raise ValueError("Duplicate exported IDs")
    return manifest, paths, items


def accepted_rows(paths):
    expected = {path.name for path in paths}
    actual = {path.name for path in (OUT / "accepted").glob("batch_*.json")}
    if actual != expected:
        raise ValueError(f"Accepted coverage incomplete: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")
    outputs, renderers, hashes = {}, {}, {}
    for source in paths:
        accepted = OUT / "accepted" / source.name
        provenance = read_json(OUT / "accepted" / "provenance" / source.name)
        if (provenance.get("status") != "accepted_for_staging"
                or provenance.get("source_batch_sha256") != digest(source)
                or provenance.get("accepted_output_sha256") != digest(accepted)):
            raise ValueError(f"Invalid acceptance provenance: {source.name}")
        evidence = {}
        for field in ("original_response", "patch_response", "final_response", "semantic_report", "renderer_run_provenance"):
            if provenance.get(field):
                referenced = OUT / provenance[field]
                if not referenced.resolve().is_relative_to(OUT.resolve()):
                    raise ValueError(f"Evidence path outside rewrite outputs: {source.name}/{field}")
                sha = digest(referenced)
                if provenance.get(field + "_sha256") != sha:
                    raise ValueError(f"Linked evidence changed: {source.name}/{field}")
                evidence[provenance[field]] = sha
        renderer = provenance.get("renderer_reported")
        if not renderer:
            raise ValueError(f"Missing renderer attribution: {source.name}")
        rows = validate_rows(read_json(accepted), read_json(source))
        overrides = provenance.get("item_renderers", {})
        if set(overrides) - {row["id"] for row in rows}:
            raise ValueError(f"Unknown renderer override IDs: {source.name}")
        for row in rows:
            if row["id"] in outputs:
                raise ValueError(f"Duplicate accepted ID: {row['id']}")
            outputs[row["id"]] = row["text"]
            renderers[row["id"]] = overrides.get(row["id"], renderer)
        hashes[source.name] = {"output": digest(accepted),
                               "provenance": digest(OUT / "accepted" / "provenance" / source.name),
                               "evidence": evidence}
    return outputs, renderers, hashes


def build_merge():
    manifest, paths, items = frozen_export()
    outputs, renderers, accepted_hashes = accepted_rows(paths)
    if set(outputs) != set(manifest["ids"]):
        raise ValueError("Accepted IDs differ from export")
    target = Path(WORLDS)
    if (not target.is_dir() or target.resolve().is_relative_to(SOURCE.resolve())
            or SOURCE.resolve().is_relative_to(target.resolve()) or target.is_symlink()
            or any(path.is_symlink() for path in target.rglob("*"))):
        raise ValueError("Expected an existing, separate worlds_rw copy")
    expected_files = set(manifest["source_sha256"])
    actual_files = {str(path.relative_to(target)) for path in target.rglob("*") if path.is_file()}
    if actual_files != expected_files:
        raise ValueError("Copied world file layout differs from the original")
    for relative, sha in manifest["source_sha256"].items():
        if Path(relative).name != "messages.jsonl" and digest(target / relative) != sha:
            raise ValueError(f"Copied world/question drift: {relative}")

    item_map = {item["id"]: item for item in items}
    diagnostics, buffers, changed = [], {}, set()
    for directory in sorted(SOURCE.glob("w*")):
        if not directory.is_dir():
            continue
        world = read_json(directory / "world.json")
        source = directory / "messages.jsonl"
        lines = source.read_text().splitlines(keepends=True)
        merged = []
        for line in lines:
            message = json.loads(line)
            uid = f"{directory.name}/{message['id']}"
            if uid not in outputs:
                merged.append(line)
                continue
            item, text = item_map[uid], outputs[uid]
            if message["role"] != "user" or message["text"] != item["template_text"]:
                raise ValueError(f"Selected source no longer matches export: {uid}")
            required, errors = names_in(item, world, message, text)
            diagnostic = metrics(item["template_text"], text)
            if errors or diagnostic["identical"]:
                raise ValueError(f"Rewrite QC failed for {uid}: {errors}, identical={diagnostic['identical']}")
            diagnostics.append({"id": uid, "lang": item["lang"], "kind": item["kind"],
                                "fact_type": item["facts"][0]["type"] if item["facts"] else "distractor",
                                "renderer": renderers[uid], "required_names": required, **diagnostic})
            rewritten = {**message, "text": text}
            if {k: v for k, v in rewritten.items() if k != "text"} != {k: v for k, v in message.items() if k != "text"}:
                raise ValueError(f"Metadata changed: {uid}")
            merged.append(json.dumps(rewritten, ensure_ascii=False) + "\n")
            changed.add(uid)
        relative = source.relative_to(SOURCE)
        data = "".join(merged).encode()
        destination = target / relative
        # Resume only a template copy or this exact merge, never unrelated edits.
        if destination.read_bytes() not in (source.read_bytes(), data):
            raise ValueError(f"Unexpected existing rewritten data: {relative}")
        buffers[destination] = data
    if changed != set(outputs):
        raise ValueError("Not every accepted ID was merged exactly once")
    report = {"surface": SURFACE, "items": len(changed), "coverage": "exactly once",
              "source_manifest_sha256": digest(OUT / "manifest.json"), "accepted_sha256": accepted_hashes,
              "worlds_rw_sha256": {str(path.relative_to(target)): hashlib.sha256(data).hexdigest()
                                   for path, data in buffers.items()},
              "unchanged_non_message_files": True, "only_text_changed": True,
              "all": summary(diagnostics), "by_lang": grouped(diagnostics, "lang"),
              "by_kind": grouped(diagnostics, "kind"), "by_fact_type": grouped(diagnostics, "fact_type"),
              "by_renderer": grouped(diagnostics, "renderer"),
              "renderer_counts": dict(Counter(renderers.values())),
              "independent_renderer_family": False,
              "formal_recoverability": "not_run", "items_diagnostics": diagnostics}
    return buffers, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if SURFACE != "rw":
        parser.error("Use AGENT_SURFACE=rw")
    buffers, report = build_merge()
    if not args.check_only:
        for destination, data in buffers.items():
            if destination.read_bytes() != data:
                temporary = OUT / "merge_pending" / f"{destination.parent.name}.jsonl"
                temporary.parent.mkdir(parents=True, exist_ok=True)
                temporary.write_bytes(data)
                temporary.replace(destination)
        write_json(OUT / "merge_report.json", report, immutable=True)
    merged = all(destination.read_bytes() == data for destination, data in buffers.items())
    print(json.dumps({"archive_merged": merged, **{k: report[k] for k in
                     ("items", "all", "by_lang", "by_kind", "renderer_counts")}}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
