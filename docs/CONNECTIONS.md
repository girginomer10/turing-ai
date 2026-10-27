# Device-direct connections

Turing AI connects from iPhone/Mac to the vendor's API or vendor-hosted MCP service. There is no Turing relay server. The catalog has 21 service entries alongside Gmail and Drive (see [GOOGLE-CONNECTIONS.md](GOOGLE-CONNECTIONS.md)). A catalog entry does not mean an account is connected or that the vendor-side developer registration is complete.

## Implemented capabilities

| Connection | Transport and sign-in | Actions exposed |
| --- | --- | --- |
| Todoist | API v1, personal token | Projects, tasks, filter search, comments, create and complete tasks |
| Linear | Hosted MCP, public PKCE/DCR or personal token | Tools discovered from the authorized workspace |
| Notion | Hosted MCP, public PKCE/DCR | Tools discovered from the authorized workspace |
| Jira & Confluence | Atlassian hosted MCP, public PKCE/DCR or scoped token | Tools allowed by the account and organization |
| Cloudflare | Cloudflare hosted MCP, OAuth or scoped API token | Search/execute Code Mode; both require review |
| GitHub | Official remote MCP, personal access token | Tools allowed by the token and organization |
| Google Calendar | Native Google OAuth; calendar.readonly | Calendar discovery, date/text-filtered events, individual events |
| Google Tasks | Native Google OAuth; tasks.readonly | Task lists and date-filtered tasks |
| Outlook Mail | Microsoft public-client PKCE | Filter/search metadata, selected message bodies |
| Outlook Calendar | Shared Microsoft account | Calendars and events in explicit date ranges |
| Outlook Contacts | Shared Microsoft account | Filtered contact records |
| Microsoft To Do | Shared Microsoft account | Lists and tasks |
| OneDrive | Shared Microsoft account | File search, folder browsing, metadata and bounded text/PDF reads |
| Dropbox | Public-client PKCE | Search, folder browsing, pagination and selected small UTF-8 text/Markdown/CSV/JSON/PDF files; no OCR/Office extraction |
| Readwise | Personal token (`Authorization: Token`) | Books and highlights |
| Airtable | Personal access token | Bases, schema and filtered records |
| ClickUp | Personal token (raw Authorization header) | Workspaces, filtered tasks and task details |
| Raindrop.io | Personal token | Collections, bookmark search and details |
| Apple Calendar | EventKit device permission | Calendars, date/text search and reviewed event creation |
| Apple Reminders | EventKit device permission | Lists, filtered reminders, reviewed creation/completion |
| Apple Contacts | Contacts permission, including limited access | Name search and reviewed contact creation; contact notes are not read |

Direct API adapters other than Todoist and Apple expose reads only. Remote MCP writes are available only through tools actually returned by the vendor and always require review unless the exact app-maintained tool name is a known read. Server-provided `readOnlyHint` annotations never grant authority. This is not a generic arbitrary-URL or local Node/Python MCP launcher.

## Developer setup and readiness

- **Google:** reuses the native iOS/macOS client IDs and callback schemes described in [GOOGLE-CONNECTIONS.md](GOOGLE-CONNECTIONS.md). Calendar API (`calendar-json.googleapis.com`) and Tasks API (`tasks.googleapis.com`) must be enabled in the Google Cloud project, and `calendar.readonly` plus `tasks.readonly` saved in the consent configuration. Users reauthorize to grant the new scopes; Gmail/Drive access is never silently expanded.
- **Microsoft:** register Turing AI once as a public native application supporting the desired personal/organization accounts. Redirect `com.omergirgin.turing:/oauth/microsoft`. No client secret. Requested scopes: `offline_access User.Read Mail.Read Calendars.Read Contacts.Read Tasks.Read Files.Read`. Supply the public client ID via `TuringMicrosoftClientID` in the bundle or the developer setup field. Organization admin policies can restrict consent. One credential is shared by five independently enabled services.
- **Dropbox:** register Turing AI once, with appropriate content access and scopes `account_info.read files.metadata.read files.content.read`; redirect `com.omergirgin.turing:/oauth/dropbox`. Supply `TuringDropboxClientID` or the setup field. Uses S256 and offline refresh without a client secret. End users should not need their own app registration in a production release.
- **Hosted MCP:** public-client registration is attempted against vendor discovery metadata, with a provider-bound custom-scheme redirect. Vendors/organizations may require callback allowlisting; verify actual sign-in for each service. No shared confidential client secret is placed in the binary. Notion has no personal-token fallback.
- **Todoist:** uses the public API with a personal token. Its OAuth MCP flow requires an approved HTTPS callback and is not implemented. The personal-token route needs no Turing server.
- **Apple:** iOS/macOS usage descriptions and macOS calendar/address-book entitlements are included. Permission requests occur only after tapping Allow access. A denied permission does not create a connection. Disconnect disables Turing's access but does not revoke the OS permission itself.

No real user token is embedded, imported from another app, or supplied to a model. Existing external browser sessions are not used as API credentials.

## Execution, costs and recovery

`ConnectionsView` is the unified catalog. `ConnectorDetailView` verifies a token or finishes OAuth before saving a connected state. Credentials are device-local Data Protection Keychain items. Defaults and per-chat choices store only stable connector IDs and connection-generation UUIDs. Reconnecting changes the generation; old chats cannot silently use the replacement account. Google Calendar/Tasks additionally bind to the Google subject and lease revision. Native permission is rechecked before access.

`ConnectorResearch` routes the current user request to up to five relevant enabled services, discovers tools, chooses a tool and prepares schema-checked arguments. It iterates with returned IDs, date filters and cursors. A run has a cooperative 120-second, 100 KB cumulative input and 20-model-call budget; these are work budgets, not a claim that a page is the full collection. Result excerpts are valid JSON with explicit truncation. All planning streams create separate `Connected tools` usage records (including unknown usage), attributed to the actual provider/model. Vendor API/MCP charges are not estimated as model-token costs.

Non-read operations show an exact per-call review sheet. An immutable `ConnectionActionReceipt` is persisted before sending the request, then updated on success, explicit error or uncertain completion. Declines send no request. Uncertain writes are never automatically retried. Receipts survive chat backup/iCloud as optional fields in the existing ExperienceValue webSources sidecar; no SwiftData schema change. Sources/activity panels use immutable value snapshots. Native items without public links still have a visible activity/coverage panel.

Not included: background mailbox/library embedding, automatic bulk import, Watch tool execution, general Apple Notes/Messages access, or server-side automation.

## Files and gotchas

- `ConnectorTypes`: catalog, stable IDs, bounded JSON and tool descriptions.
- `ConnectorHTTP`: fixed-origin, no-cookie/cache/redirect transport and bounded JSON/SSE replies. **Foundation `AsyncBytes.lines` drops empty lines. Never use it for MCP event framing.** Reuse `BoundedSSEStreamDecoder` and match the JSON-RPC response ID.
- `ConnectorStore`: synchronous Keychain mutations inside actor isolation; revision-bound sign-in and single-flight refresh. Never permit a suspended refresh/save to resurrect a disconnected account.
- `ConnectorOAuth`: provider-bound discovery, public DCR, S256, exact redirect/state validation, refresh rotation; no client secrets.
- `ConnectorMCP`: initialization, session/version headers, paginated discovery, conservative exact-name read allowlist and tool calls. Supports 2025 Streamable HTTP vendors, including their SSE response bodies; no legacy standalone SSE transport.
- `ConnectorREST`: app-owned endpoint/argument catalog; model text cannot choose a URL, method or authorization header.
- `ConnectorExecutor`: leases, transport selection, opaque continuation handles and provider responses. Graph/Readwise continuation URLs must keep the original HTTPS host and resource path; model-supplied continuation URLs are rejected. Signed Graph download URLs are stripped.
- `ConnectorFileText`: bounded UTF-8 and selectable-PDF extraction; unsigned Microsoft downloads accept only known storage-domain suffixes and never forward bearer credentials or expose signed download URLs.
- `AppleConnections`: EventKit/Contacts objects stay actor/callback-local; only JSON crosses isolation.
- `ConnectorResearch`, `ConnectionActionReceipt`: provider-independent loop, budgets, approval and durable outcome records.
- `ConnectionsView`, the Google screens, `ConversationView`, `MessageSourcesView`: catalog, opt-in access, chat execution, costs and activity UI. Keep the conversation's layout and presentation chains separate to avoid the iOS SwiftUI type-checker timeout.

## Validation boundaries

Synthetic tests exercise endpoint escaping, scopes, provider auth headers, PKCE/callback mismatch, account replacement/disconnect, MCP handshake/session/pagination, byte-framed SSE, unapproved writes, opaque next-page handles, credential exclusion, per-call usage, declined/executed action receipts and portable encoding. They are not evidence of live OAuth completion or physical-device behavior.

Simulator checks cover the unified catalog and token forms at larger preferred text sizes in light/dark appearance (no overlap, error section reachable by accessible scrolling), the Apple Calendar permission purpose string and a usable app after denial, and an invalid Todoist token returning a real HTTP 401 that is cleared without saving a connection. No private account data is needed for these checks. Live OAuth completion for each hosted service and physical-device behavior remain separate checks.

## Official integration references

- [Todoist API and hosted MCP](https://developer.todoist.com/api/v1/)
- [Linear MCP](https://linear.app/docs/mcp)
- [Notion custom MCP clients](https://developers.notion.com/guides/mcp/build-mcp-client)
- [Atlassian OAuth](https://support.atlassian.com/atlassian-ai-gateway/docs/configure-oauth-2-1/) and [API tokens](https://support.atlassian.com/atlassian-ai-gateway/docs/configure-authentication-via-api-token/)
- [Cloudflare hosted MCP catalog](https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/)
- [GitHub remote MCP](https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp-in-your-ide/set-up-the-github-mcp-server)
- [Microsoft public native OAuth](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
- [Dropbox native PKCE](https://developers.dropbox.com/oauth-guide)
- [Google Calendar reference](https://developers.google.com/workspace/calendar/api/v3/reference) and [Tasks](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list)
- [Readwise API](https://readwise.io/api_deets), [Airtable API](https://support.airtable.com/articles/6292134965-getting-started-with-airtable-s-web-api), [ClickUp authentication](https://developer.clickup.com/docs/authentication), [Raindrop API](https://developer.raindrop.io/v1/raindrops/multiple)
- [EventKit access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store), [Contacts](https://developer.apple.com/documentation/contacts/accessing-the-contact-store)
