#!/usr/bin/env python3
"""Embed every item and query of work/dataset.json with the selected models; write full cosine matrices.

Run from benchmarks/memory:
  python3 embed.py --models-dir <dir with GGUF files> [--models name ...] [--force]
Models are defined in ../common/embedders.py (local GGUF through llama.cpp, or hosted APIs when a key is configured).
Existing work/scores/<model>.f32 files are kept unless --force is given.
"""
import argparse, json, os, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "common"))
import embedders  # noqa: E402

WORK = os.path.join(HERE, "work")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--models", nargs="*")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--truncate", nargs="*", type=int, help="also write <model>-d<N>.f32 using the first N dimensions (Matryoshka models)")
    a = ap.parse_args()
    ds = json.load(open(os.path.join(WORK, "dataset.json")))
    os.makedirs(os.path.join(WORK, "scores"), exist_ok=True)
    for name in (a.models or [n for n, c in embedders.MODELS.items() if c['kind'] == 'llama']):
        out = os.path.join(WORK, "scores", f"{name}.f32")
        if os.path.exists(out) and not a.force:
            print("keep", name); continue
        if not embedders.available(name, a.models_dir):
            print("skip", name, "(model file or API key missing)"); continue
        t0 = time.time()
        Q, D = embedders.embed(name, [q["text"] for q in ds["queries"]], [i["text"] for i in ds["items"]], a.models_dir)
        (Q @ D.T).astype(np.float32).tofile(out)
        for dim in a.truncate or []:
            if dim < Q.shape[1]:
                q2, d2 = Q[:, :dim], D[:, :dim]
                q2 = q2 / np.maximum(np.linalg.norm(q2, axis=1, keepdims=True), 1e-12)
                d2 = d2 / np.maximum(np.linalg.norm(d2, axis=1, keepdims=True), 1e-12)
                (q2 @ d2.T).astype(np.float32).tofile(os.path.join(WORK, "scores", f"{name}-d{dim}.f32"))
        json.dump(dict(seconds=time.time() - t0, texts=len(ds["queries"]) + len(ds["items"]), dim=int(Q.shape[1])),
                  open(os.path.join(WORK, "scores", f"{name}.timing.json"), "w"))
        print(f"{name}: {Q.shape[0]} queries x {D.shape[0]} items, dim={Q.shape[1]}, {time.time()-t0:.0f}s", flush=True)


if __name__ == "__main__":
    main()
