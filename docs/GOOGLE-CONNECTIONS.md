# Direct Google connections

Turing AI connects to Gmail and Google Drive directly from the device with native OAuth. The native client IDs are bundled; a user signs in on each device, grants the read-only scopes, and the app persists the account and tokens in the device Keychain. Calendar and Tasks reuse the same credential through the unified [Connections catalog](CONNECTIONS.md).

## Runtime

The device runs native OAuth authorization-code + PKCE through ASWebAuthenticationSession. No Turing server, service account, client secret, or third-party MCP relay is used. Google OAuth credentials and the verified account subject/email live exclusively in a dedicated device-only Keychain service. iPhone and Mac each connect independently; credentials are not copied through iCloud, backups, WatchConnectivity, or provider requests.

`Settings → Connections` enables read-only Gmail/Drive scopes and connects or switches one Google account on this device. `Use in chats by default` separately opts into sending relevant search excerpts to the selected AI provider. Defaults start off and bind to the account subject; connecting OAuth alone does not turn on model access. Chats without a stored custom choice inherit these device-only defaults. `Chat → + → Connections` overrides services per conversation, including an explicit off choice, and binds that selection to the account subject. A different account requires an explicit new selection. A revision lease blocks delivery of fetched excerpts after disconnect or reauthorization.

For a small allowlist of exact date-only requests such as "Bugün gelen maillerime baksana", native routing searches only the current local day and makes no initial routing call; batch summarization still has ordinary provider usage. Additional filters always go through the planner; never broaden a narrow request with this shortcut. Gmail time bounds use epoch seconds because date strings use PST ([official filtering guide](https://developers.google.com/workspace/gmail/api/guides/filtering)).

For other requests, an initial bounded call to the selected provider produces a validated plan, with one initial query per service and `exhaustive` for all-mail summaries. Gmail then runs an iterative, read-only research loop; Drive retains its five-file search. Dates/senders/subjects are resolved in the initial query. Refinements retain the initial explicit date/sender/subject/label filters in native code. No arbitrary model-supplied URLs, tool names or message IDs are executed.

Gmail lists ten candidate IDs per page and fetches **metadata only** (headers/snippet) before selection. Targeted searches select validated indices from that page; only selected bodies are opened. Empty/unhelpful results can trigger a revised scoped query; body evidence can also request a refinement or next page. Exhaustive requests open every matching item, summarize each batch into bounded accumulated evidence, and keep paging regardless of a model's premature finish. IDs are deduplicated, skipped candidates remain eligible under revised queries, and repeated/oversized page tokens are rejected. Full bodies and attachments are not placed wholesale into the model context; excerpts and generated summaries remain explicitly untrusted evidence. The final answer reports inspected headers, processed excerpts and partial versus exhausted coverage. The source panel retains up to 100 distinct links, disclosing omissions.

The loop uses a cooperative 90-second work budget, 100,000 cumulative model-input bytes and 8,000 reserved model-output tokens per run (plus initial routing). It checks time/authorization between network operations and during model streaming; an individual network wait remains subject to the existing HTTP timeouts. These are work budgets rather than a fixed mailbox-size limit. Budget exhaustion returns partial evidence and a **device-memory-only continuation**, bound to the conversation, Google subject and authorization revision. Explicit "devam et" / "continue" resumes the pending batch/cursor while that chat stays open; restarting the app or recreating the chat view loses it. There is no background mailbox index, embeddings, raw mailbox import or server. An optional semantic index would be a separate future layer.

Every routing, selection and summarization stream creates its own `Connected search` usage record before the provider request, then updates it with reported usage. Missing usage remains unknown. Normal answer tokens stay on the assistant message. Before every intermediate provider call, the account revision and chat permission selection are revalidated; disconnect/cancellation does not silently return successful partial results. Tokens never enter provider payloads, exports, iCloud or the Watch. Saved answers, condensed evidence-derived output and source receipts follow the existing chat backup/iCloud behavior; ephemeral working excerpts/cursors are not persisted.

Drive reads Docs/Slides text exports, the first sheet of Sheets as CSV, UTF-8 text/JSON/XML, and bounded text from PDF pages; unread formats/large files disclose metadata-only results. PDFs with scanned-only content require opening the original; OCR is not performed here. Google credentials cannot follow HTTP redirects or be sent to arbitrary hosts. Auth and API error bodies are not shown/logged.

## Progress and sources in the response

Planning, Gmail/Drive search and per-item reading progress render inside the assistant response while the research loop runs. `GoogleSearchProgress` reflects actual planning/list/read operations and never uses timers to imply work; progress belongs to the pending assistant message and is cleared on completion, failure or cancellation. Completion becomes a compact source button (including an honest no-match receipt) that opens a separate scrollable native panel. The `+` menu shows **Connections · On** when access is active; there is no permanent connected-service strip in the composer. Progress callbacks add no model requests, and persisted receipts contain source links/service names rather than additional email excerpts. Optional `ExperienceValue.searchedServices` preserves completed zero-result searches and stays compatible with older portable receipts.

Original source links use iOS universal-link routing first, then the system browser fallback, which preserves the original URL/account selector. There is no generic supported URL for opening an existing Gmail message in every possible default mail app: `mailto:` composes a new message, so it must not replace a source link. See [Apple universal links](https://developer.apple.com/documentation/Xcode/allowing-apps-and-websites-to-link-to-your-content) and [Mail links](https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/MailLinks/MailLinks.html).

## Google Cloud setup

1. Create a Google Cloud project for the app (no billing account is required for these APIs). Enable the Gmail API, Google Drive API, Calendar API and Tasks API.
2. Configure the Google Auth Platform / OAuth consent screen: app name Turing AI, External audience. While the audience is in Testing mode, only listed test users can sign in and refresh tokens expire on Google's testing-mode schedule. Save the scopes `openid`, `https://www.googleapis.com/auth/userinfo.email` (the console's canonical email scope), `https://www.googleapis.com/auth/gmail.readonly`, `https://www.googleapis.com/auth/drive.readonly`, `https://www.googleapis.com/auth/calendar.readonly` and `https://www.googleapis.com/auth/tasks.readonly`. All access is read-only; sending/editing is not implemented.
3. Create two **iOS-type** OAuth clients, one per bundle ID. Google's native Apple documentation requires the iOS client type for both iOS and macOS; do not change the Mac client to Desktop, because the native Apple flow uses the reversed client-ID custom scheme. Do not enable Firebase App Check or a server client.
4. Configure the public IDs through `scripts/configure-google-oauth.py`, then `xcodegen generate`. They land in `project.yml` as `TURING_GOOGLE_*` build settings and in each target's Info.plist as `TuringGoogleClientID` plus a `CFBundleURLTypes` entry. The expected redirect is `REVERSED_CLIENT_ID:/oauthredirect`. Check both compiled Info.plists for exact matching callbacks. No client secret belongs in this app.
5. Each device needs its own Google login; credentials do not sync between iPhone and Mac or through iCloud.

The bundled public native client IDs (not secrets):

- iPhone, `com.omergirgin.mosaic`: `986659128595-2ouh9lfcb6lpj494rsmeeoegqmpki0eq.apps.googleusercontent.com`
- Mac, `com.omergirgin.mosaic.macos`: `986659128595-ibb80ggv4eltjhv14sskmbiouigpjd2t.apps.googleusercontent.com`

Public release needs restricted-scope verification, public homepage/privacy/terms URLs, privacy disclosures, and an assessment of the transfer of excerpts to the selected AI provider; a device-only design does not automatically waive these requirements. Testing-mode refresh-token expiry and Workspace admin restrictions may require reconnecting or admin approval.

Enabling Calendar or Tasks for a device session requires reauthorization on that device, because the new scopes are not implied by an earlier Gmail/Drive grant. Calendar/Tasks run through `ConnectorREST`/`ConnectorResearch`, not through `GoogleSourceClient`'s mail/file switch; their defaults bind both to a connector generation and the current Google account subject.

## Files

- `Connections/GoogleConnectionTypes.swift`: scoped identities, PKCE and strict callback/plan data.
- `GoogleHTTPClient.swift`: ephemeral bounded HTTP, fixed hosts, no redirects.
- `GoogleConnectionStore.swift`: Keychain envelope, actual granted scopes, refresh serialization, account/revision leases.
- `GoogleSignInSession.swift`: native browser presentation and cancellation with Sendable callback entry.
- `GoogleSourceClient.swift`: fixed Gmail/Drive operations and bounded content extraction.
- `GoogleChatSearch.swift`: initial routing, service isolation and evidence assembly.
- `GmailResearch.swift`: metadata selection, read-only iteration, batch summaries, work budgets and ephemeral continuation.
- `GoogleConnectionsView.swift`: settings and per-chat consent/selection.
- `ConversationView.swift`: execution, context budget, source citations and independent search usage.

## Validation

Tests use synthetic tokens and stub HTTP/provider transports, never real Google or AI credentials. They cover OAuth state/PKCE, scope escalation, replay rejection, actual granted scopes, account isolation, disconnect during refresh, query/ID restrictions, MIME handling, context limits, request accounting boundaries, fixed endpoints, snapshot validation, empty-result round trips, HTTP-backed progress/error ordering, more-than-25-result paging, selective body reads, resume without re-downloading completed bodies, and permission revocation/cancellation. Run `swift test --package-path Packages/MosaicCore` plus the iOS/macOS Xcode builds.

A real sign-in in the iPhone Simulator verifies callback, token exchange, verified identity, granted scopes and Keychain persistence across relaunch. Live mailbox/file search quality, expiry-driven refresh, denied/partial scopes, and physical-device login are separate checks. The DEBUG-only `--in-memory --sources-preview` fixture renders long transcripts and source lists without private data or API calls.

## Official references

- [Native OAuth + PKCE](https://developers.google.com/identity/protocols/oauth2/native-app)
- [iOS and macOS client configuration](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Gmail search](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list)
- [Gmail message reading](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/get)
- [Drive export formats](https://developers.google.com/workspace/drive/api/guides/ref-export-formats)
- [Restricted-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)
