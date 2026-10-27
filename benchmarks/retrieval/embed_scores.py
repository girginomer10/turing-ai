#!/usr/bin/env python3
"""Embed XQuAD (tr/en) with several local GGUF embedding models and write cosine score matrices.

Run from benchmarks/retrieval:  python3 embed_scores.py --models-dir <dir with .gguf files>
Requires: numpy, llama.cpp's `llama-server` on PATH, and the GGUF files listed in MODELS.
Input formatting mirrors the app's EmbeddingInputFormatter (query/document prefixes).
"""
import argparse, json, os, subprocess, sys, time, urllib.request, urllib.error
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import embedders  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
DATA = os.path.join(HERE, "data")
XQUAD_URL = "https://raw.githubusercontent.com/google-deepmind/xquad/master/xquad.{lang}.json"



def load_dataset():
    os.makedirs(DATA, exist_ok=True)
    raw = {}
    for lang in ("tr", "en"):
        path = os.path.join(DATA, f"xquad.{lang}.json")
        if not os.path.exists(path):
            urllib.request.urlretrieve(XQUAD_URL.format(lang=lang), path)
        raw[lang] = json.load(open(path))["data"]
    paragraphs = {"tr": [], "en": []}
    questions = {}  # id -> dict
    for lang in ("tr", "en"):
        for article in raw[lang]:
            for para in article["paragraphs"]:
                idx = len(paragraphs[lang])
                paragraphs[lang].append(para["context"])
                for qa in para["qas"]:
                    q = questions.setdefault(qa["id"], {"id": qa["id"]})
                    q[lang] = qa["question"]
                    q["gold_" + lang] = idx
    items = [q for q in questions.values() if "tr" in q and "en" in q]
    assert all(q["gold_tr"] == q["gold_en"] for q in items), "paragraph alignment mismatch"
    items.sort(key=lambda q: q["id"])
    ds = {"paragraphs": paragraphs, "questions": [
        {"id": q["id"], "gold": q["gold_tr"], "tr": q["tr"], "en": q["en"]} for q in items]}
    json.dump(ds, open(os.path.join(WORK, "dataset.json"), "w"), ensure_ascii=False)
    return ds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--models", nargs="*", help="names from ../common/embedders.py (default: all available)")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    os.makedirs(os.path.join(WORK, "scores"), exist_ok=True)
    ds = load_dataset()
    print(f"{len(ds['questions'])} questions, {len(ds['paragraphs']['tr'])} paragraphs per language")
    for name in (a.models or [n for n, c in embedders.MODELS.items() if c['kind'] == 'llama']):
        done = all(os.path.exists(os.path.join(WORK, "scores", f"{name}.{ql}-{dl}.f32")) for ql in ("tr", "en") for dl in ("tr", "en"))
        if done and not a.force:
            print("keep", name); continue
        if not embedders.available(name, a.models_dir):
            print("skip", name, "(model file or API key missing)"); continue
        t0 = time.time()
        Q, D = {}, {}
        for lang in ("tr", "en"):  # one model load/connection per language pair keeps the code simple
            Q[lang], D[lang] = embedders.embed(name, [q[lang] for q in ds["questions"]], ds["paragraphs"][lang], a.models_dir)
        for ql in ("tr", "en"):
            for dl in ("tr", "en"):
                (Q[ql] @ D[dl].T).astype(np.float32).tofile(os.path.join(WORK, "scores", f"{name}.{ql}-{dl}.f32"))
        print(f"{name}: dim={Q['tr'].shape[1]}, {time.time()-t0:.0f}s", flush=True)
    print("done")


if __name__ == "__main__":
    main()
