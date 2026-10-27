# Turing AI product brief

## Product thesis

**Models change. Your memory, projects, and work history stay with you.**

Turing AI is a native Apple-platform AI workspace (with a Kotlin/Compose Android port) that keeps the user-facing experience independent from any one model vendor. People connect their own provider accounts, choose a model per conversation, and retain a transparent local layer of conversations, memories, and reusable tasks.

## Release 0.1

### Conversation

- Stream text through 50 built-in provider presets spanning major model labs, inference clouds, gateways, local runtimes, and a custom OpenAI-compatible endpoint.
- Tap the model beneath the conversation title (or use the toolbar model action) to choose any enabled model across connected providers. The next turn uses that model without migrating history or changing earlier request receipts.
- Chats lists contain conversations with messages, nonblank drafts, or unsent attachments. Opening and leaving an empty chat does not add a visible history entry; clearing an unsent draft hides that entry again.
- Compact chat history opens as a full-width drawer from the hamburger button or a left-edge swipe.
- Draft messages in a full-width multiline editor that grows with the text, then scrolls vertically within the available keyboard viewport. Return inserts a newline; send explicitly with the arrow button or Command-Return. Microphone/send controls stay below the text.
- Dictate into the composer with Gemini Live while keeping the eventual chat provider independent.
- Stop a response, append an auditable retry after a provider error, copy a message, and explicitly save a message to memory.
- Show the provider, model, and destination host used for every request.
- Keep long requests inside the selected model limits without truncating message text; preserve the current message and two newest completed turns.
- Automatically compress the oldest completed turns near the selected model's limit, keep the readable result portable across providers, and preserve every raw local message.
- Recover exact relevant details from older current-chat user messages represented by a summary or omitted from the raw suffix, without duplicating verbatim recent history.

### Attachments and model preferences

- Attach up to four photos, PDFs, or text/Markdown files to a message. Photos are normalized to JPEG (at most 1024 pixels on the long edge and 1 MiB) without location/camera metadata. PDF/text content is extracted on-device; chat attachments preserve that extracted text, not the original PDF layout. Tap a sent attachment to inspect it.
- Photos reach the selected provider as image input in Responses, Chat Completions, Anthropic, or Gemini wire format. The chooser marks conservative photo-capable models; custom deployments can explicitly override that capability. Historical photos must stay in the active raw context and within its image/token limits; they are not silently omitted.
- Favorite models, recently used models, a global new-chat default and project overrides share the enabled-model catalog. Disabled models are never selected as defaults. A project without an available override falls back to the app default, then recent enabled choices.

### Personal iCloud sync

- Optional iCloud sync uses each person's private CloudKit database. There is no Turing-owned sync server or application login. Chats, memory, projects, model preferences and attachments sync while the app is active (30-second polling plus Sync Now).
- API keys remain in each device's Keychain and must be added on the other device. Scheduled runs and pending automatic-memory jobs stay device-local to avoid duplicate paid work. The sync setting is off until the user enables it.
- Offline edits are journaled; retained deletion markers prevent old records from returning. Concurrent changes to the same record pause for a choice between device and iCloud versions, with previews and local recovery copies. The last ten pre-receive backups are retained. Incompatible cross-record choices fail validation before replacement.
- Incremental synchronization uploads changed record assets and publishes a verified manifest last. Active raw record content is capped at 128 MiB; old cloud assets can occupy additional iCloud storage. Every device must run a version that understands the incremental manifest; older versions stop safely when they encounter it. This remains foreground synchronization, not a background execution guarantee.

### Conversation tools

- Edit a sent user message or ask another model from a response's menu. A new alternative preserves the completed prefix and attachments, then opens an editable draft; original history remains intact. Choose a model and explicitly send. Alternatives can be reopened from the chat toolbar.
- Temporary Chat holds its entire session in memory, with no saved chat, automatic memory, usage ledger, or iCloud records. Closing it or putting the app in the background clears the session. The selected provider still receives requests under its own service policy.
- Usage & Cost shows daily/monthly reported tokens for chat, compaction, formation and smart ranking. Reviewed official rates are bundled; users can override them for special account tariffs and return to defaults. The searchable Model price list shows sources and its review date. Missing rates and unreported usage are explicit; estimates exclude separate tool/embedding/audio charges and do not reconstruct deleted/temporary usage. Current rates recalculate historical estimates.
- Share text, a Safari page, photos or files to Turing AI from the iPhone share menu. Review the queued item in Shared items and open a new draft. Nothing is sent automatically. Safari supplies extracted page text; other apps may supply only a URL. The queue itself stays local until a draft is imported.
- Web search is an explicit per-chat option for supported native OpenAI and Anthropic models. Answers display provider-supplied source links. Unsupported providers/models show it as unavailable. Search can incur provider tool fees; no separate Turing server or key is involved.

### Provider portability

- Provider keys are stored in Apple Keychain, never in the conversation database.
- Providers manage the connection, endpoint and Keychain reference. Manage Models enables/disables individual chat models and edits each model’s request limits; Save applies the catalog changes. Conversations and tasks share one searchable list of enabled models across all enabled connections. Newly discovered models remain disabled; existing connections retain their previous model until their catalog is managed. Legacy provider model/limit fields remain only for migration compatibility.
- Provider presets are grouped as model labs, inference clouds, gateways, embedding/retrieval services, local runtimes, and custom connections.
- Compatible live model catalogs are followed across every documented page and merged with curated suggestions. Anthropic, Gemini, Cohere, and Fireworks pagination is explicit; xAI uses its language-model endpoint. Chat selectors exclude records that are not positively identified as text-chat capable, including Mistral, Together, Fireworks, Chutes, Hugging Face, OpenRouter, Vercel, Tencent, Baidu, Poe, and LM Studio results. Mixed hosted catalogs and untyped custom/local listings stay manual. Model IDs remain editable because catalogs change, account access differs, and not every provider exposes a compatible listing endpoint.
- Chat, embeddings, model discovery, and live transcription are explicit capabilities; embedding-only connections never appear as chat choices.
- Custom endpoints must use HTTPS, except trusted local-network development endpoints.

### Live transcription

- The microphone control uses an enabled Google Gemini connection even when another provider is selected for chat.
- Connecting, listening, and finalizing are visible states with one accessible start/stop control.
- Interim hypotheses are visible but not persisted. Only finalized text is appended to the local draft, which remains editable before sending.
- Audio is converted to bounded PCM16 mono 16 kHz chunks and sent directly to Google's fixed Gemini Live origin. Redirects are rejected and key-bearing URLs are redacted from errors.
- Stopping, backgrounding, or leaving the conversation closes microphone capture first, signals end-of-audio, and allows a bounded final-result drain. Silence and already-completed turns do not produce false data-loss warnings; only an unresolved interim hypothesis does.
- Continuous sessions stop at 10 minutes; finalized draft text is retained so dictation can continue in a new session.

### Memory

- Smart memory optionally uses the selected chat model for one bounded relevance request across languages (the embedding-ranked top 20 when an embedding profile is enabled, otherwise the first 40 lexical matches; at most six exact IDs, kept from confidence 0.85). It may still add a few memories when nothing applies, and when it succeeds it takes precedence over the optional reranker. It cannot create facts. Invalid, interrupted or timed-out ranking falls back to local matching/enabled embeddings. The extra request can consume provider credits; available token usage and fallbacks appear in the context receipt. Turkish/English concept matching is always available locally. New extracted memories follow the user's language.
- An optional reranker (Memory › Embedding Models › Reranker, off by default) scores the first stage's 20 best candidates against the question with a cross-encoder from Cohere, Jina, Voyage, DeepInfra, llama.cpp, vLLM, LocalAI or a custom `/rerank` host. Its probability alone decides what is injected (no event fade, ties keep first-stage order), an optional minimum relevance drops memories that do not help, and any failure falls back to embedding and local ranking. It sends the question and the candidate excerpts to the chosen provider and is logged as a "Reranker" usage row. See [benchmarks/memory](../benchmarks/memory/README.md) for the measured effect.
- Attachment contents are excluded from personal-memory extraction; only the user's authored message is evidence. Document facts remain available to answer the conversation.

- Turing AI automatically searches eligible completed user messages from earlier conversations, the summarized or omitted prefix of the active conversation, and enabled imported documents for each new request.
- After each successful reply, the selected provider/model may propose atomic lasting information or dated personal events from the exact user message. A personal event embedded in a question can qualify; finding kittens does not establish pet ownership. The app validates the source fingerprint, evidence, confidence, target, bounds, and provider provenance locally before committing anything; assistant output is never treated as evidence.
- Repeated statements reinforce an existing learned topic, corrections create a new current value without erasing earlier revisions, and explicit forget requests deactivate the topic. Every learned topic exposes its source excerpts and full change history and can be edited, paused, or forgotten without approval prompts. Paused, forgotten, and disabled topics are excluded from recall and from later automatic-memory provider payloads.
- Events require stronger extraction confidence, retain the user message’s report date and revision history, and can be updated by later resolutions. Older delayed extraction cannot overwrite a newer event report. Lasting information and Events are displayed separately.
- Event recall loses ranking weight over time (45-day half-life, 40% floor; an event already ranking in the top three results is shielded at 0.85 so a specific old event is still found), without deleting history. At most two event items fit within the existing six-item/8,000-character external-recall budget. Short referential questions can borrow at most two recent user turns; unrelated questions keep their own query. Recalled events are explicitly historical evidence, never proof that a situation still applies.
- A Turkish-aware lexical/character retriever is always available locally; up to four optional embedding profiles add semantic ranking.
- Embedding profiles may point to compatible hosted or local connections, including dedicated Voyage AI and Jina AI presets. Native Qwen and Cohere requests preserve query/document intent; model-specific NVIDIA input rules and provider batch limits are enforced. Split responses must retain one nonzero vector dimension, and rankings are fused without mixing vector spaces.
- PDF, Markdown, and plain-text files are chunked locally with page provenance. Blank, scanned, and weak-text PDF pages use Apple Vision OCR on the device; each recalled chunk discloses OCR provenance, and the document UI records OCR use plus short embedded-text pages retained after the safety limit.
- Embedding-model settings show current, missing, stale, and orphaned document vectors and can safely rebuild the derived document index without deleting source text.
- Pinned facts remain visible, editable, disableable, deletable, and scoped Everywhere, to one project, or to one conversation.
- Every interactive request stores an immutable context receipt containing the exact project name/instructions sent; raw-included, summary-covered, same-chat recalled, and still-omitted chat-message IDs; a readable summary and its generation/reuse/failure status; exact provider/model/endpoint provenance; available usage; inspectable message previews; estimated budget; pinned facts; distinctly labeled same-chat and external recalled excerpts; engines; and fallback warnings used at that time.
- Automatic-memory activity keeps a durable local provider-request and reported-token receipt, including failed attempts and cumulative retry totals.
- Request receipts and rolling summaries use append-only normalized records and immutable artifact references. Complete ID partitions are reconstructed from the raw transcript at inspection time, avoiding quadratic database growth in very long chats.
- Rolling summaries cover only a contiguous completed prefix, remain app-owned after model/provider switching, and are invalidated when any covered raw source changes. A bounded local exact-recall pass may quote covered or omitted older user messages. Included raw messages remain excluded from recall, and newer raw corrections always follow both the summary and excerpts and take precedence.

### Data portability and recovery

- The main store has an explicit V1→V2→V3→V4→V5 additive migration plan. V4 adds project memberships and memory-formation telemetry; V5 adds per-provider model catalogs and per-task model selections without changing older entity hashes. Legacy blobs remain available as a dual-read fallback; new writes are normalized, and a resumable, idempotent bounded conversion API is available for controlled legacy batches.
- A versioned `.mosaicbackup` contains conversations, messages, projects and memberships, curated and learned memories, learned-memory provenance/history/jobs/audits, tasks, exact task-model selections, provider metadata and enabled-model catalogs/limits, embedding profiles, document text/chunks, and opaque legacy/normalized audit bytes with deterministic ordering and an integrity checksum.
- Backups never contain API keys or the rebuildable semantic vector cache. Import gives provider configurations fresh local IDs, leaves every restored provider disabled until explicit review, and pauses restored automations before they can run.
- Restore validates format version, bounded archive/record/payload counts, hashes, normalized and retained legacy audit structure, duplicate IDs, and hard references in a staging store before one transactional replacement of live logical records. Snapshot, staging, replacement, and vector-cache work run outside the UI actor; a failed validation performs no live mutation.

### Scheduled prompts

- One-time, daily, and weekly prompts.
- While the app is active, due prompts run against the exact selected model and provider and store their result as a conversation.
- Recurring prompts remain anchored to the time zone saved with the task.
- With notification permission, the app schedules one on-device reminder for each task's next due time and keeps it synchronized across create, edit, pause, resume, run, delete, restore, and relaunch.
- When an iPhone app is suspended or terminated, the reminder can ask the user to reopen the app, but the local app cannot guarantee an LLM request at an exact time. The prompt runs at the next foreground opportunity.
- A future cloud runner requires separate consent because it changes the promise that keys remain only on the device.

### Projects

- Create, edit, archive, and restore named projects with a separate instruction layer that never overwrites a chat's own system prompt.
- Start a chat inside a project or move an existing chat between projects when no request is in flight.
- A project chat recalls global memory, current-chat memory, and only same-project chats, documents, and project memory. It never recalls another project or an unassigned chat.
- An unassigned chat recalls only global memory, current-chat memory, unassigned chats, and documents marked Everywhere.
- Moving a chat also atomically reconciles learned memory supported only by that chat; mixed-audience evidence blocks the move without leaving partial changes.
- Project assignment is revalidated after asynchronous embedding and automatic-memory calls, so a move during provider work discards stale context instead of crossing the new boundary.

## Deliberately deferred

- Turing-managed cloud accounts
- Team workspaces and sharing
- Managed cloud automation
- Full-duplex spoken conversation and synthesized voice playback
- Code execution and general agent tools
- Plugin marketplace
- Layout-aware table and form extraction beyond plain OCR text
- A bundled neural embedding runtime that does not require Ollama or LM Studio
- Provider-verified context metadata and automatic model-catalog capability sync
- A dedicated model-actor legacy-receipt scanner after the normalization codec is extracted as one shared pure implementation
- Cold-launch opaque store quarantine/generation switching when the source database itself cannot be opened

## Product principles

1. **No silent capability downgrade.** If a provider lacks a feature, show it as unavailable.
2. **No invisible memory.** People can inspect exactly what is remembered and what was attached to a request.
3. **No ambiguous automation.** Label whether a task is a reminder, an on-device run, or a cloud run.
4. **No secret persistence.** Keys stay in Keychain and must never appear in logs, exports, crash reports, or SwiftData.
5. **Native by default.** Use platform navigation, menus, keyboard shortcuts, Dynamic Type, VoiceOver labels, semantic colors, and standard controls.

## Later roadmap

- Memory suggestions that can promote recalled evidence into a pinned fact
- Embedding storage-size management and automatic background reindex scheduling
- Side-by-side model comparison
- Mac menu-bar access, Shortcuts, and widgets
- Optional self-hosted or cloud scheduler with separate provider credentials

## Simple and advanced controls

Simple view is the default on iPhone and Mac. Settings includes Show advanced controls, also available in the Mac Settings window. This is a device-local presentation preference, not a different account, chat library or execution mode. Switching views never changes saved models, provider destinations, credentials, memory options, permissions or prices.

- Both views retain model selection across providers, favorites, voice, connections and their exact action review, source receipts, memory editing/forgetting, document import, iCloud, projects, automations and data recovery.
- Simple setup explains choosing a service, adding an API key and saving before chatting. Standard service addresses remain visible; custom/local/invalid endpoints stay editable so the simpler presentation cannot trap a connection.
- Advanced controls expose model ID additions, request-limit overrides, photo-capability overrides, embedding settings, memory run diagnostics and connector developer registration fields. Missing Microsoft/Dropbox registration disables sign-in with an honest setup explanation.
- Simple chat collapses provider provenance and token counts under Response details. Simple Spending uses the same cost calculation with per-model/category estimates and incomplete/unpriced usage warnings. Advanced view retains the complete usage and custom-price controls.

Implementation: UI/Settings/InterfacePreferences.swift owns the stable UserDefaults key turing.interface.advancedControls. Keep this presentation key out of data migrations, account permissions and execution policy.

## Free-provider setup guide

The provider-free welcome screen and AI models & accounts library expose an optional Explore free options guide. Groq, Gemini, OpenRouter and Mistral entries include example models, published allowances, account/key setup, plan/payment distinctions, data/eligibility notes, dated official sources and an Add my API key action. It opens the existing Keychain-backed editor with the matching provider and one suggested model; OpenRouter starts with openrouter/free, not a paid default. Existing configurations are never changed by browsing the guide.

This is guidance, not a live quota meter, billing-plan detection, a free-only enforcement mode or automatic account creation. Requests and tokens are distinct; memory/tools can consume multiple requests per message. Credentials remain user-owned. Provider sign-up and terms acceptance happen on the provider's site. OpenRouter's documented PKCE flow could streamline user-authorized key creation later; native OAuth onboarding is not implemented here.
