#!/usr/bin/env python3
"""Score every (query, item of the query's persona store) pair with cross-encoder rerankers.

Output: work/rerank/<model>.f32, shape (queries, items), NaN where the item is outside the query's persona store,
plus work/rerank/<model>.timing.json. Local models run through llama.cpp's /v1/rerank (--reranking); hosted
rerankers need a key in the environment or benchmarks/.env.
Run from benchmarks/memory:  python3 rerank.py --models-dir <dir> [--models name ...] [--force]
"""
import argparse, json, os, subprocess, sys, time, urllib.error, urllib.request
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "common"))
import embedders  # noqa: E402

WORK = os.path.join(HERE, "work")
RERANKERS = {
    "qwen3-rerank-0.6b": dict(kind="llama", file="qwen3-reranker-0.6b-q8_0.gguf"),
    "qwen3-rerank-4b": dict(kind="llama", file="Qwen3-Reranker-4B-Q4_K_M.gguf"),
    "bge-reranker-v2-m3": dict(kind="llama", file="bge-reranker-v2-m3-Q8_0.gguf"),
    "cohere-rerank-v3.5": dict(kind="api", provider="cohere", model="rerank-v3.5", key="COHERE_API_KEY"),
    "cohere-rerank-multilingual-v3": dict(kind="api", provider="cohere", model="rerank-multilingual-v3.0", key="COHERE_API_KEY"),
    "cohere-rerank-v4-pro": dict(kind="api", provider="cohere", model="rerank-v4.0-pro", key="COHERE_API_KEY"),
    "cohere-rerank-v4-fast": dict(kind="api", provider="cohere", model="rerank-v4.0-fast", key="COHERE_API_KEY"),
    "voyage-rerank-2.5": dict(kind="api", provider="voyage", model="rerank-2.5", key="VOYAGE_API_KEY"),
    "voyage-rerank-2.5-lite": dict(kind="api", provider="voyage", model="rerank-2.5-lite", key="VOYAGE_API_KEY"),
    "di-qwen3-rerank-0.6b": dict(kind="api", provider="deepinfra", model="Qwen/Qwen3-Reranker-0.6B", key="DEEPINFRA_API_KEY"),
    "di-qwen3-rerank-4b": dict(kind="api", provider="deepinfra", model="Qwen/Qwen3-Reranker-4B", key="DEEPINFRA_API_KEY"),
    "di-qwen3-rerank-8b": dict(kind="api", provider="deepinfra", model="Qwen/Qwen3-Reranker-8B", key="DEEPINFRA_API_KEY"),
    "di-nemotron-rerank-8b": dict(kind="api", provider="deepinfra", model="nvidia/Nemotron-3.5-Rerank-8B-BF16", key="DEEPINFRA_API_KEY"),
}


def post(url, payload, headers=None):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json", **(headers or {})})
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 7:
                time.sleep(20); continue  # provider rate limit (e.g. trial keys): wait it out
            if e.code in (500, 502, 503) and attempt < 3:
                time.sleep(2 ** attempt * 2); continue
            raise RuntimeError(f"HTTP {e.code}") from None


def score_llama(path, port, queries_docs):
    srv = subprocess.Popen(["llama-server", "-m", path, "--reranking", "--embedding", "--pooling", "rank", "--port", str(port),
                            "-c", "32768", "-b", "8192", "-ub", "8192", "--parallel", "4", "--log-disable"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(240):
            if srv.poll() is not None:
                raise RuntimeError("llama-server exited early")
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2); break
            except (urllib.error.URLError, ConnectionError, OSError):
                time.sleep(1)
        else:
            raise RuntimeError("llama-server did not start")
        out = []
        for i, (q, docs) in enumerate(queries_docs):
            r = post(f"http://127.0.0.1:{port}/v1/rerank", {"model": "m", "query": q, "documents": docs})
            s = np.zeros(len(docs), dtype=np.float32)
            for row in r["results"]:
                s[row["index"]] = row["relevance_score"]
            out.append(s)
            if i and i % 60 == 0:
                print(f"    {i}/{len(queries_docs)}", flush=True)
        return out
    finally:
        srv.terminate(); srv.wait()


def score_api(cfg, queries_docs):
    embedders.load_env()
    key = os.environ[cfg["key"]]
    auth = {"Authorization": f"Bearer {key}"}
    out = []
    for i, (q, docs) in enumerate(queries_docs):
        prov = cfg["provider"]
        if prov == "deepinfra":
            r = post(f"https://api.deepinfra.com/v1/inference/{cfg['model']}", {"queries": [q] * len(docs), "documents": docs}, auth)
            s = np.asarray(r["scores"], dtype=np.float32)
            embedders.charge("deepinfra", float((r.get("inference_status") or {}).get("cost") or 0.0))
        else:
            if prov == "cohere":
                r = post("https://api.cohere.com/v2/rerank", {"model": cfg["model"], "query": q, "documents": docs, "top_n": len(docs)}, auth)
                embedders.charge("cohere", 0.002)
            else:
                r = post("https://api.voyageai.com/v1/rerank", {"model": cfg["model"], "query": q, "documents": docs, "top_k": len(docs)}, auth)
                embedders.charge("voyage", ((r.get("usage") or {}).get("total_tokens") or 0) * 0.05 / 1e6)
            s = np.zeros(len(docs), dtype=np.float32)
            for row in r.get("results") or r.get("data"):
                s[row["index"]] = row["relevance_score"]
        out.append(s)
        if i and i % 60 == 0:
            print(f"    {i}/{len(queries_docs)}", flush=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--models", nargs="*")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--port", type=int, default=0, help="0 = pick a free port")
    ap.add_argument("--first-stage", help="results.<label>.json whose candidate lists limit what is scored")
    ap.add_argument("--config", default="bge-m3+qwen3-emb-0.6b", help="first-stage configuration name")
    ap.add_argument("--depth", type=int, default=20)
    ap.add_argument("--tag", default="", help="suffix for output files so several first stages can coexist (default: none)")
    a = ap.parse_args()
    ds = json.load(open(os.path.join(WORK, "dataset.json")))
    items, queries = ds["items"], ds["queries"]
    cols = {p: [k for k, it in enumerate(items) if it["persona"] == p] for p in ds["personas"]}
    os.makedirs(os.path.join(WORK, "rerank"), exist_ok=True)
    if a.first_stage:  # score only the first stage's top-N candidates of each query (cheaper for large rerankers)
        cand = json.load(open(a.first_stage))["stores"]["per-persona"][a.config]["candidates"]
        cols_q = [cand[qi][: a.depth] for qi in range(len(queries))]
    else:
        cols_q = [cols[q["persona"]] for q in queries]
    pairs = [(q["text"], [items[k]["text"] for k in cols_q[qi]]) for qi, q in enumerate(queries)]
    n_pairs = sum(len(d) for _, d in pairs)
    for name in (a.models or list(RERANKERS)):
        cfg = RERANKERS[name]
        stem = f"{name}@{a.tag}" if a.tag else name
        out = os.path.join(WORK, "rerank", f"{stem}.f32")
        if os.path.exists(out) and not a.force:
            print("keep", name); continue
        if cfg["kind"] == "llama":
            path = os.path.join(a.models_dir, cfg["file"])
            if not os.path.exists(path):
                print("skip", name, "(missing file)"); continue
        else:
            embedders.load_env()
            if not os.environ.get(cfg["key"]):
                print("skip", name, "(no API key)"); continue
        t0 = time.time()
        scores = score_llama(path, a.port or embedders.free_port(), pairs) if cfg["kind"] == "llama" else score_api(cfg, pairs)
        secs = time.time() - t0
        mat = np.full((len(queries), len(items)), np.nan, dtype=np.float32)
        for qi, q in enumerate(queries):
            mat[qi, cols_q[qi]] = scores[qi]
        mat.tofile(out)
        json.dump(dict(seconds=secs, pairs=n_pairs, queries=len(queries), pairs_per_second=n_pairs / secs), open(os.path.join(WORK, "rerank", f"{stem}.timing.json"), "w"))
        print(f"{name}: {n_pairs} pairs in {secs:.0f}s ({n_pairs/secs:.0f}/s, {secs/len(queries)*1000:.0f} ms per query over a full store)", flush=True)


if __name__ == "__main__":
    main()
