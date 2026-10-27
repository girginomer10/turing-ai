"""LLM pre-annotation of proposals (ESTIMATE ONLY, hidden from the human annotators).

Purpose: a rough count of how many proposals look unsupported, to size the human effort. It is not ground truth and
must never be merged into the labeled dataset. The judge is a family different from both extractors (default
DeepSeek V4.1 Flash on DeepInfra). Output: work/preannotation/<model>.jsonl; re-runs skip proposals already judged.

Run from benchmarks/verifier:  python -I preannotate.py [--model di:deepseek-ai/DeepSeek-V4.1-Flash] [--limit 50]
"""
import argparse, concurrent.futures as cf, json, os, sys, threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import llm  # noqa: E402

DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "work", "preannotation")

SYSTEM = """You check whether a memory an assistant wants to store about a user is justified by ONE user message.
Judge consistency with what the user said, not real-world truth. The existing memory (if any) is context only: an old memory cannot justify a new one.
Labels:
- supports: the message states or directly implies the proposed memory (paraphrase, translation, compression are fine).
- insufficient: the message does not say it; the memory adds or assumes something (ownership from an encounter, a fact from a plan, the user's attribute from a relative's, a time scope the user did not state, a bundled claim only partly supported).
- contradicts: the message explicitly says the opposite (negation, quitting, correction, a different current value).
Tags (optional, several): person, relationship, negation, plan_vs_fact, time_scope, ownership, other.
Reply with JSON only: {"label":"supports|insufficient|contradicts","tags":[],"reason":"one short sentence"}"""


def prompt(p):
    op = p["operation"]
    ex = p.get("existing_topic") or p.get("existing_topic_by_target")
    existing = f"[{ex['kind']}] {ex['title']}: {ex['content']}" if ex else "(none)"
    return (f"User message ({p['createdAt']}):\n{p['message']}\n\nExisting memory being updated: {existing}\n\n"
            f"Proposed memory [{op['kind']}] {op['title']}: {op['content']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="di:deepseek-ai/DeepSeek-V4.1-Flash")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--proposals", default=os.path.join(DATA, "proposals.jsonl"), help="proposals JSONL (default: data/proposals.jsonl)")
    ap.add_argument("--out-dir", default=OUT, help="output directory (use the private directory for real messages)")
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    path = os.path.join(a.out_dir, a.model.replace(":", "_").replace("/", "_") + ".jsonl")
    done = set()
    if os.path.exists(path):
        done = {json.loads(l)["proposal_id"] for l in open(path, encoding="utf-8") if l.strip()}
    props = [json.loads(l) for l in open(a.proposals, encoding="utf-8") if l.strip()]
    props = [p for p in props if p.get("apply_ok") and p["proposal_id"] not in done]
    if a.limit:
        props = props[:a.limit]
    lock = threading.Lock()

    def work(p):
        r = llm.call(a.model, SYSTEM, prompt(p))
        out = dict(proposal_id=p["proposal_id"], family=p["family"], conversation_id=p["conversation_id"], lang=p["lang"], model=a.model,
                   cost=r.get("cost"), error=r.get("error"))
        try:
            j = json.loads(llm.strip_fence(r["text"]))
            assert j["label"] in ("supports", "insufficient", "contradicts")
            out.update(label=j["label"], tags=j.get("tags") or [], reason=str(j.get("reason", ""))[:300])
        except Exception:
            out.update(label=None, raw=(r.get("text") or "")[:300])
        return out

    with open(path, "a", encoding="utf-8") as f, cf.ThreadPoolExecutor(a.workers) as ex:
        futs = [ex.submit(work, p) for p in props]
        try:
            for n, fut in enumerate(cf.as_completed(futs), 1):
                r = fut.result()
                with lock:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n"); f.flush()
                if n % 100 == 0:
                    print(f"  {n}/{len(props)} phase spent ${llm.phase_spent():.3f}", flush=True)
        except Exception as e:
            for fut in futs: fut.cancel()
            print("STOP:", type(e).__name__, str(e)[:200])
    print(f"done {len(props)} new, phase spent ${llm.phase_spent():.3f}")


if __name__ == "__main__":
    main()
