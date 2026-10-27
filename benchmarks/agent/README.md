# Memory research agent: environment and first go/no-go

A small local model should learn to research a long Turkish/English chat archive in a few bounded steps
(`search(query)`, `expand(message)`, `select(messages)`, `stop`) and hand a short evidence pack with sources to the
chat model the user picked. This directory holds the programmatic environment that makes that measurable: synthetic
worlds whose answers and gold evidence are computed, not labelled.

Status: days 1–3 of the first go/no-go are done on template text. They were repeated on a paraphrased archive
and on a realistic chat archive (whole written sessions, split facts, relative dates).
* Day 1: the environment, 150 questions plus 25 controls, the rendering check (300/300 facts recovered on both
  surfaces, with the caveats below) and the small-model Turkish check
  ([tr_check/RESULTS.md](tr_check/RESULTS.md)).
* Day 2: single-shot retrieval against prompted research agents, all on template text (results below).
  * On two-hop questions a prompted strong agent finds the complete evidence where retrieval mostly cannot, even
    when retrieval reads as many messages.
  * On count questions the gain mostly comes from reading more.
  * The untrained 2B model is far below the strong agent.
* Day 3: a downstream answer model (ChatGPT) reads each pack.
  * Two-hop: 10 % right from (a)'s packs, 100 % from the agent's.
  * Count questions: 50 % against 78 %.
* The first go/no-go passes. Its main open risk was template text. On an archive whose fact and distractor turns
  were paraphrased (below), the two-hop gap holds: answers 6 % vs 100 %. That surface still keeps every name
  verbatim, so it is not yet realistic chat.

## Worlds (`world.py`, `render.py`, `make_worlds.py`)

* A seeded world is the archive owner's life from January 2024 to September 2026: 30 people (three first names shared
  by two people each), 8 projects and 60 dated events.
* Versioned facts: a person's city and employer (1–3 versions), a project's lead and deadline (1–3 versions), team
  joins and leaves, events with attendees, city and an optional project. About a quarter of people also have an
  unrealised plan to move after their latest move. The plan is a distractor that never changes state.
* Rendering: every fact version is stated in exactly one user message, a few days after it happens. The message can be
  Turkish, English or code-switched (55/30/15 %). Turkish case endings on proper nouns follow vowel harmony. People
  are named by full name, by first name (only when unambiguous) or by relation plus full name.
* The rest of the archive is noise sessions (recipes, code questions, translations, travel) and name-mention
  distractors that talk about a person or project without stating anything about them. About 54 % of sessions hold
  no fact.
* Per world: ~2,000 messages, ~490 sessions, ~270 fact-bearing messages. QC checks run on every build: each fact is
  stated exactly once, messages are in time order, versions are stated in order, and every gold fact has a message.

`messages.jsonl` carries gold fields (`facts`, `distractor`). Strip them before anything retrieves over the archive.

## Questions (`questions.py`)

All answers hold "now", at the end of the archive. Per world there are 10 questions per class plus 5 controls, and
templates are spread round-robin:

| class | templates | gold messages |
|---|---|---|
| latest_value | latest city / employer / project lead / deadline (the value changed at least once; stale versions recorded) | 1 |
| two_hop | city or employer of a project's current lead; deadline of the project a person currently leads; employer of the person I met on a given date and city | 2 |
| aggregate | how often I met X in a year; how many people live in a city now; how many who joined a team are still on it | 2–6 |
| one_hop (control) | a value that never changed | 1 |

The bridge entity of a two-hop question never appears in the question. Questions are in Turkish or English
independently of the evidence language.

Gold is the evidence a careful reader needs, not only the messages naming the answer. `count_city_now` also includes
the latest city message of everyone who used to live in that city. `count_team_now` includes every join and leave.
`led_project_deadline` only asks about people who never led another project. Person answers accept the bare first
name when it is unique in the world. Every class, controls included, uses "now"-style wording, so the wording does
not reveal the class.

### Known limits (from an independent audit of the generated files)

* `latest_value` gold is the chronologically last message about that subject and attribute. The only later
  distractor is an unrealised move plan (7 of 75 such questions). So "most recent hit for subject + attribute" solves
  it. It tests ranking by recency, not reasoning. Do not oversell a baseline-versus-agent gap on this class.
* Assistant replies are drawn so that a short acknowledgement no longer marks a fact turn: 47 % of bare
  acknowledgements and 30 % of acknowledgement-prefixed replies follow a fact turn, against about 27 % of all user
  turns. Long, substantive replies still only follow noise. Retrieval should index user turns only; `expand` sees
  the residual signal.
* Several noise prompts start with "Can you…", and "Can" is also a first name in the pool.
* English loanwords take suffixes by spelling, not by pronunciation (bash'ta, Labs'ta).
* Project lead and team membership are generated independently. Someone can leave a team and be named its lead a
  week later (found by a research agent in w4).

## Rendering check (`rewrite.py`, `rewrite_prompt.md`)

Template text is a deterministic floor; real chats are messier. 300 fact-bearing turns (60 per world, stratified by
language and fact type) are rewritten by one model family. A second family then re-extracts the facts without seeing
the gold. The same extractor also reads the template text, which controls for the extractor itself. The go/no-go
asks for at least 90 % recoverability per language.

What this does and does not show:
* The renderer saw the structured facts and was told to keep them. That makes it a cooperative paraphrase: median
  token Jaccard with the template is about 0.6, and 8 of 300 texts are unchanged.
* The extractor receives batched messages, a closed schema and each message's exact timestamp. Its working
  directory holds only the schema; this does not by itself prevent access to gold files elsewhere on the host.
* Events must match attendees, date, city, activity and project.
* These day-1 rewrites were not merged into the archives; days 2–3 used template text (`text == template_text`).
  The separate full `worlds_rw` archive has since been merged, as described under "Rewritten surface" below.

The rewrite batches predate a later change to 27 fact sentences (the "moved to another project" wording and
duplicate openers). Those 27 changes do not affect the facts being scored.

## Day 2: single-shot retrieval versus prompted research agents (template text)

* **Engine** (`retrieval.py`): BM25 over Turkish-folded stems and EmbeddingGemma-300M (Q8, llama.cpp) are fused
  by reciprocal rank, then bge-reranker-v2-m3 rescores the fused top 30. Only user turns are indexed.
* **Baselines** (`baselines.py`, `app_retriever.py`): the raw question is retrieved once and the pack is filled to
  8 messages.
  * (a) hybrid + rerank;
  * (b) (a) + same-session neighbours (±2 user turns);
  * the app's own `HybridMemoryRetriever` (Swift harness from `../memory`), with and without the same reranker.
* **Environment** (`env.py`): `search` (5 hits), `expand` (the session around a seen message), `select` (only ids
  shown in this question) and `stop`. At most 8 search/expand calls, and a pack of at most 8. Search uses the same
  engine as (a).
* **Agents** (`agent_prompt.md`, `small_agent.py`):
  * Claude subagents (`claude_opus`) and GPT through `codex exec` (`gpt_codex`), driving the CLI;
  * untrained Qwen3.5-2B Q8 (`qwen35_2b_prompted`), given the same guidance as JSON actions under a schema.

Evidence recall at a pack budget of 8. Each cell is mean recall / share of questions with every gold message in the
pack (50 questions per class, 25 controls). "(a) at equal reads" is (a)'s recall when it may show as many messages
as the agent was shown, which separates researching better from reading more.

| method | latest value | two-hop | aggregate | one-hop | searches / messages shown |
|---|---|---|---|---|---|
| (a) hybrid + rerank | 0.98 / 0.98 | 0.53 / 0.10 | 0.79 / 0.46 | 1.00 | 1 / 8 |
| (b) (a) + neighbours | 0.96 / 0.96 | 0.42 / 0.00 | 0.54 / 0.12 | 1.00 | 1 / 8 |
| app retriever + rerank | 1.00 / 1.00 | 0.55 / 0.12 | 0.76 / 0.46 | 1.00 | 1 / 8 |
| app retriever alone | 0.94 / 0.94 | 0.48 / 0.04 | 0.62 / 0.28 | 0.96 | 1 / 8 |
| **GPT agent, one question per context** | 1.00 / 1.00 | **1.00 / 1.00** | 0.89 / 0.66 | 1.00 | 6.0 / 34 |
| (a) at equal reads | 1.00 | 0.60 | 0.89 | 1.00 | |
| GPT agent, 35 questions per context | 1.00 / 1.00 | 1.00 / 1.00 | 0.96 / 0.88 | 1.00 | 3.3 / 17 |
| Claude agent, 35 questions per context | 1.00 / 1.00 | 0.94 / 0.94 | 0.92 / 0.70 | 1.00 | 5.4 / 27 |
| Qwen3.5-2B, prompted, untrained (v2) | 0.48 / 0.48 | 0.21 / 0.00 | 0.12 / 0.00 | 0.64 | 1.0 / 11 |
| Qwen3.5-2B, prompted, untrained (v1) | 0.00 | 0.00 | 0.00 | 0.00 | 1.0 / 30 |

* **Two-hop is the result.**
  * The GPT agent in a fresh context per question has every gold message on 50/50 questions. Its packs average 2.5
    messages, against 0.53 for (a): a paired difference of +0.47 [0.42, 0.52], 95 % bootstrap.
  * Given as many reads, (a) reaches only 0.60. Even at depth 20 it plateaus at 0.60, because hop 2 needs a name
    the question does not contain.
  * Cheap single-shot fixes stay at 0.36–0.62 (audit check on the live engine): TR+EN queries, entity-only queries,
    one pseudo-relevance round.
* **Aggregate gains are mostly reading.**
  * At budget 8 the fresh-context GPT agent is +0.10 [0.06, 0.15] over (a).
  * At equal reads (a) matches it (0.89 vs 0.89).
  * Count questions also exhaust the read budget (7–8 of 8 calls).
  * The agent's own counts are right on 80 % of these questions; with shared context the figure was 96 %.
* **Latest value saturates** for every method (README "Known limits"). It carries no information for the go/no-go.
* **Shared context inflates the strong agents.** With 35 questions in one context, earlier searches had already
  shown the bridge entity for 43–48 of 50 two-hop questions. Claude searched it before seeing it in that question
  5 times. Two-hop holds up in fresh contexts. Aggregate drops (0.96 to 0.89 recall), so fresh context is the
  number of record.
* **The untrained small model is far below the strong agent.**
  * v1 (plain harness): it never selects (1 select in 175 questions), so its packs are empty. That is a protocol
    failure, not a research floor.
  * v2 adds two guards: the environment refuses repeat expansions, and the first `stop` with an empty pack gets a
    reminder. It then selects sometimes, but searches once and stops early.
  * In both versions, the messages it was shown contain only 39 % of two-hop and aggregate gold.
  * Its own answers: latest value 0.74, two-hop 0.04, aggregate 0.04 (v2).
  * A trained model has to beat these numbers, not 0.00.
* **Answers.** The agents' own answers are checked programmatically against the computed answer. The fresh-context
  GPT agent gets 100 % on latest-value and two-hop. This says nothing yet about a downstream answer model reading the
  pack (day 3).
* **Integrity.** The GPT logs (all 175 fresh-context runs and the 5 per-world runs) contain only environment
  commands. Claude subagents could technically read files, so their compliance is self-reported.
* **Environment fixes after the first runs.** Four Claude packs were empty because `select` rejected a whole call
  when one id came from another question. `select` now adds the ids shown in this question and names the rest.
  Rejected calls are logged, and repeat expansions are refused. The per-world runs predate these fixes.

### Go/no-go against the plan

The rule: a tool agent beats the neighbour baseline (b) by at least 15 points of evidence recall on latest value or
multi-hop at equal budget, and the untrained small model is clearly below the strong agent.

| check | result |
|---|---|
| Agent beats (b) by at least 15 points on latest value or multi-hop | Met on two-hop: +0.58 over (b), and +0.47 over the stronger (a). Latest value is saturated. |
| Untrained small model clearly below the strong agent | Met: two-hop 0.21 vs 1.00; even what it was shown holds only 0.39 of the gold. |
| No stop condition triggered | Met: (b) is not within 5 points; the small model follows the action format under a schema; Turkish fact recoverability is ≥ 90 %. |

So the go/no-go passes on evidence retrieval. Two caveats:
* The text is still template text.
* On template text, hop 1 uses a closed vocabulary ("took over", "yönetiyor"). This makes decomposition easier than
  it will be in rewritten or real chat.

Day 3 (below) confirms the gap at the answer level. A run on a rewritten archive decides whether it survives
realistic text.

## Day 3: answer accuracy from the packs (`answer.py`)

ChatGPT, through `codex exec` on the subscription, answers each question from one pack. It sees only the question
and the pack's messages (date + text, no ids), is told to answer "unknown" when the pack is not enough, and runs in a
read-only sandbox whose working directory contains only the output schema.

How the calls are built:
* Several questions share one call to save calls.
* No two questions in a call name the same person or project, in any world.
* Items from all methods are shuffled together, so the model cannot tell which method made a pack.

Answers are checked programmatically against the computed answer (`score.answer_ok`).

Accuracy, 50 questions per class:

| pack | latest value | two-hop | aggregate | one-hop |
|---|---|---|---|---|
| no pack (question only) | 0.00 | 0.00 | 0.00 | 0.00 |
| gold messages only | 1.00 | 1.00 | 1.00 | 1.00 |
| (a) hybrid + rerank, top 8 | 0.98 | 0.10 | 0.50 | 0.96 |
| (b) (a) + neighbours | 0.94 | 0.00 | 0.36 | 0.92 |
| app retriever + rerank, top 8 | 0.98 | 0.12 | 0.50 | 0.88 |
| **GPT agent, one question per context** | 1.00 | **1.00** | **0.78** | 0.96 |
| Claude agent (35 per context; separate call set) | 1.00 | 0.94 | 0.90 | 1.00 |
| Qwen3.5-2B, prompted, untrained (v2) | 0.48 | 0.00 | 0.04 | 0.60 |

* **Answers follow complete evidence, not recall.** (a)'s two-hop packs hold 53 % of the gold messages but complete
  evidence for only 10 % of questions. The answer model gets exactly those 10 % right.
* Against (a), with 95 % bootstrap intervals:
  * the agent's packs gain +0.90 [0.80, 0.98] on two-hop;
  * on aggregate the gain is +0.28 [0.14, 0.42]. At equal reads the evidence recall was the same, so this is
    better-chosen evidence at a pack size of about 5 rather than better search.
* **The answer model is reliable and does not guess.** It scores 100 % with gold packs and 0 % with no pack (it says
  "unknown"). Pack quality is therefore the only thing that varies.
* **Packs built by the Claude agent score as well** (two-hop 0.94; the misses are its 3 empty packs). The gain is not
  a same-family effect between the GPT agent and the GPT answer model.
* Run-to-run noise: one gold-pack control answer differed between the two call sets (one-hop 1.00 vs 0.96).
* **Not covered yet:**
  * a second answer model family (the transfer claim);
  * rewritten or real chat text;
  * any trained controller.

## Rewritten surface: the two-hop gap survives paraphrase

`AGENT_SURFACE=rw` selects separate `work/worlds_rw`, `index_rw`, `runs_rw`, `answers_rw`, and `app_bench_rw`
directories. Leaving it unset retains the template paths. The environment command given to each Codex research
context includes the variable explicitly, so a child shell cannot silently select the template archive.

All 1,359 fact-bearing user messages and 393 name-mention distractors have been rewritten and merged into
`work/worlds_rw`. Coverage is exactly 1,752 unique IDs. Only `text` changed: `template_text`, message metadata,
all five world graphs, and all 175 questions and gold IDs are preserved. The original archive hashes are unchanged.
`rewrite_archive_finalize.py` validates complete acceptance records, linked source/output/review hashes, proper
names and copied-world invariants before merging. Raw outputs and every repair version remain under `work/`.

The final surface contains 177 Gemini 4 Argon texts (operator-reported model identity, not independently verified)
and 1,575 GPT-6 Astra texts generated at medium reasoning effort, including three repairs to a Gemini batch.
It does **not** meet the original independent-renderer-family condition: the research and answer models are also
GPT. This is a wording-robustness experiment, not an independent-family validation. Attribution is retained per
message. The Claude CLI route produced no rewrites. The frozen day-1 and original archive prompts are unchanged;
`rewrite_archive_gemini_prompt.md` contains the shared, clarified fidelity constraints.

Mechanical checks pass for every message; no rewrite is identical to its template. Semantic review found and
corrected unsupported details, gender assumptions and ambiguous residence statements. No material findings remain
in the reviewed final versions. This review is separate from the formal extraction gate.

| rewritten subset | messages | mean token Jaccard | mean characters, template → rewritten |
|---|---:|---:|---:|
| all | 1,752 | 0.314 | 60.3 → 65.7 |
| fact-bearing | 1,359 | 0.332 | 62.5 → 65.4 |
| distractors | 393 | 0.252 | 52.8 → 66.5 |
| Turkish | 966 | 0.319 | 62.4 → 64.8 |
| English | 505 | 0.329 | 57.1 → 62.0 |
| mixed | 281 | 0.270 | 59.0 → 75.3 |

Overall median Jaccard is 0.300. The 300 day-1 rewrites have mean 0.615 with the same tokenizer; the samples differ,
so this is not a paired comparison. Repeated replacement phrases, short sentence patterns and some redundant
recordkeeping filler remain. Lower overlap is not proof of naturalness or performance on real chat.

`rewrite_archive_recovery.py` freezes a 300-message sample, 100 per language, stratified by fact type without
replacement. Rare strata are exhausted: mixed-language move plans have only one example. The sample is not
population-weighted. It is partitioned into 31 calls with no repeated person first name or project within a call.
The extractor receives only IDs, timestamps and text, using explicit GPT-6 Astra / xhigh settings and a fresh
temporary working directory containing only its schema. Full event logs must show zero tool calls; the directory
alone is not an OS-level read-isolation boundary. Exact response coverage is required, and the day-1 matcher is
reused. Extra extracted facts and nonempty fields ignored by that matcher are separately flagged for review.

### Recoverability gate (passed)

Both extractors recovered every sampled fact, so the ≥ 90 % per-language gate passed.

| extractor | Turkish | English | mixed | all |
|---|---|---|---|---|
| GPT-6 Astra (xhigh, `rewrite_archive_recovery.py`) | 100/100 | 100/100 | 100/100 | 300/300 |
| Claude Sonnet subagents (`rewrite_archive_recovery_claude.py`) | 100/100 | 100/100 | 100/100 | 300/300 |

* The Claude run is the cross-family check, because GPT wrote most of the text.
* GPT recovered all 25 Gemini-written and all 275 GPT-written sampled facts.
* GPT also extracted four secondary facts. All four come from the same pattern: "the previous lead moved to another
  project" (also present in the template), read as leaving the team. That ambiguity does not touch any gold answer.
  The only count-team question whose project had a lead change still counted as a member has no such sentence
  (w2-q022).

### Retrieval, agents and answers on the rewritten archive

Everything was rerun with `AGENT_SURFACE=rw` on the same 175 questions and gold ids:
* the index and the single-shot baselines;
* the app retriever;
* the GPT research agent, one fresh codex context per question (verified that the context reads the rewritten
  archive);
* the untrained Qwen3.5-2B (v2 harness);
* ChatGPT answering from each pack.

The GPT agent's logs contain only environment commands.

Evidence cells are recall / complete. Reads are the messages shown to the agent per question, with characters read
in brackets. Answers come from ChatGPT reading the pack.

| class | method | template evidence | rewritten evidence | template answer | rewritten answer | template reads | rewritten reads |
|---|---|---:|---:|---:|---:|---:|---:|
| two-hop | (a) hybrid + rerank | 0.53 / 0.10 | 0.53 / 0.06 | 0.10 | 0.06 | 8 | 8 |
| two-hop | (a) at equal reads | 0.60 | 0.55 | | | | |
| two-hop | GPT agent, fresh context | 1.00 / 1.00 | **1.00 / 1.00** | 1.00 | **1.00** | 35.6 (1,987 ch) | 32.3 (2,019 ch) |
| two-hop | Qwen3.5-2B untrained | 0.21 / 0.00 | 0.25 / 0.00 | 0.00 | 0.00 | 10.7 | 10.6 |
| aggregate | (a) hybrid + rerank | 0.79 / 0.46 | 0.81 / 0.52 | 0.50 | 0.62 | 8 | 8 |
| aggregate | (a) at equal reads | 0.89 | 0.91 | | | | |
| aggregate | GPT agent, fresh context | 0.89 / 0.66 | 0.95 / 0.74 | 0.78 | 0.84 | 37.9 (2,260 ch) | 39.2 (2,606 ch) |
| aggregate | Qwen3.5-2B untrained | 0.12 / 0.00 | 0.20 / 0.06 | 0.04 | 0.10 | | |

Other rewritten-surface rows:
* (b) neighbours: two-hop 0.49 / 0.02, answer 0.02.
* App retriever + rerank: two-hop 0.53 / 0.06, answer 0.06.
* Gold pack: 1.00 in every class. No pack: 0.00 in every class.
* Latest value: about 1.0 for every method except Qwen (0.54).

What this shows:
* **The two-hop gap survives the rewrite.**
  * The agent again has complete evidence on 50/50 questions, and ChatGPT answers all 50.
  * Single-shot retrieval answers 3 of 50 (+0.94 [0.86, 1.00]).
  * At equal reads, (a) reaches 0.55 recall.
  * The agent read about the same amount on both surfaces (32–36 messages, ~2,000 characters).
* **Aggregate:** the agent leads at budget 8 (+0.14 recall, +0.22 answers [0.08, 0.36]). At equal reads (a) is
  within 4 points (0.91 vs 0.95). As on template text, most of the gain is reading more and choosing a compact pack.
  Part of both methods' rise on this surface is an artifact of explicit dates (see the limits below).
* **One-hop controls got harder** (for (a): recall 1.00 → 0.92, answers 0.96 → 0.80). The agent stays at 0.96.
  * Recall: the two retrieval misses are lexical. The rewrite mostly dropped the verb "çalışıyor" that the
    questions use (146 of 326 template employer turns, 13 rewritten).
  * Answers: in 3 of the 5 answer misses the gold message was in the pack. The answer model read a more recent
    team join as the employer (for example, it answered a project name) or answered "unknown".
  * So on this surface, answer accuracy reflects some answer-model reading errors as well as pack quality.
* **The untrained small model stays far below:** two-hop answers 0/50, and its shown messages hold 44 % of two-hop
  gold.

### Limits that still apply (several found by an independent audit of this run)

* **Dates became more explicit than in the template.** The rewrite prompt recommended dates with the year.
  * Of the 300 event messages, 284 now carry day, month and year. On template text, 155 were relative ("dün",
    "today") and none had a year.
  * As a result, `count_meetings_year` (the question names the year) reaches 1.00 recall for both (a) and the agent,
    against 0.89 and 0.92 on template text.
  * The aggregate improvements on this surface are partly this artifact. Two-hop hop 2 (the bridge person's city or
    employer) is unaffected.
* **Only 35 % of user turns were rewritten** (1,752 of 5,003). All noise turns and assistant replies are still
  template text.
  * About a third of fact turns are multi-sentence, against no noise turns.
  * A few record-keeping phrases ("aklında tut", "kaydet") appear only in fact turns.
  * The two-hop result does not depend on this, because noise turns name nobody. It does mean fact turns are
    stylistically marked.
* **Names are preserved verbatim.** No surname was dropped or added, and no new name appears. 78 of 80 lead-change
  messages still contain a "lead / yönet / başına" keyword. Hop 1 is still solved by searching the project name.
  This surface tests robustness to paraphrase, not realistic mention (pronouns, nicknames, facts split across
  turns).

* **Same family.** GPT wrote 1,575 of 1,752 rewritten turns and is also the agent and the answer model. The Claude
  extractor's 300/300 and the day-3 finding are cross-family evidence that the text carries the facts: Claude-built
  packs answered as well as GPT-built ones on template text. Neither rules out a stylistic advantage for a GPT agent
  on GPT-written text. A Claude agent on this surface would test that.
* **Rewritten is not real.** The rewrites are lexically far from the template (mean token Jaccard 0.31 vs 0.61 for
  the day-1 paraphrases). They still repeat replacement phrases and keep one fact per message, a single message per
  fact version and full names where the template had them. Real chat spreads facts across turns and uses pronouns.
* World-level limits listed under "Known limits" are unchanged, because worlds and questions are identical by
  design.
* **Run order.** The baselines and the agent run started after the Claude extractor passed the gate, but before
  the GPT extractor's score was written. Both passed, so the results are unaffected.

A harder surface would rewrite noise turns too, keep the template's relative dates, and spread facts across turns
with pronouns and nicknames.

Reproduce (servers from `retrieval.py serve` running):

```bash
cd benchmarks/agent
export AGENT_SURFACE=rw
/opt/homebrew/bin/python3 -I rewrite_archive_finalize.py --check-only
/opt/homebrew/bin/python3 -I rewrite_archive_recovery.py extract && /opt/homebrew/bin/python3 -I rewrite_archive_recovery.py score
/opt/homebrew/bin/python3 -I rewrite_archive_recovery_claude.py
/opt/homebrew/bin/python3 -I retrieval.py index && /opt/homebrew/bin/python3 -I baselines.py && /opt/homebrew/bin/python3 -I app_retriever.py
/opt/homebrew/bin/python3 -I run_codex.py && /opt/homebrew/bin/python3 -I small_agent.py --run qwen35_2b_prompted_v2
/opt/homebrew/bin/python3 -I score.py
/opt/homebrew/bin/python3 -I answer.py build && /opt/homebrew/bin/python3 -I answer.py run && /opt/homebrew/bin/python3 -I answer.py score
```

## Realistic chat surface (`realistic.py`, `realistic_prompt.md`)

The template and rewritten surfaces keep one fact per message with the person's name in it. Real chat does not.
This surface rewrites the whole archive as written chat sessions around the same worlds and the same 175 questions.

* **Plan (programmatic, `realistic.py plan`).**
  * 1,543 sessions: 988 carry 1–3 facts, 555 are topic chats (code, cooking, money, writing...). 32 % of topic
    chats mention a person or project without stating anything about them.
  * 522 of the 1,359 facts are *split*: the person is named in one user message, and the fact comes later through a
    pronoun or Turkish pro-drop ("başak tarım'da yeni bir işe başlamış").
  * Events within a week use relative dates (today, yesterday, a weekday); older ones use day and month, as in the
    template.
  * Each world has a fixed user persona (style only).
* **Writing.** Claude Sonnet subagents wrote every session by hand from the plan, both user and assistant turns,
  and annotated each user turn with the facts it states (`conveys`) or whose person it introduces (`names`).
  Claude is a different family from the GPT agent, the GPT answer model and the GPT checker.
* **Gold.** Each question's gold is the union of its facts' `conveys` and `names` turns. Two-hop gold now spans
  2–4 messages. Worlds, questions and answers are unchanged.
* **Checks.**
  * `realistic.py build` validates every session: the required names, the project, split order, no unknown
    annotations. All 1,543 pass.
  * A GPT extractor (codex, empty sandbox) read each whole session and recovered 1,358 of 1,359 facts (99.9 %; all
    522 split facts). Its evidence turns covered the writer's annotations in 99.9 % of cases, and it found no fact
    in any of the 555 topic sessions.
  * The one miss is a workshop written without its city; no question uses it.
* **Size.** 9,874 messages (about 2,000 per world). Median user message 108 characters, assistant 195.

### Results across the three surfaces

Evidence recall (a pack budget of 8; recall / complete):

| class | method | template | rewritten | realistic |
|---|---|---|---|---|
| latest value | (a) hybrid + rerank | 0.98 / 0.98 | 1.00 / 1.00 | 0.75 / 0.74 |
| latest value | GPT agent, fresh context | 1.00 / 1.00 | 1.00 / 1.00 | 0.92 / 0.92 |
| two-hop | (a) hybrid + rerank | 0.53 / 0.10 | 0.53 / 0.06 | 0.46 / 0.14 |
| two-hop | (a) at the agent's reads | 0.60 | 0.55 | 0.50 |
| two-hop | GPT agent, fresh context | 1.00 / 1.00 | 1.00 / 1.00 | **0.84 / 0.74** |
| aggregate | (a) hybrid + rerank | 0.79 / 0.46 | 0.81 / 0.52 | 0.54 / 0.14 |
| aggregate | GPT agent, fresh context | 0.89 / 0.66 | 0.95 / 0.74 | 0.71 / 0.34 |
| one-hop | (a) hybrid + rerank | 1.00 | 0.92 | 0.74 / 0.68 |
| one-hop | (a) at the agent's reads | 1.00 | 1.00 | 0.92 |
| one-hop | GPT agent, fresh context | 1.00 | 0.96 | 0.72 / 0.72 |

Answer accuracy (ChatGPT reads the pack):

| method | template | rewritten | realistic (latest / two-hop / aggregate / one-hop) |
|---|---|---|---|
| no pack | 0 | 0 | 0.00 / 0.00 / 0.00 / 0.00 |
| gold messages | 1.00 | 1.00 | 1.00 / 1.00 / 1.00 / 1.00 |
| (a) hybrid + rerank | 0.98 / 0.10 / 0.50 / 0.96 | 0.98 / 0.06 / 0.62 / 0.80 | 0.68 / 0.14 / 0.28 / 0.20 |
| (b) + neighbours | 0.94 / 0.00 / 0.36 / 0.92 | 0.96 / 0.02 / 0.54 / 0.76 | 0.72 / 0.06 / 0.18 / **0.60** |
| app retriever + rerank | 0.98 / 0.12 / 0.50 / 0.88 | 0.96 / 0.06 / 0.68 / 0.80 | 0.70 / 0.12 / 0.30 / 0.36 |
| GPT agent, fresh context | 1.00 / 1.00 / 0.78 / 0.96 | 1.00 / 1.00 / 0.84 / 0.96 | **0.92 / 0.74 / 0.52 / 0.64** |
| Qwen3.5-2B untrained (v2) | 0.48 / 0.00 / 0.04 / 0.60 | 0.54 / 0.00 / 0.10 / 0.72 | 0.44 / 0.00 / 0.00 / 0.40 |

What changes on realistic chat:
* **Single-shot retrieval breaks on simple questions too.** Answers from (a)'s packs fall to 0.68 on latest value
  and 0.20 on one-hop, against 0.98 / 0.96 on template text.
  * The pack often holds the right messages but cut out of their sessions. In 12 of the 20 one-hop questions
    answered wrongly, every gold message was in the pack.
  * Orphaned pronoun turns about other people ("antalya'da yaşıyor", "I heard she has moved to Bursa") sit next to
    them, and the answer model attributes them to the person asked about.
  * Neighbour expansion, useless on template text, brings back the naming turn and lifts one-hop answers to 0.60.
* **On two-hop questions the research agent keeps a large lead, and it is no longer at ceiling.** Its packs gain
  +0.60 [0.46, 0.72] in answers over (a) (95 % bootstrap interval). Its two-hop evidence is 0.84, against 0.50 for
  (a) at the same number of reads.
  * A stronger single-shot baseline does not close this gap. Expanding each of (a)'s top-8 hits to its whole
    session (audit check, computed from stored rankings) gives 0.18 complete two-hop evidence at 29 messages,
    against the agent's 0.74 at 2.7.
* **Do not read the latest-value and one-hop gaps as research gains.** On those classes the agent's answer leads
  (+0.24 latest value, +0.44 one-hop) are mostly the price of (a)'s context-free packs.
  * Session-context packs built from (a)'s own ranking reach 0.68 complete one-hop evidence with 1 hit (3.8
    messages) and 0.70 latest value with 2 hits. Their answer accuracy has not been run.
  * Single-shot retrieval also indexes only user turns. On this surface, 65 % of the fact turns without a name are
    restated by the assistant with the name ("Selam Duygu, Başak Tarım'daki yeni işini duydum"). The reason to leave
    assistant turns out (the template acknowledgements) does not apply to written replies.
  * A session-context baseline and an assistant-indexed baseline are the next fair comparison for these classes.
* **Aggregate:** +0.24 [0.06, 0.40] in answers. Session packs from (a) reach 0.24 complete evidence, against the
  agent's 0.34.
* **The read budget binds.** The agent used all 8 search/expand calls on 134 of 175 questions, against 88 on
  template text. It read about 5,700 characters per question, against 1,900.
* **Where the agent loses evidence: split facts.** Across the 57 questions where its pack missed gold, 73 fact
  turns and 49 naming turns were never shown; 14 and 13 were shown but not selected.
  * In 12 of the 13 incomplete two-hop questions, the missing piece is a split pair. Example: "Zeynep Kurt için…"
    followed by "Antalya'ya yeni taşındı".
  * The pro-drop fact turn has no name, so no name query reaches it.
  * The naming turn is a low-content request ("ona ne yazsam"). For the person's name, the reranker ranks it below
    that person's other, fact-rich turns.
  * Searches for the bridge person return mostly their other facts (45 % of hits) or other people's facts (22 %).
    Name-only turns and bare mentions are 13 %.
  * One-hop shows the cost: the agent's evidence (0.72) is below (a) reading as many messages (0.92).
  * What a trained controller would need: query on the attribute ("taşındı", "çalışıyor"), not only the name, and
    expand naming turns to reach the fact that follows.
* **The untrained small model stays far below** on every class (two-hop and aggregate answers 0.00).

Limits:
* Facts are still stated by the user in a single session, and every split resolves within that session.
* The writer followed a plan that guarantees each fact is stated once, unambiguously. Real archives contradict
  themselves, repeat stale values and leave things unresolved.
* The GPT agent and answer model are not the writer's family, but GPT also checked recoverability.
* **Scoring note.** Writers omit the year when a deadline falls in the chat's year, as the plan allows, and the
  answer model then answers "17 December". Date answers now count when day and month match and no other year is
  named. This flipped 13 realistic-surface answers to correct (4 of them gold-pack answers) and none on the template
  or rewritten surfaces. All tables use the new rule.
* `w4-q027` gold includes one naming turn for a co-attendee who is not asked about. The effect on scores is nil.

## Run

```bash
cd benchmarks/agent
/opt/homebrew/bin/python3 -I make_worlds.py        # work/worlds/w1..w5
/opt/homebrew/bin/python3 -I rewrite.py select     # work/rewrite/batches
/opt/homebrew/bin/python3 -I rewrite.py extract --surface template
/opt/homebrew/bin/python3 -I rewrite.py extract --surface rendered
/opt/homebrew/bin/python3 -I rewrite.py score
/opt/homebrew/bin/python3 -I retrieval.py serve &  # embedding + rerank servers
/opt/homebrew/bin/python3 -I retrieval.py index
/opt/homebrew/bin/python3 -I baselines.py
/opt/homebrew/bin/python3 -I app_retriever.py      # build ../memory/Bench first
/opt/homebrew/bin/python3 -I run_codex.py          # one question per context
/opt/homebrew/bin/python3 -I small_agent.py --run qwen35_2b_prompted_v2
/opt/homebrew/bin/python3 -I score.py
/opt/homebrew/bin/python3 -I answer.py build
/opt/homebrew/bin/python3 -I answer.py run
/opt/homebrew/bin/python3 -I answer.py score
```

Everything under `work/` is generated and git-ignored.
