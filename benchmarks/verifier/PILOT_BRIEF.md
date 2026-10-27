# Pilot brief: should we build a "memory-write verifier"? (for an independent second opinion)

Please read this as a sceptical reviewer. I want your honest judgement, not encouragement. If the pilot says the project is not worth building, say so.

## 1. Context

- **Who:** an economics graduate applying to the EPITA "AI Systems" master's. They need one technically convincing project, built on their own working app, that shows data → model → deployment → measurement. Time: about 4 weeks. Budget: small (tens of dollars of API credit, a laptop, Colab-scale GPU).
- **The app (Turing AI):** a bring-your-own-key chat client (SwiftUI iOS/macOS, Android port) with a local, portable memory that works across ~50 model providers. After each chat turn an **extractor** (a chat model the user chose, prompted by the app) proposes memory operations ("create/update topic X with content Y") from **exactly one user message plus the existing memory topics**. A deterministic validator checks JSON shape, evidence IDs, scope, confidence, secrets, etc. **Nothing checks that the proposed memory text is actually supported by the user's message.** A wrong stored memory is reused in later answers for months.
- **Earlier work (done, not the question here):** a retrieval benchmark and report (bilingual Turkish/English personal-memory retrieval; embedding models, rerankers, LLM judges), plus product fixes.

## 2. The idea under test

Train/adapt a small multilingual verifier (NLI-style, LoRA, runs on the Mac app, escalates to a strong model only when uncertain) that, given **one user message + existing topics + a proposed atomic memory**, outputs `supports / contradicts / insufficient`, and block unsupported writes. Evaluate end-to-end on later answers across several chat providers.

Labels: `supports` = the message states or directly implies the memory (paraphrase fine); `insufficient` = the memory adds or assumes something (plan stored as fact, another person's attribute stored as the user's, encounter stored as ownership, time scope lost, relation inferred from an earlier memory); `contradicts` = the message says the opposite. Existing memory is context only (an old wrong memory cannot justify a new one). Consistency with what the user said, not real-world truth.

## 3. The pilot (what was run)

- **Data (all text is by chat models, fictional people; no human labels yet):** 90 conversations, 1,201 user messages, Turkish/English/code-switched, written by ChatGPT (40), Claude (40) and Gemini (10, long dense messages, reported as a separate slice) with one shared prompt asking for realistic, indirect, messy chat plus planted situations (other people's facts, plans vs facts, negations, corrections, time scope, "forget this"). Plus **240 real user messages** from the owner's own ChatGPT/Claude history (masked, 31 sessions; mostly tasks and code).
- **Extraction:** the app's own extraction prompt, run message by message with memory state carried forward, through two cheap families (GPT-6 Luna and Qwen3.8 Flash), and the app's real Swift validator. One attempt per message.
- **Quick measurement (NOT ground truth):** a third family (DeepSeek V4.1 Flash) judged every stored proposal with the labels above. It is strict and sometimes pedantic; I estimate roughly half of its flags are real.

## 4. Results

| Quantity | Value |
|---|---|
| Messages processed | 1,201 synthetic × 2 extractors, 240 real × 2 |
| Validator rejections | ~0 (the validator is not the weak point) |
| Stored proposals | 1,896 synthetic (0.8 per message), 79 real (0.16 per message) |
| Flagged by the quick judge, synthetic | 89 / 1,763 = **5.0%** (insufficient 84, contradicts 5) |
| By extractor | GPT-6 Luna **2.0%**, Qwen3.8 Flash **8.1%** |
| By family | Claude 5.5%, ChatGPT 5.3%, Gemini-dense 3.1% |
| By change kind | created 3.2%, updated **7.7%**, reinforced 77% (n = 13 only) |
| Flagged, real messages | **1 / 79** (≈1%) |
| Conversations with at least one flag | 53 / 90 |
| Flag tags | time_scope 36, other 36, relationship 26, person 18, ownership 15, plan_vs_fact 11, negation 9 |

Real examples of what looks like a true error (synthetic data): a memory "User's daughter is named Mina" from a message that only mentions "mina" (the relation came from an earlier memory); "brother's visit cancelled due to a migraine" from "brother was going to visit but has another migraine"; "user's parents live in Adana" from "annemler Adana'da, babam 78 oldu" (arguably fine; the judge is pedantic). Typical pedantic false alarms: judging "annemler" (my mother and family) as not covering the father.

Observations about the extractor: it often writes memories as attributions ("said that…", "belirtti"), which avoids many errors; it stores **events** in ~50% of proposals; when updating, it re-states and extends the old memory, which is where unsupported details leak in.

## 5. Limits I already know

1. No human labels yet; the 5% is an upper-bound-ish estimate from one LLM judge. Human labelling of ~300 rows (two annotators, blind) is the real measurement.
2. All synthetic data are LLM-written, one family (Claude) also wrote earlier benchmark data; the planted-trap claims by the generators are unreliable (off-by-one, often mislabelled), so I do not use them.
3. The real messages contain almost none of the target phenomena (relationships, plans, negations); they test over-extraction from task context, and there it is almost clean.
4. The extractor sees one message per call; multi-message support would be an app change.
5. A verifier would add cost/latency and could reject correct memories; I would pre-register keeping ≥95% of supported memories.
6. The extractors are cheap models; users who pick strong models may see fewer errors.

## 6. Alternatives I considered (and mostly dropped)

Conformal/risk-controlled abstention for recall injection; a selective-escalation cascade (reranker → LLM judge); cross-model embedding alignment (Procrustes) to avoid re-embedding; distilling the LLM judge into a 0.6B cross-encoder; per-user adapter; privacy-aware routing of memories by provider trust; a provenance/revocation graph so corrected or forgotten facts cannot resurface through summaries, caches or restore; memory poisoning tests. Several were judged incremental, already published, or too weak statistically at this data size.

## 7. Questions

1. **Go / no-go.** Given 5% (upper-bound) flags overall, 2% for a strong cheap extractor, ~1% on real messages, is a trained verifier worth building for this application, or is the honest finding "the extractor is already good; errors are rare and concentrated in updates and weak models"?
2. If go: what is the **cheapest, most informative next experiment** (I plan: ~300 human-labelled rows stratified across slices with oversampling of flagged rows, two annotators, kappa, then a three-way comparison off-the-shelf NLI + threshold vs LoRA-adapted vs strong-LLM verifier)? What would make it fail?
3. If the effect is this small, which **single** alternative from section 6 (or something I missed) would give a more convincing, defensible "AI systems" project for this applicant in 4 weeks, and why?
4. Method critique: what is wrong or misleading in how the pilot was run or in how I read it (judge circularity, sampling, estimating rates from LLM flags, extractor choice, per-slice reporting)?
5. How should the result be framed honestly in an application if the finding is "rare but systematic errors in updates", and what claim would a reviewer find overreaching?

Answer in under 600 words, concrete, ranked.
