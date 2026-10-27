#!/usr/bin/env python3
"""Zero-shot off-the-shelf NLI models on the pilot proposals, scored against the DeepSeek pre-annotation AS A PROXY (not truth).

For every stored synthetic proposal: premise = the user message, hypothesis = the proposed memory content. The NLI model's
P(entailment) is the 'supported' score. Against the proxy labels (flagged = DeepSeek said insufficient/contradicts) it reports AUROC and,
at several thresholds, the share of flagged proposals the verifier would still ACCEPT and the share of unflagged proposals it would REJECT.
These numbers measure agreement with one LLM judge, nothing more. Needs the ML venv (torch, transformers, numpy).

Run from benchmarks/verifier:  <venv-ml>/bin/python -I nli_proxy.py --models-dir <dir with the downloaded models>
"""
import argparse, collections, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = ["MoritzLaurer__multilingual-MiniLMv2-L6-mnli-xnli", "MoritzLaurer__mDeBERTa-v3-base-mnli-xnli"]


def auroc(scores, flags):
    """P(score of an unflagged item > score of a flagged item), ties half; scores are 'supported' probabilities."""
    pos = [s for s, f in zip(scores, flags) if not f]
    neg = [s for s, f in zip(scores, flags) if f]
    if not pos or not neg: return float("nan")
    order = sorted([(s, 0) for s in neg] + [(s, 1) for s in pos])
    ranks, i = {}, 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and order[j + 1][0] == order[i][0]: j += 1
        for k in range(i, j + 1): ranks[k] = (i + j) / 2 + 1
        i = j + 1
    rpos = sum(ranks[k] for k in range(len(order)) if order[k][1] == 1)
    return (rpos - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--max-len", type=int, default=256)
    a = ap.parse_args()
    import numpy as np, torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer
    props = {}
    for l in open(os.path.join(HERE, "data", "proposals.jsonl"), encoding="utf-8"):
        p = json.loads(l); props[p["proposal_id"]] = p
    pre = {}
    for l in open(os.path.join(HERE, "work", "preannotation", "di_deepseek-ai_DeepSeek-V4.1-Flash.jsonl"), encoding="utf-8"):
        r = json.loads(l)
        if r["proposal_id"] in props and r.get("label"): pre[r["proposal_id"]] = r["label"]
    ids = sorted(pre)
    flags = [pre[i] != "supports" for i in ids]
    print(f"{len(ids)} proposals with a proxy label; flagged {sum(flags)} ({sum(flags) / len(ids):.1%})")
    out = {}
    for m in MODELS:
        path = os.path.join(a.models_dir, m)
        tok = AutoTokenizer.from_pretrained(path); mod = AutoModelForSequenceClassification.from_pretrained(path).eval()
        lab = {int(k): v.lower() for k, v in mod.config.id2label.items()}
        ent = next(k for k, v in lab.items() if v.startswith("entail"))
        scores = []
        with torch.no_grad():
            for i in range(0, len(ids), 32):
                batch = [props[x] for x in ids[i:i + 32]]
                enc = tok([b["message"] for b in batch], [b["operation"]["content"] for b in batch], truncation=True, max_length=a.max_len,
                          padding=True, return_tensors="pt")
                scores += torch.softmax(mod(**enc).logits, dim=-1)[:, ent].tolist()
        out[m] = scores
        print(f"\n== {m}  AUROC for finding proxy-flagged proposals: {auroc(scores, flags):.3f}")
        print("   threshold on P(entail) | accepts flagged (miss) | rejects unflagged (false alarm) | rejects overall")
        for t in (0.2, 0.4, 0.5, 0.6, 0.8):
            acc_f = sum(1 for s, f in zip(scores, flags) if f and s >= t) / max(1, sum(flags))
            rej_u = sum(1 for s, f in zip(scores, flags) if not f and s < t) / max(1, len(flags) - sum(flags))
            rej = sum(1 for s in scores if s < t) / len(scores)
            print(f"   {t:.1f}                   | {acc_f:6.1%}                 | {rej_u:6.1%}                         | {rej:6.1%}")
        by = collections.defaultdict(list)
        for s, f, i in zip(scores, flags, ids): by[props[i]["conversation_id"][:3]].append((s, f))
        print("   AUROC by slice:", {k: round(auroc([s for s, _ in v], [f for _, f in v]), 3) for k, v in sorted(by.items())})
    json.dump({"ids": ids, "flags": flags, "scores": out}, open(os.path.join(HERE, "work", "nli_proxy_scores.json"), "w"))


if __name__ == "__main__":
    main()
