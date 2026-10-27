"""Embedding back ends shared by the benchmarks: local GGUF models through llama.cpp and hosted APIs.

Query/document formatting follows each model card (and, where the app defines one, EmbeddingInputFormatter).
API keys are read from the environment or benchmarks/.env (git-ignored) and never printed or logged.
"""
import json, os, socket, subprocess, time, urllib.error, urllib.request
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
INSTRUCT = ("Instruct: Given a user's current message, retrieve relevant passages from their previous "
            "conversations and imported documents\nQuery: {text}")
NOMIC_V15 = os.path.expanduser(
    "~/.lmstudio/.internal/bundled-models/nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf")

# kind "llama": local GGUF. kind "api": hosted endpoint (needs a key). ctx = llama-server context per request.
MODELS = {
    "nomic-v1.5": dict(kind="llama", path=NOMIC_V15, ctx=2048, query=lambda t: "search_query: " + t, doc=lambda t: "search_document: " + t),
    "bge-m3": dict(kind="llama", file="bge-m3-Q8_0.gguf", ctx=4096, query=lambda t: t, doc=lambda t: t),
    "qwen3-emb-0.6b": dict(kind="llama", file="Qwen3-Embedding-0.6B-Q8_0.gguf", ctx=4096, query=lambda t: INSTRUCT.format(text=t), doc=lambda t: t),
    "qwen3-emb-4b": dict(kind="llama", file="Qwen3-Embedding-4B-Q8_0.gguf", ctx=4096, query=lambda t: INSTRUCT.format(text=t), doc=lambda t: t),
    "embeddinggemma-300m": dict(kind="llama", file="embeddinggemma-300M-Q8_0.gguf", ctx=2048,
                                query=lambda t: "task: search result | query: " + t, doc=lambda t: "title: none | text: " + t),
    "nomic-v2-moe": dict(kind="llama", file="nomic-embed-text-v2-moe.Q8_0.gguf", ctx=512,
                         query=lambda t: "search_query: " + t, doc=lambda t: "search_document: " + t),
    "e5-large-instruct": dict(kind="llama", file="multilingual-e5-large-instruct-q8_0.gguf", ctx=512,
                              query=lambda t: "Instruct: Given a user's question, retrieve relevant passages from their memory\nQuery: " + t, doc=lambda t: t),
    "arctic-embed-l-v2": dict(kind="llama", file="snowflake-arctic-embed-l-v2.0-q8_0.gguf", ctx=4096,
                              query=lambda t: "query: " + t, doc=lambda t: t),
    # hosted models (price = USD per million input tokens, used only for the spend ledger)
    "openai-3-large": dict(kind="api", provider="openai", model="text-embedding-3-large", key="OPENAI_API_KEY", price=0.13),
    "openai-3-small": dict(kind="api", provider="openai", model="text-embedding-3-small", key="OPENAI_API_KEY", price=0.02),
    "voyage-4": dict(kind="api", provider="voyage", model="voyage-4", key="VOYAGE_API_KEY", price=0.06),
    "voyage-4-large": dict(kind="api", provider="voyage", model="voyage-4-large", key="VOYAGE_API_KEY", price=0.12),
    "voyage-4-lite": dict(kind="api", provider="voyage", model="voyage-4-lite", key="VOYAGE_API_KEY", price=0.02),
    "voyage-3-large": dict(kind="api", provider="voyage", model="voyage-3-large", key="VOYAGE_API_KEY", price=0.18),
    "cohere-embed-v4": dict(kind="api", provider="cohere", model="embed-v4.0", key="COHERE_API_KEY", price=0.12),
    # OpenRouter proxies cannot forward task types, so Gemini 001 is raw text; Gemini 2 takes its task from a text prefix
    "or-gemini-embedding-001": dict(kind="api", provider="openrouter", model="google/gemini-embedding-001", key="OPENROUTER_API_KEY", price=0.15),
    "or-gemini-embedding-2": dict(kind="api", provider="openrouter", model="google/gemini-embedding-2", key="OPENROUTER_API_KEY", price=0.20,
                                  query=lambda t: "task: search result | query: " + t, doc=lambda t: "title: none | text: " + t),
    "or-mistral-embed": dict(kind="api", provider="openrouter", model="mistralai/mistral-embed-2312", key="OPENROUTER_API_KEY", price=0.10),
    "or-pplx-embed-4b": dict(kind="api", provider="openrouter", model="perplexity/pplx-embed-v1-4b", key="OPENROUTER_API_KEY", price=0.03),
    "di-qwen3-emb-8b": dict(kind="api", provider="deepinfra", model="Qwen/Qwen3-Embedding-8B", key="DEEPINFRA_API_KEY", price=0.01,
                            query=lambda t: INSTRUCT.format(text=t)),
    "di-bge-m3": dict(kind="api", provider="deepinfra", model="BAAI/bge-m3", key="DEEPINFRA_API_KEY", price=0.01),
    "di-embeddinggemma-300m": dict(kind="api", provider="deepinfra", model="google/embeddinggemma-300m", key="DEEPINFRA_API_KEY", price=0.002,
                                   query=lambda t: "task: search result | query: " + t, doc=lambda t: "title: none | text: " + t),
    "di-embeddinggemma-2": dict(kind="api", provider="deepinfra", model="google/embeddinggemma-2", key="DEEPINFRA_API_KEY", price=0.02,
                                query=lambda t: "task: search result | query: " + t, doc=lambda t: "title: none | text: " + t),
    "di-nemotron-embed-8b": dict(kind="api", provider="deepinfra", model="nvidia/Nemotron-3.5-Embed-8B-BF16", key="DEEPINFRA_API_KEY", price=0.035),
    "di-nemotron-embed-8b-qp": dict(kind="api", provider="deepinfra", model="nvidia/Nemotron-3.5-Embed-8B-BF16", key="DEEPINFRA_API_KEY", price=0.035,
                                    query=lambda t: "query: " + t, doc=lambda t: "passage: " + t),
}


# Ablation: the same models fed raw text (no query/document prefix or instruction).
for _name in ("nomic-v1.5", "nomic-v2-moe", "qwen3-emb-0.6b", "qwen3-emb-4b", "embeddinggemma-300m", "e5-large-instruct", "arctic-embed-l-v2"):
    MODELS[_name + "-raw"] = dict(MODELS[_name], query=lambda t: t, doc=lambda t: t)


LEDGER = os.path.join(HERE, "..", ".spend.json")
# Hard caps in USD per provider for the whole project; calls stop before a cap is crossed.
CAPS = {"openrouter": 6.5, "openai": 12.0, "deepinfra": 3.0, "voyage": 5.0, "cohere": 5.0}


class BudgetExceeded(RuntimeError):
    pass


def spent(provider):
    try:
        return json.load(open(LEDGER)).get(provider, 0.0)
    except (OSError, ValueError):
        return 0.0


def charge(provider, usd):
    """Atomic read-modify-write under an exclusive file lock (several runners may share one ledger)."""
    import fcntl
    with open(LEDGER + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = {}
        try:
            data = json.load(open(LEDGER))
        except (OSError, ValueError):
            pass
        total = data.get(provider, 0.0) + usd
        data[provider] = total
        tmp = LEDGER + ".tmp"
        json.dump(data, open(tmp, "w"), indent=1)
        os.replace(tmp, LEDGER)
    if total > CAPS.get(provider, 1.0):
        raise BudgetExceeded(f"{provider} spend ${total:.2f} exceeds its cap ${CAPS.get(provider, 1.0):.2f}")


def load_env():
    path = os.path.join(HERE, "..", ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def available(name, models_dir):
    cfg = MODELS[name]
    if cfg["kind"] == "api":
        load_env()
        return bool(os.environ.get(cfg["key"]))
    path = cfg.get("path") or os.path.join(models_dir, cfg["file"])
    return os.path.exists(path)


def _http(url, payload, headers, retries=4):
    data = json.dumps(payload).encode()
    for attempt in range(retries):
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **headers})
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < retries - 1:
                time.sleep(2 ** attempt * 2); continue
            raise RuntimeError(f"HTTP {e.code} from {url.split('?')[0]}") from None  # never include the key
        except (urllib.error.URLError, TimeoutError):
            if attempt < retries - 1:
                time.sleep(2 ** attempt); continue
            raise


def _normalize(rows):
    m = np.asarray(rows, dtype=np.float32)
    return m / np.maximum(np.linalg.norm(m, axis=1, keepdims=True), 1e-12)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _embed_llama(cfg, models_dir, queries, docs, port=None):
    port = port or free_port()  # a fixed port could silently reach another model's server
    path = cfg.get("path") or os.path.join(models_dir, cfg["file"])
    srv = subprocess.Popen(["llama-server", "-m", path, "--embedding", "--port", str(port), "-c", str(cfg["ctx"]),
                            "-b", str(cfg["ctx"]), "-ub", str(cfg["ctx"]), "--parallel", "1", "--log-disable"],
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

        def one(text):
            t = text
            for _ in range(8):  # shrink over-long inputs instead of failing (small-context models)
                try:
                    return _http(f"http://127.0.0.1:{port}/v1/embeddings", {"input": t, "model": "m"}, {})["data"][0]["embedding"]
                except RuntimeError:
                    t = t[: int(len(t) * 0.7)]
            raise RuntimeError("input could not be embedded")

        return _normalize([one(cfg["query"](t)) for t in queries]), _normalize([one(cfg["doc"](t)) for t in docs])
    finally:
        srv.terminate(); srv.wait()


def _batches(items, n):
    for i in range(0, len(items), n):
        yield items[i:i + n]


def _embed_api(cfg, queries, docs):
    load_env()
    key = os.environ[cfg["key"]]
    prov, model, price = cfg["provider"], cfg["model"], cfg.get("price", 0.0)
    qf, df = cfg.get("query", lambda t: t), cfg.get("doc", lambda t: t)

    def run(texts, role):
        out = []
        for batch in _batches(texts, 64 if prov != "gemini" else 100):
            tokens = 0
            if prov in ("openai", "openrouter", "deepinfra"):
                url = {"openai": "https://api.openai.com/v1/embeddings",
                       "openrouter": "https://openrouter.ai/api/v1/embeddings",
                       "deepinfra": "https://api.deepinfra.com/v1/openai/embeddings"}[prov]
                r = _http(url, {"model": model, "input": batch, "encoding_format": "float"}, {"Authorization": f"Bearer {key}"})
                out += [d["embedding"] for d in sorted(r["data"], key=lambda d: d["index"])]
                tokens = (r.get("usage") or {}).get("total_tokens") or sum(len(t) // 3 for t in batch)
            elif prov == "cohere":
                r = _http("https://api.cohere.com/v2/embed", {"model": model, "texts": batch, "embedding_types": ["float"],
                          "input_type": "search_query" if role == "q" else "search_document"}, {"Authorization": f"Bearer {key}"})
                out += r["embeddings"]["float"]
                tokens = ((r.get("meta") or {}).get("billed_units") or {}).get("input_tokens") or sum(len(t) // 3 for t in batch)
            elif prov == "voyage":
                r = _http("https://api.voyageai.com/v1/embeddings", {"model": model, "input": batch,
                          "input_type": "query" if role == "q" else "document"}, {"Authorization": f"Bearer {key}"})
                out += [d["embedding"] for d in r["data"]]
                tokens = (r.get("usage") or {}).get("total_tokens") or sum(len(t) // 3 for t in batch)
            elif prov == "gemini":
                task = "RETRIEVAL_QUERY" if role == "q" else "RETRIEVAL_DOCUMENT"
                reqs = [{"model": f"models/{model}", "content": {"parts": [{"text": t}]}, "taskType": task} for t in batch]
                r = _http(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:batchEmbedContents",
                          {"requests": reqs}, {"x-goog-api-key": key})
                out += [e["values"] for e in r["embeddings"]]
                tokens = sum(len(t) // 3 for t in batch)
            else:
                raise ValueError(prov)
            charge(prov, tokens * price / 1e6)
        return _normalize(out)

    return run([qf(t) for t in queries], "q"), run([df(t) for t in docs], "d")


def embed(name, queries, docs, models_dir, port=None):
    """Return (Q, D) L2-normalised float32 matrices for raw query/document strings."""
    cfg = MODELS[name]
    if cfg["kind"] == "llama":
        return _embed_llama(cfg, models_dir, queries, docs, port)
    return _embed_api(cfg, queries, docs)
