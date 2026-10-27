"""Build the blind labeling packet from data/proposals.jsonl.

Population: retained upsert operations whose envelope passed the real validator AND whose apply mirror succeeded
(apply_ok), i.e. memories the app would actually store. Rows are shuffled with a fixed seed; model family,
conversation id and proposal id are hidden (the mapping lives in work/labeling/packet_key.csv).

Outputs (work/labeling/): packet_core.csv (both annotators, for agreement), packet_rest_A.csv and packet_rest_B.csv
(split of the remainder), packet_key.csv (hidden mapping), and a copy of LABELING_GUIDE.md.
Run from benchmarks/verifier:  python -I make_packet.py [--core 300]
"""
import argparse, csv, json, os, random, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
OUT = os.path.join(HERE, "work", "labeling")
COLUMNS = ["row_id", "message_time", "user_message", "existing_memory", "proposal_kind", "proposal_action", "proposal_title",
           "proposal_content", "label", "tags", "note"]


def existing_text(p):
    t = p.get("existing_topic") or p.get("existing_topic_by_target")
    if not t:
        return ""
    return f"[{t['kind']}] {t['title']}: {t['content']}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", type=int, default=300)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--include-apply-failed", action="store_true")
    a = ap.parse_args()
    rows = [json.loads(l) for l in open(os.path.join(DATA, "proposals.jsonl"), encoding="utf-8") if l.strip()]
    if not a.include_apply_failed:
        rows = [r for r in rows if r.get("apply_ok")]
    seen, uniq = set(), []
    for r in rows:
        if r["proposal_id"] in seen:
            continue
        seen.add(r["proposal_id"]); uniq.append(r)
    rng = random.Random(a.seed)
    rng.shuffle(uniq)
    os.makedirs(OUT, exist_ok=True)
    packet, key = [], []
    for n, p in enumerate(uniq, 1):
        rid = f"r{n:04d}"
        op = p["operation"]
        action = {"created": "new memory", "updated": "update of the existing memory", "reinforced": "restates the existing memory",
                  "reactivated": "re-activates a forgotten memory"}.get(p.get("change_kind"), "new memory")
        packet.append(dict(row_id=rid, message_time=p["createdAt"], user_message=p["message"][:1200], existing_memory=existing_text(p),
                           proposal_kind=op["kind"], proposal_action=action, proposal_title=op["title"], proposal_content=op["content"],
                           label="", tags="", note=""))
        key.append(dict(row_id=rid, proposal_id=p["proposal_id"], family=p["family"], conversation_id=p["conversation_id"], message_id=p["message_id"], lang=p["lang"]))
    core, rest = packet[:a.core], packet[a.core:]
    half = len(rest) // 2
    for name, part in [("packet_core.csv", core), ("packet_rest_A.csv", rest[:half]), ("packet_rest_B.csv", rest[half:])]:
        with open(os.path.join(OUT, name), "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=COLUMNS); w.writeheader(); w.writerows(part)
    with open(os.path.join(OUT, "packet_key.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(key[0].keys())); w.writeheader(); w.writerows(key)
    shutil.copy(os.path.join(HERE, "LABELING_GUIDE.md"), os.path.join(OUT, "LABELING_GUIDE.md"))
    fams = {}
    for k in key:
        fams[k["family"]] = fams.get(k["family"], 0) + 1
    print(f"{len(packet)} rows: core {len(core)}, rest A {half}, rest B {len(rest) - half}; per family {fams}; written to {OUT}")


if __name__ == "__main__":
    main()
