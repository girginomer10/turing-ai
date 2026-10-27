# Turing AI design system

## Navigation

- iPhone uses a compact stack with a standard navigation bar.
- iPad and Mac use an adaptive sidebar/detail split.
- Conversations occupy the primary content area; Memory, Automations, Providers, and Data & Recovery remain first-class destinations.
- Mac exposes Settings through the standard app menu and `Command-,`; New Chat uses `Command-N`.
- Provider choice and large model catalogs use searchable drill-down lists, so thousands of account-visible model IDs do not become one oversized menu. The exact model ID remains directly editable.

## Accessibility baseline

- System text styles and fonts; no fixed body-text sizes.
- Semantic system colors in light, dark, and increased-contrast appearances.
- At least 44×44 pt primary touch targets on iPhone and standard desktop controls on Mac.
- Labels accompany status colors and provider glyphs.
- VoiceOver labels for icon-only controls and a visible keyboard focus path.
- Reduced Motion does not remove state feedback.

## AI transparency

- The active provider and model stay visible in the conversation header.
- Memory usage is shown as a count and opens the exact pinned facts, same-chat exact excerpts, earlier-chat excerpts, and document chunks supplied.
- Errors explain whether the failure came from configuration, authentication, rate limits, connectivity, or the provider.
- The app never presents generated output as verified fact and never claims a tool ran when the provider does not support it.
- Backup import shows counts and credential/automation consequences before replacement. Destructive restore remains a separate confirmation after the file has passed integrity and reference validation.

## Voice input

- A standard microphone symbol sits beside Send; it remains separate from the selected chat model.
- Connecting, listening, and finalizing are expressed with text and distinct symbols, never color alone.
- The control keeps a standard platform hit target and an explicit VoiceOver label that changes with state.
- The composer is temporarily read-only during capture, renders replaceable interim words, and keeps finalized words in the editable draft after stopping.
- Status copy names the Google destination and explains that nothing reaches the chat provider until Send.
- Backgrounding or leaving the conversation ends capture through the bounded final-result drain; a second stop during connection/finalization cancels promptly.

These choices follow Apple design guidance for accessibility, color, layout, typography, settings, and generative AI: system conventions, visible limitations, user control, and clear disclosure of off-device processing.
