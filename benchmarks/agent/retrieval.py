#!/usr/bin/env python3
"""Search engine shared by the baselines and the agent's `search` tool: BM25 + EmbeddingGemma, fused, reranked.

Only user turns are indexed (assistant replies carry a residual "this was a fact turn" signal; see README). The
gold fields of messages.jsonl never enter the index. Stdlib only; the two models run as local llama.cpp servers:

  python3 -I retrieval.py serve          # starts both servers (keep it running), Ctrl-C stops them
  python3 -I retrieval.py index          # embeds every user turn of work/worlds/w* -> work/index/<world>.json

Pipeline: BM25 over Turkish-folded 5-character stems and dense cosine each give a top-50; reciprocal-rank fusion
(k = 60) merges them; bge-reranker-v2-m3 rescores the fused top 30. Hits below the rerank pool keep fused order.
"""
import argparse, json, math, os, re, subprocess, sys, time, unicodedata, urllib.error, urllib.request
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
SURFACE = os.environ.get("AGENT_SURFACE", "template")
# template: generated sentences; rw: fact and distractor turns paraphrased; real: whole sessions written as chat.
SURFACES = {"template": "", "rw": "_rw", "real": "_real"}
if SURFACE not in SURFACES:
    raise ValueError(f"AGENT_SURFACE must be one of {sorted(SURFACES)}, got {SURFACE!r}")


def work_path(name, *parts):
    """Keep every surface's inputs, cached indexes and results in separate directories."""
    return os.path.join(HERE, "work", name + SURFACES[SURFACE], *parts)


WORLDS = work_path("worlds")
INDEX = work_path("index")
MODELS_DIR = os.environ.get("AGENT_MODELS_DIR", os.path.expanduser("~/Models/gguf"))
EMBED_FILE, RERANK_FILE = "embeddinggemma-300M-Q8_0.gguf", "bge-reranker-v2-m3-Q8_0.gguf"
EMBED_PORT, RERANK_PORT = 8091, 8092
# EmbeddingGemma prompts as in benchmarks/common/embedders.py (model card format).
Q_PREFIX, D_PREFIX = "task: search result | query: ", "title: none | text: "
FUSED_DEPTH, RERANK_POOL, RRF_K = 50, 30, 60

STOP = set("""a an the and or of to in on at for with from by is are was were be been it its this that these those i me my
we our you your he she they them his her their as but if so not no do does did have has had will would can could should
about what which who whom when where why how now just also very really ve veya ile bir bu şu o ben beni benim biz bizim
sen senin için gibi da de mi mı mu mü ne nerede nasıl kim hangi kaç ama çok daha en var yok olan olarak idi şu an artık""".split())


def fold(s):
    s = s.replace("İ", "i").replace("I", "ı").lower().replace("ı", "i")
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


STOP_F = {fold(w) for w in STOP}


def stems(text):
    return [w[:5] for w in re.findall(r"[a-z0-9]+", fold(text)) if w not in STOP_F and len(w) >= 2]


# ---------------------------------------------------------------- servers


def _get(url, timeout=2):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def _post(url, payload, timeout=120):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            if attempt == 4:
                raise
            time.sleep(1 + attempt)


def _server_model(port):
    """The GGUF file name a running server reports, or None; a fixed port could reach another model's server."""
    try:
        d = _get(f"http://127.0.0.1:{port}/v1/models")
        return os.path.basename(d["data"][0]["id"])
    except (urllib.error.URLError, ConnectionError, OSError, KeyError, IndexError, ValueError):
        return None


def check_servers():
    for port, f in ((EMBED_PORT, EMBED_FILE), (RERANK_PORT, RERANK_FILE)):
        got = _server_model(port)
        if got != f:
            sys.exit(f"server on port {port} reports {got!r}, expected {f}; run `python3 -I retrieval.py serve` first")


def cmd_serve(_):
    procs = []
    for port, f, extra in ((EMBED_PORT, EMBED_FILE, ["--embedding", "-c", "8192", "-b", "2048", "-ub", "2048"]),
                           (RERANK_PORT, RERANK_FILE, ["--reranking", "-c", "16384", "-b", "4096", "-ub", "4096"])):
        procs.append(subprocess.Popen(["llama-server", "-m", os.path.join(MODELS_DIR, f), "--port", str(port),
                                       "--parallel", "4", "-ngl", "99", "--log-disable", *extra],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    try:
        for _ in range(120):
            if all(_server_model(p) for p in (EMBED_PORT, RERANK_PORT)):
                break
            time.sleep(1)
        check_servers()
        print("servers ready", flush=True)
        while all(p.poll() is None for p in procs):
            time.sleep(2)
    finally:
        for p in procs:
            p.terminate()


def embed(texts, prefix):
    out = []
    for i in range(0, len(texts), 32):
        d = _post(f"http://127.0.0.1:{EMBED_PORT}/v1/embeddings", {"input": [prefix + t for t in texts[i:i + 32]]})
        for row in sorted(d["data"], key=lambda r: r["index"]):
            v = row["embedding"]
            n = math.sqrt(sum(x * x for x in v)) or 1.0
            out.append([x / n for x in v])
    return out


def rerank(query, docs):
    d = _post(f"http://127.0.0.1:{RERANK_PORT}/v1/rerank", {"query": query, "documents": docs})
    scores = [0.0] * len(docs)
    for r in d["results"]:
        scores[r["index"]] = r["relevance_score"]
    return scores


# ---------------------------------------------------------------- index and search


def user_turns(world):
    """User messages without gold fields, plus the session map used by `expand`."""
    msgs = [json.loads(l) for l in open(os.path.join(WORLDS, world, "messages.jsonl"))]
    clean = [{"id": m["id"], "session": m["session"], "ts": m["ts"], "role": m["role"], "text": m["text"]} for m in msgs]
    return clean


def cmd_index(args):
    check_servers()
    os.makedirs(INDEX, exist_ok=True)
    for d in sorted(os.listdir(WORLDS)):
        if not d.startswith("w"):
            continue
        out = os.path.join(INDEX, f"{d}.json")
        if os.path.exists(out) and not args.force:
            print("keep", d)
            continue
        users = [m for m in user_turns(d) if m["role"] == "user"]
        t0 = time.time()
        vecs = embed([m["text"] for m in users], D_PREFIX)
        json.dump({"ids": [m["id"] for m in users], "vectors": [[round(x, 5) for x in v] for v in vecs]}, open(out, "w"))
        print(d, len(users), "user turns embedded in", round(time.time() - t0, 1), "s")


class Engine:
    def __init__(self, world, use_rerank=True):
        self.world = world
        self.use_rerank = use_rerank
        self.messages = user_turns(world)
        self.by_id = {m["id"]: m for m in self.messages}
        idx = json.load(open(os.path.join(INDEX, f"{world}.json")))
        self.ids = idx["ids"]
        self.vecs = idx["vectors"]
        self.toks = [stems(self.by_id[i]["text"]) for i in self.ids]
        self.tfs = [Counter(ts) for ts in self.toks]
        self.df = Counter(t for ts in self.toks for t in set(ts))
        self.avgdl = sum(len(t) for t in self.toks) / len(self.toks)

    def bm25(self, query, k1=1.2, b=0.75):
        q = set(stems(query))
        n = len(self.ids)
        scores = []
        for ts, tf in zip(self.toks, self.tfs):
            s = 0.0
            for t in q:
                if t in tf:
                    idf = math.log(1 + (n - self.df[t] + 0.5) / (self.df[t] + 0.5))
                    s += idf * tf[t] * (k1 + 1) / (tf[t] + k1 * (1 - b + b * len(ts) / self.avgdl))
            scores.append(s)
        return scores

    def dense(self, query):
        qv = embed([query], Q_PREFIX)[0]
        return [sum(a * b for a, b in zip(qv, v)) for v in self.vecs]

    def search(self, query, k=10):
        """Ranked user-turn ids for a free-text query (any language)."""
        lex, den = self.bm25(query), self.dense(query)
        fused = Counter()
        for scores in (lex, den):
            order = sorted(range(len(scores)), key=lambda i: -scores[i])[:FUSED_DEPTH]
            for r, i in enumerate(order):
                if scores[i] > 0 or scores is den:
                    fused[i] += 1.0 / (RRF_K + r + 1)
        ranked = [i for i, _ in fused.most_common()]
        if self.use_rerank and ranked:
            pool = ranked[:RERANK_POOL]
            rs = rerank(query, [self.by_id[self.ids[i]]["text"] for i in pool])
            pool = [i for _, i in sorted(zip(rs, pool), key=lambda x: -x[0])]
            ranked = pool + ranked[RERANK_POOL:]
        return [self.ids[i] for i in ranked[:k]]

    def session_neighbours(self, mid, radius=2):
        """Messages (both roles) within `radius` user turns of mid in its session, in order."""
        m = self.by_id[mid]
        sess = [x for x in self.messages if x["session"] == m["session"]]
        users = [x for x in sess if x["role"] == "user"]
        pos = next(i for i, x in enumerate(users) if x["id"] == mid)
        keep = {x["id"] for x in users[max(0, pos - radius): pos + radius + 1]}
        out = []
        for i, x in enumerate(sess):
            if x["id"] in keep or (x["role"] == "assistant" and i > 0 and sess[i - 1]["id"] in keep):
                out.append(x)
        return out


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve")
    i = sub.add_parser("index")
    i.add_argument("--force", action="store_true")
    args = ap.parse_args()
    {"serve": cmd_serve, "index": cmd_index}[args.cmd](args)


if __name__ == "__main__":
    main()
