# Memory-write verifier: week-1 specification

Status: draft for the owner's review (days 1-3 of the plan). Nothing in the shipped app changes in this phase.

## 1. Problem

Turing AI's automatic memory formation asks a chat model to extract durable facts and events from **one user message**
and validates the answer deterministically (`AutomaticMemoryExtractor.parseAndValidate`,
`Packages/MosaicCore/Sources/MosaicCore/Persistence/AutomaticMemoryExtraction.swift`). The validator checks shape,
schema version, operation count, field validity, scope rules, evidence IDs (must be the supplied user message),
target-topic consistency, confidence floors, secrets and duplicate keys. It does **not** check that the message supports
the proposed memory's content. The prompt forbids inferring ownership from an encounter, a fact from a plan, and so on,
but nothing enforces it. A wrong memory persists and is reused in later answers across every provider the user switches to.

The verifier is a second, small, on-device check at write time: *does this user message support this proposed memory?*

## 2. Task definition (v1)

**Input** (exactly what the app has at write time, `AutomaticMemoryStore.prepare`, lines 171-210):

* `message`: one user message: `id`, `role=user`, `content`, `createdAt`.
* `existing_topics`: the visible topic snapshots sent to the extractor (active, enabled, global or this conversation's scope;
  id, canonical key, kind, title, content, confidence, importance, stability, status, origin, last_confirmed_at). They are
  **context only** (what is being updated), never evidence. An old, wrong record must not be able to validate itself.
* `proposal`: one atomic `upsert` operation from the validated envelope: `kind`, `title`, `content`, `target_id` (optional),
  `canonical_key`, `confidence`, `stability`.

**What must be supported.** The proposal's `content` (the atomic user-stated fact or event), including its implicit
claims: *who* it is about (the user vs another person), *polarity* (negated or not), *modality* (fact vs plan/intention/
hypothetical), *time scope* (current vs past vs future), and *relation* (ownership vs encounter). `title`, `kind`,
`confidence` and `importance` are not judged; a title that says more than the content is a content problem only if the
content says it. For an update (`target_id` set or canonical key matches an existing topic) the **new** content is judged
against the message alone; the existing topic may explain *what changed* but contributes no support.

**Output labels:** `supports` / `contradicts` / `insufficient`.

* `supports`: the message states or directly implies the content (paraphrase, translation, compression allowed).
* `contradicts`: the message explicitly asserts the opposite (negation, quitting, correction, a different current value).
* `insufficient`: neither; the content adds, generalises or assumes something the message does not say. Kittens found on
  the street -> "user owns two cats" is `insufficient`, not `contradicts`.

The verifier judges consistency with what the user said, not real-world truth.

Two patterns seen in the pilot need an explicit rule (owner to confirm; the labeling guide applies them as written):

* **Carry-over in updates.** An update often restates the existing content and adds a clause. Only the new or changed
  claims are judged against the message; the restated part is inherited (it was validated when first written) but may
  not justify the new claims and must not be contradicted by the message. Tag `carryover`. An update whose content is
  the old memory restated with nothing from the message is `insufficient`.
* **Pronouns resolved from memory.** With a single message, "she's a lawyer" can only become "the user's sister is a
  lawyer" by reading the existing topics as evidence. v1 labels this `insufficient` (tags `person`, `pronoun`) so the rate
  is measured; whether the product should allow it (for example by passing the previous user message) is a separate
  decision.

**Error-type tags** (`person`, `relationship`, `negation`, `plan_vs_fact`, `time_scope`, `ownership`, `carryover`,
`pronoun`, `other`) are
multi-label analysis tags on the dataset. They are not model outputs in v1.

**Out of scope for v1:** `forget` operations (a request to forget is not a factual claim; it stays with the existing
validator rules at AutomaticMemoryExtraction.swift lines 95-99), multi-message evidence (the app sends one message),
project scope (not exercised by the pilot), real-world fact checking.

## 3. Decision and failure policy (for the week-3 integration; documented now)

Per upsert operation, after `parseAndValidate` and before `apply`:

| verifier outcome | effect on the operation | job status |
|---|---|---|
| supported (score >= accept threshold) | written by `apply` as today | complete |
| unsupported (score <= reject threshold, or escalation says unsupported) | **dropped**; a *completed* verdict, no automatic retry, recorded in the formation audit with the verdict | complete (with dropped operations) |
| uncertain (between thresholds) | escalate once to the strong verifier (a chat model through the user's provider); its verdict is final | complete |
| could not evaluate (timeout, model missing, provider error) | **not written** (no fail-open) and **not a rejection**: recorded as `could not evaluate`; the proposal is discarded for this job. A pending-operation queue is out of scope for v1 | complete with "unverified operations discarded" |

Rules: the verifier never adds or edits operations; `forget` operations bypass it; `apply`'s final source and state
checks (`AutomaticMemoryStore.apply`, lines 213-260 and 311-317: fingerprint, provider identity, audience,
`matchesCurrentState` against the sent snapshot) stay in place because the source message or the target topic can change
while verification runs. The escalation call gets its own call id and usage record (`"Memory verification"` usage
category, next to `"Memory formation"` in `UsageReport.swift`), separate from the extractor's single-paid-call accounting,
with provider, model, tokens, latency and outcome. Thresholds are read from configuration so calibration can change them
without a code change.

Integration point: `AutomaticMemoryFormationCoordinator.formMemory` (AutomaticMemoryStore.swift lines 1526-1597), between
`generate` (which ends in `parseAndValidate`, AutomaticMemoryExtraction.swift line 538) and `apply` (line 1578). The
verifier receives `preparation.messages[0]`, `preparation.existingTopics` and `generated.envelope.operations` and returns
a filtered envelope plus per-operation verdicts for the audit.

## 4. Data

### 4.1 Pilot pack (built in this phase)

* `data/conversations.jsonl`: ~100 short conversations (TR / EN / code-switched 40 / 35 / 25), 8-14 user turns each,
  written by **Gemma 4 31B (DeepInfra)**, a family different from both extractors and from any later judge. Scenario
  phenomena per conversation (relationships, place/time, plan vs fact, negation, correction, encounter vs ownership,
  resolution, forget request, noise, credential-like text, ambiguous pronoun, conditional) are sampled with a fixed seed;
  `data/generation_log.md` records model, prompt hash and cost.
* `data/extractions.<family>.jsonl`: the app's extraction prompt (`mosaic-automatic-memory-extraction-v5`) run **message by
  message with memory state carried forward**, through two cheap families: **GPT-6 Luna (OpenAI)** and **Qwen3.8 Flash
  (DeepInfra)**. The request is built by the real Swift code (`Validate/`, calling `AutomaticMemoryExtractor.request`),
  the answer is validated by the real `parseAndValidate`, one attempt per message.
* `data/proposals.jsonl`: every retained `upsert` operation, with the message, the existing topic (if any), the change
  kind (created / updated / reinforced) and whether the apply mirror accepted it. **The labeling population is the
  proposals that passed the real validator and whose apply mirror succeeded**, i.e. memories the app would store.

**State mirror.** `extract.py` reproduces `AutomaticMemoryStore.apply` in Python: canonical key normalisation and
scope/kind prefixing (`canonicalKey`, lines 1369-1421), topic resolution by target id or by canonical key (lines
954-999), the stale-snapshot check (lines 311-317), event ordering (line 339), create / update / reinforce / forget
transitions with the confidence, importance and stability merge rules (lines 343-487), and the visible-topic query
(lines 1023-1058: active, enabled, global or this conversation, newest first, at most 128). Deviations: evidence counting
assumes one evidence record per operation; `now` is the message time plus 30 s; no project scope; no SwiftData. Any
mismatch would change *which topics the next message sees*, not the validator's verdict.

### 4.2 Human labels

* `work/labeling/packet_core.csv` (300 rows, both annotators, blind: no family, no conversation id) and
  `packet_rest_A/B.csv` (the remainder split between the two). `LABELING_GUIDE.md` is the instruction set.
* Report Cohen's kappa on the core rows **and** list the disagreements with both labels; adjudicate disagreements by a
  short discussion and record the decision; rows that stay contested are tagged `contested` and excluded from the test set.
* Natural (unperturbed) model errors are reported separately from rule-based perturbations, with the number of
  **distinct conversations** each error type appears in, not only counts.
* The LLM pre-annotation (`work/preannotation/`) exists only to size the effort; it is hidden from annotators and never
  merged into labels.

### 4.3 Training data (plan for week 1-2; not built yet)

1. **Natural pool.** All stored proposals from the pilot pack, human-labelled where they are in the test split, and
   LLM-labelled by a *third* family (DeepSeek V4.1 Flash) **plus** a second judge where they are in the train split; a train
   row keeps its label only when the two judges agree, otherwise it is dropped (not relabelled by a human; human time goes
   to the test split).
2. **Perturbation pool.** Rule-based, label-preserving edits applied to *supported* natural proposals, each producing an
   `insufficient` or `contradicts` row with a known tag: person swap (user <-> relative), negation flip, plan -> fact
   ("düşünüyorum/thinking of" -> "taşındım/moved"), time-scope shift (past -> current), encounter -> ownership, relation
   swap (abi/kuzen, sister/friend), bundled claim (append an unsupported clause). Templates are written for TR and EN
   separately; a code-switched row is perturbed in whichever language the clause is in.
3. **Splits are by source conversation.** All extractor outputs, translations and perturbations of one conversation sit in
   the same split. Target: train 60 / calibration 15 / test 25 conversations, test being the human-labelled 300-500
   pairs. **Held-out phrasing templates:** two perturbation templates per error type are reserved for test only, so a
   model cannot pass by memorising the edit patterns.
4. **Final audit with a new extractor family.** After model selection, the pipeline runs on the test conversations with a
   third extractor (e.g. Gemini Flash or Mistral Small), its stored proposals are human-labelled (100-150 rows), and the
   chosen thresholds are applied unchanged. This tests robustness to a new memory extractor, which is the realistic
   deployment shift (the user picks any provider), rather than to a new conversation author.
5. **Sizing.** Expect ~1,200-1,500 stored proposals from the pilot pack across two families, plus ~2-3 perturbations per
   supported natural row, giving ~3,000-5,000 training pairs. If natural errors are rare, the perturbation pool carries the
   negative class in training, and the test set reports the two pools separately so that a model good only at synthetic
   edits cannot hide.

## 5. Model comparison protocol

Three systems on the same human-labelled test set, same decision rule (accept if P(supports) >= tau, where tau is chosen
on the calibration split to keep >= 95% of supported memories):

1. **Off-the-shelf + threshold.** A multilingual NLI cross-encoder as downloaded (premise = message, hypothesis = proposal
   content), zero training; only tau is chosen on the calibration split. Candidates measured in the smoke test:
   `MoritzLaurer/multilingual-MiniLMv2-L6-mnli-xnli` and `MoritzLaurer/mDeBERTa-v3-base-mnli-xnli` (licence and sizes as
   recorded in `work/smoke/*.json` from the downloaded cards).
2. **Adapted same model.** The same checkpoint fine-tuned (full or LoRA; LoRA is not the point) on the training pool with
   the proposal rendered as a hypothesis in the message's language plus the existing-topic context as a prefix. Report
   loss curves, early stopping on calibration, and the natural-vs-perturbation breakdown.
3. **Strong-LLM verifier.** A chat model with the labeling guide as its prompt, through the user's provider; the competing
   system that escalation falls back to, not ground truth.

Gains from training are separable from threshold selection because (1) and (2) share the model and the threshold rule.

**Pre-registered target** (an engineering choice, not a guarantee): keep >= 95% of supported memories on the calibration
split; report everything else at that operating point.

## 6. Metrics (reported per pool: natural, perturbed; per language; per change kind)

| metric | definition |
|---|---|
| unsupported-accept rate | share of `insufficient` + `contradicts` proposals that are written |
| supported-accept rate | share of `supports` proposals that are written (target >= 95%) |
| unsupported share among accepted | precision of what reaches the store |
| escalation rate | share of proposals sent to the strong verifier |
| total cost | small-model cost (zero marginal on device) + escalated calls, per 1,000 proposals, including failed calls |
| device latency / RAM | p50 / p95 per proposal on the Mac (iPhone untested in this phase), peak RSS, model size |
| downstream correctness | two stores built from the same conversations (current system vs with verifier), the same
  later questions, the same answer-generation conditions, two providers: correct-answer rate and appropriate abstention |
| could-not-evaluate rate | share of proposals discarded for technical reasons |

## 7. On-device smoke test (this phase, Mac only)

`smoke/smoke_nli.py` downloads each candidate into its own directory, runs PyTorch as reference on
`smoke/pairs.jsonl` (54 TR / EN / mixed premise-hypothesis pairs written for this project), exports to ONNX Runtime and
Core ML, and compares decisions (label agreement, max logit difference), p50 / p95 latency, RSS, and 8-bit
quantisation. Results are in `work/smoke/` and summarised in `README.md`. iPhone feasibility is untested until the owner
runs the converted model on the device; the app has no local inference runtime today (`docs/ON_DEVICE_EMBEDDINGS.md`),
so integration means adding Core ML (first-party) or ONNX Runtime (third-party, iOS support not verified here).

## 8. Open decisions for the owner

1. Mac-only vs iPhone deployment target for the thesis demo.
2. Could-not-evaluate handling: discard silently with an audit entry (this spec) vs surface a one-line notice in the chat.
3. Whether the strong verifier may be a *different* provider than the chat provider (cost and privacy implications).
4. Second annotator (who, and how many rows beyond the 300 core).
5. Third extractor family for the final audit.
