# Security

Turing AI is a bring-your-own-key client with no backend. The security-relevant surface is the device: how keys are stored, where requests go, and what leaves the app in a backup.

## Reporting a vulnerability

Please do not open a public issue for security problems. Email the address on the maintainer's GitHub profile with:

- the affected platform and version,
- steps to reproduce or a proof of concept,
- the impact you believe it has.

You will get an acknowledgement within a few days. Fixes ship in the next release and the report is credited unless you ask otherwise.

## What is in scope

- API keys or OAuth tokens reaching anywhere other than Keychain / Keystore, or leaving the device in a backup, log, or export.
- A request being sent to a destination other than the one shown in "About this chat".
- Prompt-injection paths that let model output alter saved memory, project scope, or connection actions without the validation described in [docs/INTERNALS.md](docs/INTERNALS.md).
- Backup import that can mutate the live library without passing integrity checks.

## What is out of scope

- Behaviour of third-party providers or their models.
- Cleartext HTTP to local-network runtimes (Ollama, LM Studio, llama.cpp); this is intentional and documented, and the app enforces HTTPS for non-local hosts.
- Issues that require a jailbroken or rooted device.

## Design notes

See [docs/INTERNALS.md § Security boundary](docs/INTERNALS.md#security-boundary) for how key binding, endpoint verification, and backup redaction work.
