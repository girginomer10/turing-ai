"""Run the app's own memory extraction over the pilot conversations, message by message, with memory state carried
forward, through one or more cheap extractor families.

For every user message the request (system prompt + JSON envelope) is built by the real Swift code
(Validate/.build/release/MemoryValidate -> AutomaticMemoryExtractor.request) from exactly one user message and the
visible topic snapshots, the model answers once, and the answer goes through the real deterministic validator
(AutomaticMemoryExtractor.parseAndValidate). Retained operations are then applied to an in-memory mirror of
AutomaticMemoryStore.apply (create / update / reinforce / forget; the mirror is documented in SPEC.md) so the next
message sees the same existing_topics the app would send. One attempt per message, no retry on invalid output
(the app would mark the job failed; a later recovery retry is out of scope for the pilot).

Outputs (data/): extractions.<family>.jsonl (one row per user message) and proposals.jsonl (one row per retained
upsert operation, all families; the labeling population). Re-runs skip (family, message) pairs already on disk.

Run from benchmarks/verifier:  python -I extract.py --families oa:gpt-6-luna di:Qwen/Qwen3.8-Flash [--limit 5]
"""
import argparse, concurrent.futures as cf, datetime as dt, json, os, subprocess, sys, threading, unicodedata, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import llm  # noqa: E402

DATA = os.path.join(HERE, "data")
HARNESS = os.path.join(HERE, "Validate", ".build", "release", "MemoryValidate")
NS = uuid.UUID("c0d2b9a4-5a6e-4f0b-8b1d-6e2a3f4c5d6e")
MAXIMUM_EXISTING_TOPICS = 128
ALLOWED_KEY_CHARS = set("._-:/")


class Harness:
    """One MemoryValidate subprocess with a line protocol (one JSON in, one JSON out)."""

    def __init__(self):
        self.p = subprocess.Popen([HARNESS], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1, encoding="utf-8")

    def ask(self, obj):
        self.p.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n"); self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("harness exited")
        return json.loads(line)

    def close(self):
        try:
            self.p.stdin.close(); self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


# ---- mirror of AutomaticMemoryStore.apply (see SPEC.md "State mirror") ----

def fold(value):
    """AutomaticMemoryStore.normalizedValue: tr_TR lowercase, diacritic-insensitive, whitespace collapsed."""
    v = value.replace("I", "ı").replace("İ", "i").lower()
    v = "".join(c for c in unicodedata.normalize("NFD", v) if unicodedata.category(c) != "Mn")
    return " ".join(v.split())


def full_key(proposed, kind, scope, conversation_id):
    """AutomaticMemoryStore.canonicalKey. Raises ValueError where the app throws invalidOperation."""
    chars = []
    for ch in proposed.lower():
        chars.append(ch if (ch.isalnum() or ch in ALLOWED_KEY_CHARS) else "_")
    normalized = ""
    for ch in chars:
        if ch != "_" or (normalized and normalized[-1] != "_"):
            normalized += ch
    normalized = normalized.strip("._-:/")
    if not normalized:
        raise ValueError("empty key")
    prefix = f"global:{kind}:" if scope == "global" else f"conversation:{conversation_id.lower()}:{kind}:"
    if scope == "project":
        raise ValueError("project scope without project")
    if normalized.startswith(("global:", "project:", "conversation:")) and not normalized.startswith(prefix):
        raise ValueError("foreign prefix")
    suffix = normalized[len(prefix):] if normalized.startswith(prefix) else normalized
    if suffix.startswith(kind + "."):
        suffix = suffix[len(kind) + 1:]
    if not suffix:
        raise ValueError("empty suffix")
    value = prefix + suffix
    if len(value.encode()) > 512:
        raise ValueError("key too long")
    return value


RANK = {"evolving": 0, "stable": 1, "permanent": 2}


def apply_ops(store, ops, conversation_id, message, now, snapshot_ids):
    """Returns (ok, error, changes). `store` is a list of topic dicts (all statuses). Mutates store only on success."""
    import copy
    work = copy.deepcopy(store)
    by_id = {t["id"]: t for t in work}
    seen_keys, changes = set(), []
    for op in ops:
        try:
            key = full_key(op["canonical_key"], op["kind"], op["scope"], conversation_id)
        except ValueError as e:
            return False, f"invalidOperation(canonicalKey: {e})", []
        if key in seen_keys:
            return False, "invalidOperation(duplicate key in envelope)", []
        seen_keys.add(key)
        topic = None
        if op.get("target_id"):
            topic = by_id.get(op["target_id"].lower())
            if topic is None:
                return False, "missingTopic", []
            if not (topic["scope"] == op["scope"] and topic["kind"] == op["kind"] and topic["canonicalKey"] == key):
                return False, "invalidOperation(target mismatch)", []
        else:
            found = [t for t in work if t["canonicalKey"] == key]
            if found:
                topic = found[0]
                if not (topic["kind"] == op["kind"] and topic["scope"] == op["scope"]):
                    return False, "invalidOperation(key resolves to different kind/scope)", []
        if topic is not None and topic["id"] not in snapshot_ids:
            return False, "staleSource(topic not in the sent snapshot)", []
        if op["action"] == "forget" and topic is None:
            continue
        if topic is not None and topic["kind"] == "event" and message["createdAt"] < topic["lastConfirmedAt"]:
            continue
        if op["action"] == "upsert" and topic is None:
            topic = dict(id=str(uuid.uuid5(NS, f"{conversation_id}/{message['id']}/{key}")), canonicalKey=key, title=op["title"], content=op["content"],
                         kind=op["kind"], scope=op["scope"], conversationID=conversation_id if op["scope"] == "conversation" else None, projectID=None,
                         status="active", origin="automatic", confidence=op["confidence"], importance=op["importance"], stability=op["stability"],
                         isEnabled=True, lastConfirmedAt=now, lastUsedAt=None, useCount=0, evidenceCount=1, revision=1, createdAt=now, updatedAt=now)
            work.append(topic); by_id[topic["id"]] = topic
            changes.append(dict(kind="created", topic_id=topic["id"], key=key, previous=None)); continue
        previous = dict(topic)
        topic["revision"] += 1; topic["evidenceCount"] += 1; topic["lastConfirmedAt"] = now; topic["updatedAt"] = now
        if op["action"] == "forget":
            topic["status"] = "forgotten"; topic["isEnabled"] = False
            changes.append(dict(kind="forgotten", topic_id=topic["id"], key=key, previous=previous)); continue
        same = fold(topic["content"]) == fold(op["content"])
        enable = True if previous["status"] == "forgotten" else previous["isEnabled"]
        if same and previous["status"] == "active":
            topic.update(title=op["title"], content=op["content"],
                         confidence=min(0.99, max(previous["confidence"], 1 - (1 - previous["confidence"]) * (1 - op["confidence"] * 0.35))),
                         importance=max(previous["importance"], op["importance"]),
                         stability=previous["stability"] if RANK[previous["stability"]] >= RANK[op["stability"]] else op["stability"],
                         status="active", isEnabled=enable)
            changes.append(dict(kind="reinforced", topic_id=topic["id"], key=key, previous=previous))
        else:
            topic.update(title=op["title"], content=op["content"], confidence=op["confidence"], importance=max(previous["importance"], op["importance"]),
                         stability=op["stability"], status="active", isEnabled=enable, origin="automatic")
            changes.append(dict(kind="reactivated" if previous["status"] == "forgotten" else "updated", topic_id=topic["id"], key=key, previous=previous))
    store[:] = work
    return True, None, changes


def visible(store, conversation_id):
    rows = [t for t in store if t["status"] == "active" and t["isEnabled"] and
            ((t["scope"] == "global" and t["conversationID"] is None) or (t["scope"] == "conversation" and t["conversationID"] == conversation_id))]
    rows.sort(key=lambda t: (t["updatedAt"], t["id"]))
    rows.reverse()  # updatedAt desc; ties by id are not order-critical for the request
    return rows[:MAXIMUM_EXISTING_TOPICS]


def plus_seconds(iso, s):
    return (dt.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ") + dt.timedelta(seconds=s)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run_conversation(conv, family, harness, done, out_lock, ext_file, prop_file):
    cid = conv["conversation_id"]
    conversation_uuid = str(uuid.uuid5(NS, cid))
    store = []
    turns = conv["turns"]
    for i, t in enumerate(turns):
        if t["role"] != "user" or not t["text"].strip():
            continue
        assistant = next((u for u in turns[i + 1:] if u["role"] == "assistant"), None)
        key = (family, t["id"])
        if key in done:
            row = done[key]
            if row.get("apply_ok"):
                ok, err, _ = apply_ops(store, row["operations"], conversation_uuid, t, plus_seconds(t["createdAt"], 30), {s["id"] for s in row["snapshot"]})
            continue
        snapshot = visible(store, conversation_uuid)
        base = dict(conversationID=conversation_uuid, throughUserMessageID=t["id"],
                    assistantMessageID=assistant["id"] if assistant else str(uuid.uuid5(NS, t["id"] + "/a")),
                    message=dict(id=t["id"], role="user", content=t["text"], createdAt=t["createdAt"]), existingTopics=snapshot)
        req = harness.ask(dict(base, op="request"))
        if not req.get("ok"):
            row = dict(family=family, conversation_id=cid, message_id=t["id"], turn=i, error="request: " + req.get("error", ""), snapshot=snapshot)
        else:
            resp = llm.call(family, req["system"], req["user"], extra={"max_tokens": req["maxOutputTokens"]} if family.startswith(("or:", "di:")) else {"max_completion_tokens": req["maxOutputTokens"]})
            row = dict(family=family, conversation_id=cid, message_id=t["id"], turn=i, lang=conv["lang"], message=t["text"], createdAt=t["createdAt"],
                       snapshot=snapshot, prompt_version=req["promptVersion"], request_bytes=len(req["user"].encode()),
                       seconds=resp.get("seconds"), cost=resp.get("cost"), tokens_in=resp.get("tokens_in"), tokens_out=resp.get("tokens_out"),
                       raw=resp.get("text", ""), error=resp.get("error"))
            if not resp.get("error"):
                val = harness.ask(dict(base, op="validate", response=resp["text"]))
                row["valid"] = bool(val.get("ok")); row["validation_error"] = val.get("error"); row["operations"] = val.get("operations", [])
                if row["valid"]:
                    ok, err, changes = apply_ops(store, row["operations"], conversation_uuid, t, plus_seconds(t["createdAt"], 30), {s["id"] for s in snapshot})
                    row["apply_ok"], row["apply_error"], row["changes"] = ok, err, changes
        with out_lock:
            ext_file.write(json.dumps(row, ensure_ascii=False) + "\n"); ext_file.flush()
            if row.get("valid"):
                for j, op in enumerate(row["operations"]):
                    if op["action"] != "upsert":
                        continue
                    change = next((c for c in row.get("changes", []) if c["key"] == safe_key(op, conversation_uuid)), None)
                    prop = dict(proposal_id=f"{cid}/{t['id'][:8]}/{family.split(':', 1)[1].split('/')[-1]}/{j}", family=family, conversation_id=cid,
                                message_id=t["id"], turn=i, lang=conv["lang"], message=t["text"], createdAt=t["createdAt"], operation=op,
                                apply_ok=row.get("apply_ok"), apply_error=row.get("apply_error"),
                                change_kind=change["kind"] if change else None, existing_topic=change["previous"] if change else None,
                                existing_topic_by_target=next((s for s in snapshot if op.get("target_id") and s["id"].lower() == op["target_id"].lower()), None))
                    prop_file.write(json.dumps(prop, ensure_ascii=False) + "\n"); prop_file.flush()
    return cid


def safe_key(op, conversation_uuid):
    try:
        return full_key(op["canonical_key"], op["kind"], op["scope"], conversation_uuid)
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--families", nargs="+", required=True)
    ap.add_argument("--limit", type=int, default=0, help="only the first N conversations")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--conversations", default=os.path.join(DATA, "conversations.jsonl"), help="input JSONL (default: data/conversations.jsonl)")
    ap.add_argument("--out-dir", default=DATA, help="where extractions.<family>.jsonl and proposals.jsonl go (use the private directory for real messages)")
    a = ap.parse_args()
    convs = [json.loads(l) for l in open(a.conversations, encoding="utf-8") if l.strip()]
    convs.sort(key=lambda c: c["conversation_id"])
    if a.limit:
        convs = convs[:a.limit]
    out_lock = threading.Lock()
    os.makedirs(a.out_dir, exist_ok=True)
    prop_path = os.path.join(a.out_dir, "proposals.jsonl")
    for family in a.families:
        ext_path = os.path.join(a.out_dir, "extractions." + family.replace(":", "_").replace("/", "_") + ".jsonl")
        done = {}
        if os.path.exists(ext_path):
            for l in open(ext_path, encoding="utf-8"):
                r = json.loads(l); done[(r["family"], r["message_id"])] = r
        local = threading.local()

        def get_harness():
            if not hasattr(local, "h"):
                local.h = Harness()
            return local.h

        with open(ext_path, "a", encoding="utf-8") as ext_file, open(prop_path, "a", encoding="utf-8") as prop_file, cf.ThreadPoolExecutor(a.workers) as ex:
            futs = [ex.submit(lambda c: run_conversation(c, family, get_harness(), done, out_lock, ext_file, prop_file), c) for c in convs]
            n = 0
            for fut in cf.as_completed(futs):
                try:
                    fut.result(); n += 1
                except Exception as e:  # BudgetExceeded or harness failure: stop cleanly
                    print("STOP:", type(e).__name__, str(e)[:200], flush=True)
                    for f in futs: f.cancel()
                    break
                if n % 10 == 0:
                    print(f"  {family}: {n}/{len(convs)} conversations, phase spent ${llm.phase_spent():.3f}", flush=True)
        print(f"{family}: done, phase spent ${llm.phase_spent():.3f}", flush=True)


if __name__ == "__main__":
    main()
