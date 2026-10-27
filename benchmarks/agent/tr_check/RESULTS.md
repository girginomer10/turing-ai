# Turkish controller check (day 1)

Question: can a 1-2B open-weights model, run locally through llama.cpp `llama-server`, (1) understand Turkish questions and Turkish/code-switched chat snippets and (2) produce a valid action for the memory-research controller? The answer decides which base model gets fine-tuned.

Run date: 2026-10-24. Hardware: Mac M4 Pro, 24 GB, Metal. Server: llama.cpp `llama-server` version 0.7.0 (build 11669, commit 620d2225c).

## Models

| key | GGUF repo / file | size | upstream | licence (from model card front matter) |
|---|---|---|---|---|
| `qwen35_2b` | `unsloth/Qwen3.5-2B-GGUF` / `Qwen3.5-2B-Q8_0.gguf` (snapshot `f6d5376b`) | 2,012,012,800 B | `Qwen/Qwen3.5-2B` | `apache-2.0` (stated on both the Qwen and the unsloth card) |
| `gemma3_1b` | `ggml-org/gemma-3-1b-it-GGUF` / `gemma-3-1b-it-Q8_0.gguf` (snapshot `f9c28bcd`) | 1,069,306,368 B | `google/gemma-3-1b-it` | `gemma` (Gemma Terms of Use; the upstream repo is gated) |

- Qwen does not publish a GGUF for Qwen3.5. The unsloth build is the most downloaded one. Only the text model was downloaded; the vision projector (`mmproj`) was left out.
- Thinking: the Qwen3.5-2B card says the 2B model runs in non-thinking mode by default. The script also sends `chat_template_kwargs: {"enable_thinking": false}` and starts the server with `--reasoning off`. `/apply-template` shows the prompt ending in an empty `<think>\n\n</think>` block, and no `reasoning_content` came back. Gemma 3 has no thinking mode.
- Models left out: **Gemma 4 E2B-it**. Its smallest sensible GGUF is 2.84 GB (Q4_0, ggml-org), which would push the total download past the 4 GB limit. Its BF16 file is 9.3 GB, which means about 4.6B stored parameters, so it is not really in the 1-2B class for fine-tuning. **Qwen3-1.7B** (official Q8_0, 1.83 GB) was left out because Qwen3.5-2B replaces it and both would not fit the download budget. Neither model was tested.

## Setup

- `items.json`: 20 controller items (6 first-step, 6 select, 4 second-hop, 4 stop) and 5 free-text comprehension probes. All content is fictional and written in Turkish, some of it mixed with English. Every check is a program, with no LLM judge.
- `action_schema.json`: `oneOf` over search / expand / select / stop, with `additionalProperties: false`. The schema is sent as `response_format: {type: json_schema}` on `/v1/chat/completions` with `--jinja`, so each model's own chat template is used. A sanity check showed the constraint is really enforced: asked for a poem with the schema on, Gemma returned a schema-shaped JSON object instead.
- Decoding: `temperature 0`, `top_k 1`, `seed 0`, one slot, `-c 4096`, `-ngl 99`. `cache_prompt` is off, so every call processes the full prompt (about 450 tokens) from cold.
- Matching uses Turkish folding: `İ→i`, `I→ı`, lowercase, then `ı ğ ü ş ö ç` mapped to `i g u s o c`.
- Scoring rules:
  - first_step / second_hop: the action is `search` and the folded query contains the key entity (first step) or the bridge entity (second hop).
  - select: **strict** means the action is `select` with exactly the gold id set. **Lenient** means every gold id is selected and no stale (superseded) id is.
  - stop: **strict** means `stop`. **Lenient** also accepts `select` of exactly the gold ids, because a select-then-stop controller ends with the right pack.
  - valid: the first JSON object in the reply passes the schema. clean: the whole reply is one schema-valid object, with no prose and no code fences.
  - sel. target=gold: a diagnostic. On select items, it counts replies whose `select` ids or `expand` source point at a gold message and not at the stale one, whatever the verb.
- Prompt variants:
  - **v1** is the original system prompt.
  - **v2** and **v3** are post-hoc: they were written after seeing that Qwen chose `expand` almost every time. v2 adds "first matching rule wins" and limits `expand` to visibly cut-off messages. v3 is v2 with `expand` moved to the end of the action list.
  - **forced** is a post-hoc diagnostic. It uses the v1 prompt, but the schema is cut down to the branch of the expected action, so only the query or ids are up to the model. It is run on the 16 non-stop items.

Run with `/opt/homebrew/bin/python3 -I benchmarks/agent/tr_check/run_tr_check.py`. The script starts and stops `llama-server` itself. Raw outputs go to `benchmarks/agent/work/tr_check/`, which is git-ignored.

## Results

Each item was run once at temperature 0, and decoding was deterministic.

| model | prompt / constraint | valid | clean | strict | lenient | first | select | hop | stop | sel. target=gold | probes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Qwen3.5-2B Q8_0 | v1 / schema | 20/20 | 20/20 | 7/20 | 9/20 | 6/6 | 0/6 | 0/4 | 1/4 | 6/6 | 5/5 |
| Qwen3.5-2B Q8_0 | v1 / free | 20/20 | 20/20 | 7/20 | 9/20 | 6/6 | 0/6 | 0/4 | 1/4 | 6/6 | |
| Qwen3.5-2B Q8_0 | v2 / schema (post-hoc) | 20/20 | 20/20 | 7/20 | 8/20 | 6/6 | 0/6 | 0/4 | 1/4 | 6/6 | |
| Qwen3.5-2B Q8_0 | v3 / schema (post-hoc) | 20/20 | 20/20 | 6/20 | 6/20 | 6/6 | 0/6 | 0/4 | 0/4 | 5/6 | |
| Qwen3.5-2B Q8_0 | **v1 / forced** (diagnostic) | 16/16 | 16/16 | **15/16** | 15/16 | 6/6 | **6/6** | **3/4** | – | 6/6 | |
| Gemma-3-1B-it Q8_0 | v1 / schema | 20/20 | 20/20 | 8/20 | 8/20 | 6/6 | 1/6 | 1/4 | 0/4 | 2/6 | 4/5 |
| Gemma-3-1B-it Q8_0 | v1 / free | 20/20 | 17/20 | 8/20 | 8/20 | 6/6 | 1/6 | 1/4 | 0/4 | 2/6 | |
| Gemma-3-1B-it Q8_0 | v2 / schema (post-hoc) | 20/20 | 20/20 | 7/20 | 7/20 | 6/6 | 0/6 | 1/4 | 0/4 | 0/6 | |
| Gemma-3-1B-it Q8_0 | v3 / schema (post-hoc) | 20/20 | 20/20 | 6/20 | 6/20 | 6/6 | 0/6 | 0/4 | 0/4 | 1/6 | |
| Gemma-3-1B-it Q8_0 | **v1 / forced** (diagnostic) | 16/16 | 16/16 | **8/16** | 8/16 | 6/6 | **1/6** | **1/4** | – | 2/6 | |

The v2 and v3 free-text rows match the schema rows on every decision. The only difference is clean output for Gemma: 18/20 for v2 and 20/20 for v3.

### Speed and memory (v1 / schema)

| model | mean latency / call | generation tok/s | prompt tok/s | mean output tokens | model load | peak RSS | footprint at end |
|---|---|---|---|---|---|---|---|
| Qwen3.5-2B Q8_0 | 0.43 s | 99.8 | 1,492 | 12.6 | 1.1-1.7 s | 2,592 MB | 729 MB |
| Gemma-3-1B-it Q8_0 | 0.25 s | 161.0 | 3,003 | 16.4 | 0.9-1.2 s | 1,357 MB | 374 MB |

- Model load is the wall time from process start until `/health` returns ok, across the runs made that day. The model file was already in the OS page cache, so a truly cold load from disk was not measured.
- Peak RSS was sampled with `ps -o rss` every 0.2 s. It includes the memory-mapped weights.
- Footprint is macOS `footprint` (dirty memory only), read once at the end of the run, with a 4096-token context and one slot.
- Tokens per second come from llama-server's `timings`, summed over the 20 calls.

## What it shows

1. **Valid JSON is not the problem.** Both models produced schema-valid actions in all 272 action calls (136 per model), with or without the grammar. At temperature 0 the grammar never changed a decision. It only removed Gemma's extra output (code fences, echoed prompt text). Qwen's free-text replies were clean every time.
2. **Turkish understanding differs a lot.** With the verb fixed (the forced pass), Qwen picked exactly the right ids on 6/6 select items. That includes choosing the newer of two conflicting values (2025 İzmir over 2024 Ankara, Togg over Fiat, Kuzey Yazılım over Trendlab) and both answer messages on the two two-message items. It put the bridge entity into 3/4 second-hop queries. Gemma got 1/6 and 1/4: it often chose the stale value, or a message about the wrong person.
3. **Neither model follows the controller rules zero-shot.** Qwen keeps answering `expand` on the right message: 6/6 select items and 4/4 second-hop items under v1 and v2. Under v3 it did the same on 5/6 select items, all 4 second-hop items and all 4 stop items. On v1 stop items it chose `select` twice, `expand` once and `stop` once. Gemma keeps searching again, mostly by restating the question. Neither model ever chose `stop` when the evidence was complete, except Qwen on one item.

## Failure examples (v1 unless noted)

1. **Qwen, select_01**: replied `{"action":"expand","source":"m12"}`. m12 is the correct and most recent message, but the expected reply was `select ["m12"]`. The same pattern appears on all 6 select items, which is why the target=gold diagnostic is 6/6 while strict select is 0/6.
2. **Qwen, hop_01**: replied `expand h11` instead of searching for Kaan. Even in the forced pass the query was `"Kaan Burcu Atlas lideri"`, which also names the stale leader Burcu. **Forced hop_03** restated the question (`"Mert'in en sevdiği restoranın sahibi"`) and missed the bridge "Lokanta Mavi".
3. **Gemma, select_04 / select_06**: replied `select ["z1"]`, the stale "Trendlab" message, and `select ["i4"]`, which is about Işıl's car, not İlkay's. **Forced select_01** gave `["m11","m12","m13"]`: the stale message, the right one and an unrelated one.
4. **Gemma, hop_01 / stop_03**: replied `search "Atlas projesinin şu anki lideri hangi şehirde yaşıyor"`, a copy of the question. On stop items it searches again for things it already searched (`"Selin Eskişehir"` after `"Selin taşındı"`).
5. **Gemma, free text**: once wrapped the JSON in ```` ```json ```` fences, and twice copied a line of the system prompt after the object (`{"action":"search","query":"Lokanta Mavi"} search past messages; write the query in ...`). Probe 1 answered `"Eskişehir'e."` and left out who moved.

## Recommendation

**Fine-tune Qwen3.5-2B.**

- Its Turkish reading of the evidence is already good: 15/16 in the forced pass, 6/6 on picking the newest value, and 5/5 on the probes.
- It emits clean JSON every time, and its licence is Apache-2.0.
- Its zero-shot failure is one systematic verb bias (`expand`), which supervised fine-tuning on controller traces should be able to remove.

This last point is an inference, not yet tested. By contrast, Gemma-3-1B's errors are in the arguments themselves (stale or wrong-person ids, copying the question), which suggests weaker comprehension. That is a harder thing to fix with a small dataset (also unverified).

Qwen's costs are about 1.7x the latency (0.43 s vs 0.25 s per call) and about 2x the memory. Both are acceptable on this machine.

## Caveats and unverified points

- The test set is small: 20 items and 5 probes, all written by the same author who wrote the prompt. Read differences of one or two items as noise. The v2, v3 and forced rows were added after seeing the v1 results.
- The 4B and E2B-class models (Gemma 4 E2B, Qwen3.5-4B) and Qwen3-1.7B were not tested.
- The matching is lenient about spelling. Qwen spelled "Ilgaz" as "İlgaz", and folding counts that as a match.
- Unverified:
  - whether the Qwen3.5 architecture (an `image-text-to-text` checkpoint) is supported by the fine-tuning stack we plan to use;
  - Qwen3.5-2B's reported Turkish benchmark numbers (the card claims 201 languages; not checked for Turkish);
  - the full licence texts (only the front-matter licence strings were read).
- Disk: 3.08 GB of downloads in the default HF cache (`du`: 1.9G and 1.0G). The raw outputs are about 0.5 MB.
