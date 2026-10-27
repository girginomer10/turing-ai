"""Pilot first look: validator pass counts per extractor family, proposal counts, and the LLM pre-annotation ESTIMATE
(not truth) of how many proposals look unsupported, plus examples for the human annotators' attention.
Writes work/first_look.md (hidden from annotators because it shows pre-annotations). No API calls.

Run from benchmarks/verifier:  python -I first_look.py
"""
import collections, glob, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
WORK = os.path.join(HERE, "work")


def load(path):
    return [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]


def main():
    convs = load(os.path.join(DATA, "conversations.jsonl"))
    user_msgs = sum(1 for c in convs for t in c["turns"] if t["role"] == "user")
    langs = collections.Counter(c["lang"] for c in convs)
    out = ["# Pilot first look (generated; pre-annotation numbers are an LLM ESTIMATE, not ground truth)", "",
           f"Conversations: {len(convs)} ({dict(langs)}), user messages: {user_msgs}.", ""]
    out.append("## Extraction and validation per family\n")
    out.append("| family | messages | model errors | invalid output (validator) | valid | apply mirror failed | upsert proposals (stored) | forget ops | created / updated / reinforced | cost $ | s/msg |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for path in sorted(glob.glob(os.path.join(DATA, "extractions.*.jsonl"))):
        rows = load(path)
        fam = rows[0]["family"] if rows else os.path.basename(path)
        errs = sum(1 for r in rows if r.get("error"))
        invalid = collections.Counter(r.get("validation_error") for r in rows if r.get("valid") is False)
        valid = sum(1 for r in rows if r.get("valid"))
        apply_failed = sum(1 for r in rows if r.get("valid") and not r.get("apply_ok"))
        changes = collections.Counter(c["kind"] for r in rows if r.get("apply_ok") for c in r.get("changes", []))
        upserts = sum(1 for r in rows if r.get("apply_ok") for o in r["operations"] if o["action"] == "upsert")
        forgets = sum(1 for r in rows if r.get("apply_ok") for o in r["operations"] if o["action"] == "forget")
        cost = sum(r.get("cost") or 0 for r in rows)
        secs = [r["seconds"] for r in rows if r.get("seconds")]
        inv_txt = ", ".join(f"{k}: {v}" for k, v in invalid.most_common(4)) or "0"
        out.append(f"| {fam} | {len(rows)} | {errs} | {sum(invalid.values())} ({inv_txt}) | {valid} | {apply_failed} | {upserts} | {forgets} | "
                   f"{changes['created']} / {changes['updated'] + changes['reactivated']} / {changes['reinforced']} | {cost:.3f} | {sum(secs) / max(1, len(secs)):.1f} |")
    props = [p for p in load(os.path.join(DATA, "proposals.jsonl")) if p.get("apply_ok")] if os.path.exists(os.path.join(DATA, "proposals.jsonl")) else []
    by_kind = collections.Counter(p["operation"]["kind"] for p in props)
    out += ["", f"Stored upsert proposals (labeling population): {len(props)}; by kind: {dict(by_kind.most_common())}.", ""]
    for path in sorted(glob.glob(os.path.join(WORK, "preannotation", "*.jsonl"))):
        pre = {r["proposal_id"]: r for r in load(path) if r.get("label")}
        model = os.path.basename(path)[:-6]
        out.append(f"## Pre-annotation estimate by `{model}` (NOT ground truth; one cheap model, one pass)\n")
        out.append("| slice | proposals judged | supports | insufficient | contradicts |")
        out.append("|---|---|---|---|---|")

        def line(name, rows):
            c = collections.Counter(pre[p["proposal_id"]]["label"] for p in rows if p["proposal_id"] in pre)
            n = sum(c.values())
            if n:
                out.append(f"| {name} | {n} | {c['supports']} ({c['supports'] / n:.0%}) | {c['insufficient']} ({c['insufficient'] / n:.0%}) | {c['contradicts']} ({c['contradicts'] / n:.0%}) |")

        line("all", props)
        for fam in sorted({p["family"] for p in props}):
            line(f"family {fam}", [p for p in props if p["family"] == fam])
        for lang in ("tr", "en", "mixed"):
            line(f"lang {lang}", [p for p in props if p["lang"] == lang])
        for kind in ("created", "updated", "reinforced"):
            line(f"change {kind}", [p for p in props if p.get("change_kind") == kind])
        flagged = [p for p in props if p["proposal_id"] in pre and pre[p["proposal_id"]]["label"] != "supports"]
        tags = collections.Counter(t for p in flagged for t in pre[p["proposal_id"]].get("tags", []))
        convs_per_tag = {t: len({p["conversation_id"] for p in flagged if t in pre[p["proposal_id"]].get("tags", [])}) for t in tags}
        out += ["", f"Flagged (insufficient or contradicts): {len(flagged)} proposals in {len({p['conversation_id'] for p in flagged})} distinct conversations. "
                f"Tags (count / distinct conversations): " + ", ".join(f"{t} {n}/{convs_per_tag[t]}" for t, n in tags.most_common()) + ".", ""]
        out.append("### Examples worth the humans' attention (first 30 flagged, in file order)\n")
        for p in flagged[:30]:
            op = p["operation"]; j = pre[p["proposal_id"]]
            ex = p.get("existing_topic") or p.get("existing_topic_by_target")
            out.append(f"- **{j['label']}** {j.get('tags')} | msg: \"{p['message'][:220]}\" -> [{op['kind']}] {op['title']}: {op['content'][:200]}"
                       + (f" (existing: {ex['content'][:120]})" if ex else "") + f" | reason: {j.get('reason', '')[:160]}")
    os.makedirs(WORK, exist_ok=True)
    open(os.path.join(WORK, "first_look.md"), "w", encoding="utf-8").write("\n".join(out) + "\n")
    print("\n".join(out[:40]))
    print("wrote", os.path.join(WORK, "first_look.md"))


if __name__ == "__main__":
    main()
