"""Chat-completion client for the verifier pilot: OpenAI, OpenRouter and DeepInfra (OpenAI-compatible).

Keys come from benchmarks/.env through benchmarks/common/embedders.load_env() and are never printed or stored.
Every call is charged to the shared spend ledger (benchmarks/.spend.json) with the per-provider caps in
embedders.CAPS, plus a phase cap (PHASE_CAP_USD) measured against the ledger snapshot taken when this module
is first imported in a process. Reasoning is disabled where the provider allows it; temperature 0 where allowed.
"""
import json, os, sys, threading, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "common"))
import embedders  # noqa: E402

OPENAI = "https://api.openai.com/v1/chat/completions"
OPENROUTER = "https://openrouter.ai/api/v1/chat/completions"
DEEPINFRA = "https://api.deepinfra.com/v1/openai/chat/completions"

# spec -> (endpoint, key env, ledger provider, extra body, $/M input, $/M output; prices are fallbacks when the
# provider does not report a cost). DeepInfra reports usage.estimated_cost; OpenRouter reports usage.cost.
MODELS = {
    "oa:gpt-6-luna": (OPENAI, "OPENAI_API_KEY", "openai", {"max_completion_tokens": 2048}, 0.1, 0.5),
    "oa:gpt-6.1-sol": (OPENAI, "OPENAI_API_KEY", "openai", {"max_completion_tokens": 2048}, 2.0, 10.0),
    "or:qwen/qwen3.8-flash": (OPENROUTER, "OPENROUTER_API_KEY", "openrouter",
                              {"temperature": 0, "max_tokens": 2048, "reasoning": {"enabled": False}}, 0.15, 0.47),
    "di:Qwen/Qwen3.8-Flash": (DEEPINFRA, "DEEPINFRA_API_KEY", "deepinfra",
                              {"temperature": 0, "max_tokens": 2048, "reasoning_effort": "none"}, 0.3, 1.0),
    "di:google/gemma-4-31B-it": (DEEPINFRA, "DEEPINFRA_API_KEY", "deepinfra", {"temperature": 0.9, "max_tokens": 3000}, 0.3, 1.0),
    "di:deepseek-ai/DeepSeek-V4.1-Flash": (DEEPINFRA, "DEEPINFRA_API_KEY", "deepinfra",
                                           {"temperature": 0, "max_tokens": 2048, "reasoning_effort": "none"}, 0.3, 1.0),
}

PHASE_CAP_USD = 5.0
_lock = threading.Lock()
_start = None


def _ledger_total():
    try:
        return sum(json.load(open(embedders.LEDGER)).values())
    except (OSError, ValueError):
        return 0.0


def phase_spent():
    global _start
    if _start is None:
        _start = _ledger_total()
    return _ledger_total() - _start


def _charge(provider, usd):
    with _lock:
        embedders.charge(provider, usd)
        if phase_spent() > PHASE_CAP_USD:
            raise embedders.BudgetExceeded(f"phase spend ${phase_spent():.2f} exceeds the ${PHASE_CAP_USD:.2f} cap")


def call(spec, system, user, extra=None, retries=4):
    """Returns dict(text, seconds, cost, tokens_in, tokens_out[, error]). Never raises on HTTP errors."""
    endpoint, keyenv, provider, body_extra, pin, pout = MODELS[spec]
    embedders.load_env()
    phase_spent()  # take the ledger snapshot on first use
    model = spec.split(":", 1)[1]
    messages = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": user}]
    body = {"model": model, "messages": messages, **body_extra, **(extra or {})}
    for attempt in range(retries + 1):
        t0 = time.time()
        try:
            req = urllib.request.Request(endpoint, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json",
                                                  "Authorization": "Bearer " + os.environ[keyenv]})
            with urllib.request.urlopen(req, timeout=240) as r:
                d = json.load(r)
            u = d.get("usage") or {}
            cost = u.get("cost")
            if cost is None:
                cost = u.get("estimated_cost")
            if cost is None:
                cost = (u.get("prompt_tokens", 0) * pin + u.get("completion_tokens", 0) * pout) / 1e6
            _charge(provider, float(cost))
            choice = d["choices"][0]
            text = choice["message"].get("content") or ""
            return dict(text=text, seconds=time.time() - t0, cost=float(cost), tokens_in=u.get("prompt_tokens"),
                        tokens_out=u.get("completion_tokens"), finish=choice.get("finish_reason"))
        except urllib.error.HTTPError as e:
            try:
                detail = (json.load(e).get("error") or {}).get("message", "")[:160]
            except Exception:
                detail = ""
            if e.code in (429, 500, 502, 503) and attempt < retries:
                time.sleep(5 * (attempt + 1)); continue
            return dict(text="", error=f"HTTP {e.code} {detail}", seconds=time.time() - t0, cost=0.0)
        except (urllib.error.URLError, TimeoutError, KeyError) as e:
            if attempt < retries:
                time.sleep(3); continue
            return dict(text="", error=f"network {type(e).__name__}", seconds=time.time() - t0, cost=0.0)


def strip_fence(text):
    t = text.strip()
    if t.startswith("```"):
        first = t.find("\n")
        if first > 0 and t.endswith("```"):
            t = t[first + 1:-3].strip()
    return t
