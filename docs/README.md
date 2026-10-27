# Turing AI documentation

- [ARCHITECTURE](ARCHITECTURE.md): system overview, layers, provider transports, context budgeting, memory and retrieval, data policy, storage versioning, backup and recovery, scheduling, sync, and the engineering gotchas behind them.
- [INTERNALS](INTERNALS.md): the rules each subsystem enforces: transports, embedding profiles, OCR, dictation, context budgeting and compaction, bounded reads, receipts, automatic memory, backups, and the security boundary.
- [PRODUCT](PRODUCT.md): product thesis, shipped feature scope, principles, deliberate exclusions and roadmap.
- [DESIGN](DESIGN.md): navigation, accessibility baseline, AI transparency and voice-input design rules.
- [CONNECTIONS](CONNECTIONS.md): device-direct connections to third-party services (REST, hosted MCP, Apple EventKit/Contacts), their auth models, execution budgets and action receipts.
- [GOOGLE-CONNECTIONS](GOOGLE-CONNECTIONS.md): native Google OAuth, the Gmail/Drive research loop, and Google Cloud project setup.
- [MODEL_CATALOG](MODEL_CATALOG.md): per-provider research notes behind the bundled model suggestion catalog, with official sources.
- [PRICING](PRICING.md): bundled model price catalog, calculation rules, expiry and refresh procedure.
- [ON_DEVICE_EMBEDDINGS](ON_DEVICE_EMBEDDINGS.md): design and release gates for an in-app MLX Qwen embedding runtime (not yet integrated).
- [WATCH](WATCH.md): Apple Watch voice app, live and record-and-send paths, security lifecycle, sync protocol and limits.
- [ANDROID](ANDROID.md): Kotlin/Compose port layout, build and signing, Room schema policy and platform differences.
- [RELEASING](RELEASING.md): signed archive, export and TestFlight upload steps for the Apple targets.
- [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md): provider trademark attributions and the licenses of bundled artwork.
