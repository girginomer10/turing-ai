# Internals

Design notes on the behaviors that are easy to get subtly wrong: provider transports, context budgeting, compaction, recall, automatic memory, backups, and the security boundary. [ARCHITECTURE.md](ARCHITECTURE.md) describes the module layout; this document describes the rules each module enforces.

## Provider transports

Provider identity and wire protocol are separate concerns. Most presets share one hardened OpenAI-compatible chat/embedding transport. OpenAI Responses, Anthropic Messages, Gemini, native Qwen/Cohere embeddings, and provider-specific catalog shapes are dedicated adapters.

- Anthropic, Gemini, Cohere, and Fireworks catalogs follow their documented pagination tokens. xAI uses its language-model catalog. Mistral, Together, Fireworks, Chutes, Hugging Face, OpenRouter, Vercel, Tencent, Baidu, Poe, and LM Studio listings are filtered to positively identified text-chat models.
- Untyped custom and local OpenAI-compatible listings stay manual rather than assuming every returned ID can chat. A missing or mixed catalog endpoint is shown as such, never as a failed connection; the exact model ID can always be entered by hand.
- Catalog pages, identifiers, cursors, totals, and pagination depth are bounded before they reach UI state.
- MiniMax's cumulative streaming snapshots are converted to true deltas before any UI, task, or compaction consumer sees them.
- Provider-reported length, safety, refusal, or unsupported-tool stops are surfaced as incomplete responses instead of successful answers.
- The Tinfoil preset uses its documented direct HTTPS compatibility endpoint. Tinfoil's SDK attestation and encrypted transport are not integrated, so the app makes no enclave-verification claim.

## Embedding profiles

Embedding profiles are optional. Each model keeps its own vector space; rankings are combined across profiles rather than comparing incompatible vectors directly. Remote profiles receive the current recall query and selected chat/document excerpts and may incur provider charges.

- Query and document requests keep provider-specific retrieval intent through native Qwen and Cohere adapters as well as Voyage, Jina, NVIDIA, and Gemini. NVIDIA GTE/GTR models omit the unsupported input-type field.
- Large jobs are split into provider-safe batches without reordering results or accepting a dimension change between batches.
- Local and custom connections without a verified default leave the embedding model ID for explicit input. LM Studio can supply IDs through its typed native catalog; only Ollama receives the curated local Qwen default.

## Document import and OCR

PDF, Markdown, and plain-text imports produce page-aware chunks. For PDFs, a useful embedded text layer is kept and Apple Vision OCR runs only on blank or weak-text pages. OCR stays on the device, preserves page and per-chunk OCR provenance, and records how many pages used OCR. OCR is capped at 200 pages per import: blank pages keep priority, and extra short pages retain their embedded text with that fallback disclosed instead of rejecting the whole document.

## Gemini Live transcription

Dictation uses the dedicated `gemini-3.5-transcribe-live` WebSocket with an enabled Google Gemini key, independent of the chat model that receives the message.

- Setup completes before the microphone opens. Input is converted to bounded 16 kHz mono PCM. Interim words are shown without being saved; only finalized text is committed to the local draft.
- Stopping allows a bounded final-result handshake. A later final transcript or turn completion confirms the drain; silence is not treated as data loss, and a warning appears only when an interim hypothesis remains unresolved.
- Leaving the conversation or backgrounding stops capture through the same path. The chat provider receives nothing until the user presses Send.
- A local guard begins finalization before Google's 10-minute continuous limit; provider GoAway notices are identified separately. Either path can be restarted without losing finalized draft text.

## Context budget and rolling compaction

Each provider/model configuration has editable context-window and maximum-output limits. Curated models with documentation-backed limits start from their metadata; unknown hosted IDs use a conservative 32,768/4,096 fallback, and unknown local-runtime or custom IDs use 8,192/2,048. Older records without saved limits resolve through the same policy.

The estimated input budget and its 512–2,048 token safety margin are read-only derived values: text is budgeted at one token per UTF-8 byte plus protocol framing, and the margin stays unused because providers tokenize differently.

At roughly 72% of the safe input budget, the currently selected provider/model can be used for one extra request that compresses the oldest contiguous completed turns toward a 55% target. The validated result is stored as portable JSON so a later turn can reuse it after switching providers.

- Raw messages are never replaced or deleted. The current message and the two newest completed turns stay verbatim, and newer raw corrections override the historical summary.
- After the final history plan is known, only the summarized or omitted older user messages are searched locally, and a small set of exact relevant excerpts can be attached within the same budget. This same-chat pass never duplicates verbatim-included messages and makes no extra provider or embedding request.
- Very large legacy chats compact at most one bounded source batch per send. If even the oldest single completed turn exceeds the model's safe summary-request budget, it stays local and recent raw history is used visibly; later sends do not silently bypass that limit.
- Invalid, partial, oversized, stale, or cross-chat summaries are never activated. If safe raw recent history still fits, it is used visibly. Retrying creates a new immutable answer attempt and reuses an unchanged valid summary without another compaction request.

## Bounded local reads

Large libraries stay responsive by keeping only 16 live transcript rows in the selected chat and loading older keyset pages on demand. Request history, same-chat recall candidates, normalized summary state, chat search, and curated-memory selection are prepared in small keyset batches on dedicated SwiftData actors instead of materializing unbounded model arrays on the UI actor.

| Limit | Value |
| --- | ---: |
| Aggregate recall payload per source lane | 8 MiB |
| Canonical history fail-closed ceiling | 20,000 rows or 16 MiB |
| Single message row | 512 KiB |
| Curated context scan | 4,096 records, 20 facts retained |
| Final escaped provider prompt | 64 KiB |
| Embedding work per profile batch | 32 chunks |

The Memory screen, its conversation picker, document chunk counts, document deletion, vector health, and document backfill use the same bounded actor pages. Embedding work is revalidated after every provider call.

## Request receipts

Every request records a context receipt listing raw-included, summary-covered, exact same-chat recalled, and still-omitted message IDs. On disk this is a bounded request event, the raw suffix selection, and references to immutable compaction artifacts; the UI reconstructs the full historical view from authoritative raw messages rather than storing an ever-growing copy of every prior ID with every answer.

The receipt distinguishes exact same-chat excerpts from earlier-chat/document recall, includes them in the final input estimate, and shows the readable summary, whether it was generated or reused, the exact summary provider/model/endpoint, reported usage when available, and failed or cancelled extra attempts.

## Automatic memory

After a completed reply, the same chat connection makes one small, strictly bounded extraction request. The model may propose only atomic user-stated memories. Deterministic local validation rechecks the exact source-message fingerprint, evidence IDs, project audience, target topic, confidence, field limits, and provider provenance before one atomic commit. Assistant text is never evidence.

- Repeated facts reinforce one topic. Explicit corrections replace the current value without erasing history. Explicit forget requests deactivate it.
- Paused, forgotten, or disabled topics are excluded from recall and from every later extraction payload.
- Learned topics join the same lexical and optional multi-embedding retrieval path as chats and documents.
- Project chats see global memory plus only that project's chats, documents, and project-scoped memory; unassigned chats never see project content. Moving a chat atomically moves an exclusively supported learned topic, while mixed-project evidence blocks the move rather than partially widening its audience. Audience partitions are selected before result caps, so a very large unrelated project cannot crowd the active project's memory out of recall.
- Conflict order: the current user message, then manually curated facts, then learned topics, then older raw excerpts.
- Learning is on by default without per-item approval and can be disabled globally. Every topic stays inspectable, editable, and traceable to its source.
- Provider failures never change an already successful reply. Interrupted work is recoverable; failed work requires a visible retry, so there is no uncontrolled spend loop. A durable activity receipt is committed before each extraction request and records reported tokens, failures, and cumulative retry totals; relaunch reconciliation marks an interrupted attempt failed without repeating a possibly billable call.

## Schema and backups

Main-store schema changes are explicit and additive through V4. V4 adds only project/binding and memory-formation-audit sidecar tables, preserving the V1–V3 model hashes. Legacy receipt and compaction blobs remain readable during the V2 rollback window; new writes use normalized records, and a bounded idempotent conversion API migrates legacy receipts without deleting an undecodable blob.

Portable `.mosaicbackup` files are versioned, deterministically ordered, size-bounded, and integrity checked before any live mutation. Export flushes pending rows through the normal validation gate, scans every source collection in four-record keyset pages, and applies its encoded byte/record budget before retaining each item.

Backups contain conversations, messages, projects and bindings, documents, provider and embedding configurations, learned-memory topics/evidence/revisions/jobs/audits, opaque legacy bytes, and normalized audit records. They never contain API keys, app-local preferences, or the rebuildable vector cache. Restored provider records receive new local identities and stay disabled until reviewed; restored automations are paused. Importing a file therefore cannot inherit an existing Keychain credential or issue a provider request.

Live replacement verifies one complete generation or commits the exact prior library back. If neither can be verified, a relaunch-persistent recovery lock blocks normal changes and exports until a valid restore succeeds.

## Scheduled prompts

Scheduled prompts run while the app is active. With notification permission, an on-device due-time reminder is scheduled as well. When iOS suspends or terminates the app, exact background execution is not guaranteed; the reminder asks the user to reopen the app, and the prompt runs at the next foreground opportunity. A cloud scheduler is deliberately outside this local-first design.

## Security boundary

Provider keys are never written to SwiftData, backups, logs, or source control.

- Keychain protects local storage. Each newly saved key is bound to its provider adapter and exact percent-encoded base endpoint, so a concurrently changed destination cannot reuse it.
- Legacy raw Keychain values from known preset destinations are atomically upgraded and read back in bound form before first use. An unverifiable or changed destination fails closed and asks for the key again without deleting the old item.
- A mismatched binding can be repaired by replacing or removing the saved key, and configuration rollback restores the previous opaque Keychain value without decoding it.
- "About this chat" shows chat and embedding destinations before a request. Live microphone audio goes only to Google's fixed Gemini Live origin while transcription is active.
- Custom production endpoints should use HTTPS. Local HTTP endpoints are intended only for trusted local networks.

A user-supplied key in a native client remains under that user's and device's control; the app has no server in the path.

## Local macOS builds

The `CODE_SIGNING_ALLOWED=NO` compile checks do not carry App Sandbox entitlements. `scripts/run-macos-local.sh` builds, applies an ad-hoc signature with the checked-in sandbox entitlements, verifies the bundle, and opens it. It refuses to continue while any app process is running, and the bundle prohibits multiple instances.

Because the ad-hoc signature has no Apple application identifier, this explicit local Debug build uses the traditional macOS Keychain instead of the entitlement-backed Data Protection Keychain. Distribution builds never make that fallback: a missing application identifier fails closed. A key saved by the local build may need to be re-entered after a rebuild or when moving to a properly signed release. A sandboxed build cannot inspect a legacy store created by an unsigned app in the process-global `~/Library/Application Support` directory.
