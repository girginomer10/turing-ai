#!/usr/bin/env python3
"""Prepare and render a fixed archive's natural-language surface using the Claude subscription CLI.

AGENT_SURFACE=rw /opt/homebrew/bin/python3 -I rewrite_archive.py export
AGENT_SURFACE=rw /opt/homebrew/bin/python3 -I rewrite_archive.py render --limit 1 --jobs 1
AGENT_SURFACE=rw /opt/homebrew/bin/python3 -I rewrite_archive.py render --jobs 3

The original worlds and day-1 rewrite files are never modified. Raw CLI outputs stay under work/.
An authentication, rate-limit, refusal, timeout or CLI error stops rendering without a model fallback.
Only malformed JSON/coverage may be retried automatically. Existing valid outputs are resumable.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import random
import shutil
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from retrieval import SURFACE, WORLDS, work_path  # noqa: E402
from rewrite import describe  # noqa: E402

SOURCE = HERE / "work" / "worlds"
OUT = Path(work_path("rewrite_archive"))
PROMPT = HERE / "rewrite_archive_prompt.md"


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value, immutable=False):
    if immutable and path.exists():
        if read_json(path) != value:
            raise ValueError(f"Refusing to overwrite different existing data: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n")
    tmp.replace(path)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_manifest():
    return {str(p.relative_to(SOURCE)): digest(p) for p in sorted(SOURCE.rglob("*")) if p.is_file()}


def cmd_export(args):
    target = Path(WORLDS)
    if not SOURCE.is_dir():
        raise ValueError(f"Missing template archive: {SOURCE}")
    manifest = source_manifest()
    if not target.exists():
        shutil.copytree(SOURCE, target)
    # World graphs and questions must remain byte-identical, even after a resumed merge.
    for relative, sha in manifest.items():
        if Path(relative).name != "messages.jsonl" and digest(target / relative) != sha:
            raise ValueError(f"World/question drift in {relative}")
    items = []
    for directory in sorted(SOURCE.glob("w*")):
        if not directory.is_dir():
            continue
        world = read_json(directory / "world.json")
        facts = {f["id"]: f for f in world["facts"]}
        for line in (directory / "messages.jsonl").read_text().splitlines():
            message = json.loads(line)
            if message["role"] != "user" or not (message.get("facts") or message.get("distractor")):
                continue
            if message["text"] != message["template_text"]:
                raise ValueError(f"Source is not a template surface: {directory.name}/{message['id']}")
            items.append({"id": f"{directory.name}/{message['id']}", "lang": message["lang"], "ts": message["ts"],
                          "template_text": message["template_text"],
                          "facts": [describe(facts[fid], world) for fid in message["facts"]],
                          "kind": "fact" if message["facts"] else "distractor"})
    counts = Counter(item["kind"] for item in items)
    if counts != {"fact": 1359, "distractor": 393} or len({x["id"] for x in items}) != len(items):
        raise ValueError(f"Unexpected fixed-archive coverage: {dict(counts)}")
    random.Random(29).shuffle(items)
    batches = [items[i:i + args.batch_size] for i in range(0, len(items), args.batch_size)]
    expected = {f"batch_{i:03d}.json" for i in range(len(batches))}
    existing = {p.name for p in (OUT / "batches").glob("*.json")}
    if existing - expected:
        raise ValueError("Existing batch layout differs; do not mix exports")
    for i, batch in enumerate(batches):
        write_json(OUT / "batches" / f"batch_{i:03d}.json", batch, immutable=True)
    batch_hashes = {name: digest(OUT / "batches" / name) for name in sorted(expected)}
    write_json(OUT / "manifest.json", {"source_sha256": manifest, "prompt_sha256": digest(PROMPT),
               "items": len(items), "counts": dict(counts), "batch_size": args.batch_size,
               "batches": len(batches), "batch_sha256": batch_hashes, "ids": [x["id"] for x in items]}, immutable=True)
    print(json.dumps({"items": len(items), "counts": dict(counts), "batches": len(batches),
                      "languages": dict(Counter(x["lang"] for x in items))}), flush=True)


def validate_rows(rows, batch):
    if not isinstance(rows, list) or not all(isinstance(r, dict) and set(r) == {"id", "text"}
                                           and isinstance(r["text"], str) and r["text"].strip() for r in rows):
        raise ValueError("Expected a JSON array of nonempty {id, text} objects")
    if [r["id"] for r in rows] != [b["id"] for b in batch]:
        raise ValueError("IDs must match the input exactly once, in the same order")
    return rows


class RendererFailure(RuntimeError):
    """A CLI failure requiring the owner's decision, never a fallback or config change."""


def render_one(path, retries, stopped):
    batch = read_json(path)
    output = OUT / "rendered" / path.name
    if output.exists():
        validate_rows(read_json(output), batch)
        return f"{path.name}: keep"
    prompt = PROMPT.read_text() + "\n\nBatch:\n" + json.dumps(batch, ensure_ascii=False)
    sandbox = OUT / "renderer_sandbox"
    sandbox.mkdir(parents=True, exist_ok=True)
    raw_dir = OUT / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    command = ["claude", "-p", "--model", "sonnet", "--output-format", "json", "--tools", "",
               "--no-session-persistence"]
    for attempt in range(retries + 1):
        if stopped.is_set():
            return f"{path.name}: cancelled after another CLI failure"
        prefix = raw_dir / f"{path.stem}.{time.time_ns()}.a{attempt}"
        stdout = Path(str(prefix) + ".stdout.json")
        stderr = Path(str(prefix) + ".stderr.txt")
        started = time.time()
        try:
            with stdout.open("w") as out, stderr.open("w") as err:
                result = subprocess.run(command, input=prompt, text=True, cwd=sandbox,
                                        stdout=out, stderr=err, timeout=1800)
        except (OSError, subprocess.TimeoutExpired) as exc:
            stopped.set()
            raise RendererFailure(f"Claude failed for {path.name}: {exc}; raw prefix: {prefix}") from exc
        write_json(Path(str(prefix) + ".meta.json"), {"command": command, "returncode": result.returncode,
                   "seconds": round(time.time() - started, 2), "batch_sha256": digest(path),
                   "prompt_sha256": digest(PROMPT)})
        if result.returncode:
            stopped.set()
            raise RendererFailure(f"Claude exit {result.returncode} for {path.name}:\n"
                                  f"{stderr.read_text()[-4000:]}\n{stdout.read_text()[-4000:]}\nRaw: {prefix}")
        try:
            envelope = read_json(stdout)
        except json.JSONDecodeError as exc:
            stopped.set()
            raise RendererFailure(f"Invalid CLI envelope for {path.name}: {exc}; raw: {prefix}") from exc
        if not isinstance(envelope, dict) or envelope.get("is_error") or envelope.get("subtype") not in (None, "success"):
            stopped.set()
            raise RendererFailure(f"Claude error for {path.name}: {json.dumps(envelope, ensure_ascii=False)}")
        try:
            body = envelope.get("result", "").strip()
            if body.startswith("```") and body.endswith("```"):
                body = body.split("\n", 1)[1].rsplit("```", 1)[0].strip()
            rows = validate_rows(json.loads(body), batch)
        except (ValueError, TypeError, KeyError) as exc:
            # Textual refusals are not JSON errors to retry.
            if not body.startswith("[") or attempt == retries:
                stopped.set()
                raise RendererFailure(f"No valid render for {path.name}: {exc}; result: {body[:4000]!r}; "
                                      f"raw: {prefix}") from exc
            print(f"{path.name}: malformed array/coverage; retry {attempt + 1}/{retries}", flush=True)
            continue
        write_json(output, rows, immutable=True)
        return f"{path.name}: rendered {len(rows)}"


def cmd_render(args):
    manifest = read_json(OUT / "manifest.json")
    if manifest["source_sha256"] != source_manifest() or manifest["prompt_sha256"] != digest(PROMPT):
        raise ValueError("Source or prompt drift since export; do not mix rendering versions")
    paths = sorted((OUT / "batches").glob("batch_*.json"))
    if len(paths) != manifest["batches"]:
        raise ValueError("Incomplete exported batches")
    if {p.name: digest(p) for p in paths} != manifest["batch_sha256"]:
        raise ValueError("Exported batches changed; do not mix rendering inputs")
    if args.limit:
        paths = paths[:args.limit]
    stopped = threading.Event()
    # Bounded waves keep a failed call from launching every remaining batch.
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        for i in range(0, len(paths), args.jobs):
            futures = [executor.submit(render_one, p, args.retries, stopped) for p in paths[i:i + args.jobs]]
            for future in as_completed(futures):
                try:
                    print(future.result(), flush=True)
                except Exception as exc:
                    stopped.set()
                    # Report now, before the executor waits for calls already in flight.
                    print(f"STOP: {exc}\nNo more batches will start; waiting for in-flight calls.",
                          file=sys.stderr, flush=True)
                    raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export")
    export.add_argument("--batch-size", type=int, default=60)
    render = commands.add_parser("render")
    render.add_argument("--jobs", type=int, default=3)
    render.add_argument("--limit", type=int, default=0)
    render.add_argument("--retries", type=int, default=2)
    args = parser.parse_args()
    if SURFACE != "rw":
        parser.error("Use AGENT_SURFACE=rw; original template outputs are protected")
    if any(getattr(args, name, 1) < 1 for name in ("batch_size", "jobs")):
        parser.error("Batch size and worker count must be positive")
    if any(getattr(args, name, 0) < 0 for name in ("limit", "retries")):
        parser.error("Limit and retry count must be nonnegative")
    try:
        {"export": cmd_export, "render": cmd_render}[args.command](args)
    except (RendererFailure, ValueError) as exc:
        print(f"STOP: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
