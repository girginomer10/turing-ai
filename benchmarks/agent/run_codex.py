#!/usr/bin/env python3
"""Run a GPT research agent through `codex exec` on the environment, one fresh context per question.

One question per context keeps earlier questions' searches from leaking bridge entities into later ones (the
per-world runs share a context across 35 questions). Each exec gets agent_prompt.md rewritten for a single question,
runs in work/runs/<run>/ (its only writable directory; network on for the local search servers) and is logged to
work/runs/<run>/logs/<qid>.txt. Questions already stopped are skipped, so the run can be resumed.

Run from benchmarks/agent with `retrieval.py serve` running:  python3 -I run_codex.py [--run gpt_codex_isolated] [--jobs 5]
"""
import argparse, json, os, shlex, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from baselines import RUNS, load_questions  # noqa: E402
from retrieval import SURFACE  # noqa: E402

ENVCMD = ["/opt/homebrew/bin/python3", "-I", os.path.join(HERE, "env.py")]
# Codex's sandbox shell may not inherit the parent's environment.
ENVP = f"AGENT_SURFACE={SURFACE} {shlex.join(ENVCMD)}"


def single_question_prompt(run, qid):
    body = open(os.path.join(HERE, "agent_prompt.md")).read().split("---", 1)[1].strip()
    body = body.replace("{ENV}", ENVP).replace("{RUN}", run)
    lines = [l for l in body.splitlines() if "questions --world" not in l]
    body = "\n".join(lines)
    body = body.replace("Work through every question in your list in order: start, research, select, stop.\n"
                        "When all are done, reply with one line per question: `<qid>: <answer> | pack size`.",
                        f"Your question id is {qid}: start it, research, select, stop. Then reply with one line: "
                        "`<qid>: <answer> | pack size`.")
    assert qid in body, "prompt rewrite failed"
    return body


def run_one(run, qid):
    d = os.path.join(RUNS, run)
    st = os.path.join(d, "state", f"{qid}.json")
    if os.path.exists(st) and json.load(open(st))["done"]:
        return qid, "skip"
    with open(os.path.join(d, "logs", f"{qid}.txt"), "w") as log:
        r = subprocess.run(["codex", "exec", "--skip-git-repo-check", "--ephemeral", "-s", "workspace-write",
                            "-c", "sandbox_workspace_write.network_access=true", "-C", d, "-"],
                           input=single_question_prompt(run, qid), text=True, stdout=log, stderr=subprocess.STDOUT,
                           timeout=1800)
    return qid, r.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="gpt_codex_isolated")
    ap.add_argument("--jobs", type=int, default=5)
    ap.add_argument("--qid", help="Run only this question (for a surface-isolation smoke check).")
    args = ap.parse_args()
    qs = [q["id"] for q in load_questions()]
    if args.qid:
        if args.qid not in qs:
            ap.error(f"unknown question: {args.qid}")
        qs = [args.qid]
    os.makedirs(os.path.join(RUNS, args.run, "logs"), exist_ok=True)
    with ThreadPoolExecutor(args.jobs) as ex:
        for i, (qid, rc) in enumerate(ex.map(lambda q: run_one(args.run, q), qs)):
            if rc not in (0, "skip"):
                print(qid, "exit", rc, flush=True)
            if i % 25 == 0:
                print(f"{i + 1}/{len(qs)}", flush=True)
    subprocess.run(ENVCMD + ["--run", args.run, "finalize"],
                   env={**os.environ, "AGENT_SURFACE": SURFACE}, check=True)


if __name__ == "__main__":
    main()
