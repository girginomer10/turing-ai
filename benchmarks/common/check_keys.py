#!/usr/bin/env python3
"""Smoke-test every key in benchmarks/.env with one tiny request each. Never prints a key."""
import json, os, urllib.error, urllib.request
import embedders

embedders.load_env()


def call(name, url, headers=None, payload=None):
    key_present = True
    try:
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **(headers or {})})
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            body = json.load(e)
        except Exception:
            body = {}
        msg = (body.get("error") or {}) if isinstance(body, dict) else {}
        msg = msg.get("message") if isinstance(msg, dict) else str(msg)[:120]
        return e.code, {"error": (msg or "")[:140]}
    except Exception as e:
        return 0, {"error": type(e).__name__}


def env(k): return os.environ.get(k, "")

rows = []
if env("OPENROUTER_API_KEY"):
    s, d = call("openrouter", "https://openrouter.ai/api/v1/key", {"Authorization": "Bearer " + env("OPENROUTER_API_KEY")})
    info = d.get("data", {}) if s == 200 else {}
    rows.append(("OpenRouter", s, f"limit={info.get('limit')} remaining={info.get('limit_remaining')} usage={info.get('usage')} free_tier={info.get('is_free_tier')}" if s == 200 else d.get("error")))
if env("OPENAI_API_KEY"):
    s, d = call("openai", "https://api.openai.com/v1/embeddings", {"Authorization": "Bearer " + env("OPENAI_API_KEY")}, {"model": "text-embedding-3-small", "input": "ping"})
    rows.append(("OpenAI embeddings", s, "ok" if s == 200 else d.get("error")))
if env("GEMINI_API_KEY"):
    s, d = call("gemini", "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent", {"x-goog-api-key": env("GEMINI_API_KEY")},
                {"model": "models/gemini-embedding-001", "content": {"parts": [{"text": "ping"}]}})
    rows.append(("Gemini embedding-001", s, "ok" if s == 200 else d.get("error")))
if env("DEEPINFRA_API_KEY"):
    s, d = call("deepinfra", "https://api.deepinfra.com/v1/openai/embeddings", {"Authorization": "Bearer " + env("DEEPINFRA_API_KEY")}, {"model": "BAAI/bge-m3", "input": "ping"})
    rows.append(("DeepInfra embeddings", s, "ok" if s == 200 else d.get("error")))
if env("VOYAGE_API_KEY"):
    s, d = call("voyage", "https://api.voyageai.com/v1/embeddings", {"Authorization": "Bearer " + env("VOYAGE_API_KEY")}, {"model": "voyage-3.5", "input": ["ping"], "input_type": "query"})
    rows.append(("Voyage embeddings", s, "ok" if s == 200 else d.get("error")))
if env("COHERE_API_KEY"):
    s, d = call("cohere", "https://api.cohere.com/v2/embed", {"Authorization": "Bearer " + env("COHERE_API_KEY")},
                {"model": "embed-v4.0", "texts": ["ping"], "input_type": "search_query", "embedding_types": ["float"]})
    rows.append(("Cohere embed-v4.0", s, "ok" if s == 200 else d.get("error")))
for name, status, note in rows:
    print(f"{name:22s} HTTP {status:<4d} {note}")
