# Apple Watch voice

Turing AI includes a single-target watchOS 10+ app bundled with the iOS app. Initial setup requires the paired iPhone. After setup, requests go directly from Watch to the selected provider over its available internet connection; there is no Turing server.

## Setup

1. Install matching Turing AI iPhone and Watch builds.
2. On iPhone, open Settings → Apple Watch and enable voice access.
3. Keep both apps open, then sync models and keys. Repeat after changing provider credentials, endpoints or enabled models.
4. Choose Live conversation or Record & send on Watch.

Only enabled HTTPS chat providers with endpoint-bound Keychain credentials transfer. Local HTTP providers are excluded. Live supports the official OpenAI and Gemini endpoints only. Model availability and API balance are enforced by the provider; a catalog entry does not guarantee account access.

## Voice paths

- **Live:** OpenAI `gpt-realtime-2.1` or Google `gemini-3.1-flash-live-preview`, using microphone PCM16 mono at 24 kHz and streamed audio playback. Voice activity detection allows interruption; OpenAI truncates unplayed output from its conversation context. Foreground sessions stop after five minutes, on Stop, backgrounding, audio interruption or connection failure. No automatic paid retry/reconnect.
- **Record & send:** Record up to 60 seconds; OpenAI `gpt-transcribe` produces a transcript. Read it in full, optionally edit using native Watch text input, then explicitly Send. Any synced enabled chat model can answer. OpenAI `gpt-4o-mini-tts` with the Marin voice reads the answer; Read aloud retries speech without resending the chat request. Requires an official OpenAI connection for transcription and speech.

The voice is AI-generated. Provider charges use the user's own balance. Watch chat, live, transcription and speech usage appear in iPhone Usage & Cost. Watch keeps a protected local history and immutable acknowledged outbox; iPhone imports into the existing chat library, portable backups and the user's iCloud sync. Leaving a conversation preserves saved turns and drafts. Model changes keep history and seed the new model with a bounded recent prefix. Backgrounding stops audio, not saved history.

## Security and lifecycle

- Credential snapshots travel only through interactive paired WatchConnectivity messages, never application context, queued userInfo, logs or iCloud.
- Watch stores the complete snapshot atomically as one Keychain item, `WhenUnlockedThisDeviceOnly`. Disabling access on iPhone sends a non-secret dated revocation; removal takes effect when Watch reconnects. Local Remove access removes the copied keys immediately. A stored revocation blocks stale snapshots and stale Keychain recovery.
- Requests reject redirects and use ephemeral sessions without cookies, caches or URL credential storage. Native live host/path/port checks prevent using an official-provider credential at a substituted WebSocket endpoint.
- Generation checks cancel late audio/network completions. Audio activation is serialized so a cancelled permission/routing request cannot reactivate the microphone after Stop.
- Recordings live only in a feature-owned temporary folder and are deleted after transcription/cancel; abandoned recordings are removed on the next voice-controller initialization. Bounded input/output queues stop on backpressure; provider errors never expose raw echoed keys/URLs.
- Transcript and chat response limits are 16 KiB, history is bounded, sync is capped at 60 KB, recorded audio and synthesized speech responses at 8 MiB.

## WatchConnectivity callback isolation

Unannotated WatchConnectivity reply/error closures written inside a MainActor method inherit MainActor isolation under Swift 6. The framework invokes them on background queues, which triggers a Swift executor assertion before any inner UI `Task` can run. Both iPhone and Watch therefore obtain reply/error handlers from nonisolated `VoiceCallbackDelivery`, with explicitly Sendable audio callbacks that hop to MainActor before touching UI. The same correction applies to the microphone input tap, session activation and playback completion callbacks; audio-interruption notifications are explicitly delivered on the main queue. Tests exercise replies and errors from a GCD background queue. Both devices must run a build with this fix for both sync directions to work.

## Live dialogue lifecycle

Three behaviors ended live sessions prematurely on a physical Watch: `.inactive` unconditionally stopping the session (watchOS uses this state for wrist-down, frontmost changes and routing UI), every audio interruption notification stopping it including `.ended`, and a 20-second PCM queue that threw and tore down the connection when a long response arrived faster than playback.

The current controller keeps the connection and microphone through inactive/active transitions and response completion. Actual background, interruption-began, Stop, the five-minute limit, and connection failures still stop audio, with distinct status messages. Queued output can hold up to 120 seconds (about 11.5 MB of float PCM); scheduled tail accounting does not double-count partially played buffers. Fully played responses are not truncated when the next user turn begins. There is no automatic paid reconnect.

`WatchConversation` lives in TuringVoice behind audio/transport protocols so tests exercise the production controller with deterministic hardware/network substitutes: two turns on one connection, response-finished while audio is still queued, wrist-down, interruption began/ended, real background cancellation, barge-in, and 30-second output bursts/capacity enforcement.

Source: [Apple frontmost app lifecycle](https://developer.apple.com/documentation/watchkit/taking-advantage-of-frontmost-app-state).

## Chat history, memory and usage integration

- Watch Chats loads paginated iPhone conversations and recent text turns. Continue any downloaded chat in either voice mode; a native model picker includes all synced enabled chat models or enabled official live models. Live model toggles live under iPhone Apple Watch settings. Shared phone conversations keep a text-capable model when the Watch uses a realtime model.
- Completed Watch turns persist atomically with their outgoing transfer. Drafts survive leaving the screen. Offline turns and usage wait for an acknowledged interactive paired transfer when iPhone is reachable. Refresh chats or reopen both apps to sync; this is not a continuously running background server. Usage acknowledgements never falsely mark a not-yet-created chat as existing on iPhone.
- Phone import appends immutable message IDs and preserves phone titles, drafts and archive state. A receipt survives chat deletion, so a lost acknowledgement cannot resurrect deleted chats. Late offline turns can append to an archived chat without unarchiving it. Costs remain after conversation deletion. Bounded pages use timestamp and UUID cursors to avoid skipping equal-date records.
- Before each new recorded request or live session, a reachable iPhone supplies a bounded selection from the same project-aware/disabled/expiry-checked memory retrieval and system prompt. Offline Watch uses downloaded chat history and clearly says iPhone memory is unavailable. Live memory is a session-start snapshot. Completed imported exchanges enter the existing audited automatic-memory formation path when enabled; an existing job is not automatically paid-retried. Model selection is rechecked when iPhone is reachable; offline uses the last explicit configuration sync.
- Usage keeps stable request/session IDs and increasing revisions. OpenAI response IDs are deduplicated; Gemini usage snapshots are committed once per turn. Live transcription has separate attempt receipts. Recorded speech uses the official SSE audio-done usage. Audio cost estimates use dated official standard rates and reported modalities/cache/duration; missing data, custom hosts and expired rates remain unpriced. Watch chat uses the existing text model rate/custom-price system. No paid request is automatically retried.
- Watch text history is limited to 1,000 turns per chat / 200 cached chats / 32 MB, with a 5,000-transfer outbox and 60 KB wire messages. A detail page carries up to 20 recent messages with a bounded text budget; long phone content may be clipped on Watch. The full phone source remains unchanged. Saved history contains no API credentials; Keychain and credential revocation remain separate. Remote context includes at most six selected items within 8 KB.
- Regressions cover two live turns without restart, late OpenAI transcription pairing, Gemini second-turn persistence, preserved model/history/drafts, atomic write failures/relaunch, usage-only acknowledgements, deleted/archived chats, repeated/out-of-order imports, same-date pagination, rates/SSE, and portable provider-ID remapping. Tests make no paid provider requests.

## Background usage delivery and model layout

- Usage-only records additionally use WatchConnectivity's system-managed `transferUserInfo` queue when interactive phone reachability is unavailable. Messages, drafts, context and credentials are excluded from this background envelope. The persistent Watch outbox remains authoritative until the phone acknowledges a successful durable save; a latest cumulative revision covers older revisions of the same usage ID. Queue admission is bounded to ten outstanding deliveries with throttled retries; OS scheduling is eventual, not immediate. Revoking Watch access cancels queued usage and disables handling.
- Phone Watch imports commit through the existing coordinator save gate while holding the verified lease; a raw `context.save()` would bypass refresh revisions. The open Usage & Cost view debounces revision-driven refreshes, constructs its report reader off the main actor and rejects stale cancelled loads. No token estimates are invented when the provider omits usage.
- Model selection uses a shared scalable, multiline model/provider label and a separate native list. Display replaces identifier hyphens with spaces for wrapping; selection, API requests and accounting preserve the exact original ID. DEBUG `--watch-ui-preview --watch-live-layout --preview-model=...` renders this view with synthetic endpoints and no live call.
- Tests cover background envelope restriction/latest revision selection, durable import publication and cumulative usage/idempotency behavior.

## Validation and limits

The package's protocol tests cover routing/auth, disabled models, endpoint substitution, native setup payloads, malformed/unsupported PCM, interruptions, response extraction and sanitized errors. MosaicCore tests cover regression of shared app behavior. Watch UI preview fixtures are DEBUG-only, synthetic, do not persist keys and make no network requests.

Simulator validation cannot establish physical microphone/speaker routing, WatchConnectivity behavior on a user's devices, OS-scheduled background transfer, account-specific live access or cellular reliability. Test those on a physical paired Watch before treating live voice as production-verified.

## Sources

Last reviewed: 2026-09-06.

- [OpenAI Realtime](https://developers.openai.com/api/docs/guides/realtime)
- [OpenAI Realtime conversations and interruption](https://developers.openai.com/api/docs/guides/realtime-conversations)
- [OpenAI transcription](https://developers.openai.com/api/docs/guides/speech-to-text)
- [OpenAI text-to-speech model](https://developers.openai.com/api/docs/models/gpt-4o-mini-tts)
- [Gemini Live wire reference](https://ai.google.dev/api/live)
- [Apple low-level networking on watchOS](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)
- [Apple single-target Watch apps](https://developer.apple.com/documentation/watchos-apps/migrating-to-a-single-target-watchos-app)
- Pricing: [OpenAI pricing](https://developers.openai.com/api/docs/pricing), [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing), [OpenAI speech stream events](https://platform.openai.com/docs/api-reference/audio)
