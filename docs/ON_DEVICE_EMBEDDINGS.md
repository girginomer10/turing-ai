# On-device embedding runtime decision

## Status

Turing AI already supports local Qwen embeddings through a user-run Ollama or LM Studio connection, plus remote embedding profiles such as DeepInfra and Tinfoil. A Qwen runtime embedded directly in the iOS/macOS app is **designed but not integrated yet**. Do not expose it as available until the physical-device gates below pass.

## Chosen path

Use `MLXEmbedders` from Apple's `mlx-swift-lm` project rather than attempting a first-party Core ML conversion.

- Pin `mlx-swift-lm` to revision `ec6b56a2e7f16e6c948eef1197e500418db0436b`. The current `3.31.4` release predates an attention-mask correction needed for reliable mixed-length Qwen batches.
- Pin the downloadable model to `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` revision `6c3ae70858513f1a78e9cdca3cae330d9075cd2a`.
- The original Apache-2.0 Qwen model is 0.6B parameters, supports more than 100 languages, produces up to 1,024 dimensions, and has a 32K context window. The original weight file is about 1.2 GB; the selected 4-bit MLX weight file is about 335 MB and the full download is roughly 350 MB.
- Download the model only after an explicit user action. It must not inflate the app bundle.

Primary references:

- [Qwen3-Embedding-0.6B model card](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)
- [Pinned 4-bit MLX model](https://huggingface.co/mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ/tree/6c3ae70858513f1a78e9cdca3cae330d9075cd2a)
- [MLXEmbedders model factory](https://github.com/ml-explore/mlx-swift-lm/blob/ec6b56a2e7f16e6c948eef1197e500418db0436b/Libraries/MLXEmbedders/ModelFactory.swift)
- [MLXEmbedders Qwen3 implementation](https://github.com/ml-explore/mlx-swift-lm/blob/ec6b56a2e7f16e6c948eef1197e500418db0436b/Libraries/MLXEmbedders/Models/Qwen3.swift)

## Runtime contract

1. Model state is explicit: `notInstalled`, `downloading(progress)`, `ready`, `loading`, or `failed(message)`.
2. One actor owns the model container. It serializes inference, releases strong references after idle or memory pressure, and calls `MLX.Memory.clearCache()` after unloading.
3. The first release embeds one input at a time. This is predictable on memory-constrained phones and avoids batch-mask regressions.
4. Queries use the English retrieval instruction already defined by `EmbeddingInputFormatter`; document and prior-message chunks are embedded without the query instruction.
5. Start with normalized 1,024-dimensional vectors and a 1,024-token input cap. Smaller Matryoshka dimensions require Turkish/English retrieval evaluation before activation.
6. The vector-space identity includes engine, repository, revision, dimension, and a recipe version. Any change marks old vectors stale and triggers rebuild rather than comparing incompatible vectors.
7. Model updates download into a new revision directory, verify required files, rebuild the derived index, and switch atomically. Never follow a mutable `main` revision silently.
8. If MLX is unavailable or the model is not installed, Turing AI keeps the built-in local hybrid recall and any enabled provider profiles.

## Release gates

- Build both app targets with the pinned dependency and no model bundled.
- Verify download, cancellation, resume, checksum/file validation, deletion, and low-storage errors.
- Measure cold load, single-chunk latency, peak memory, battery, and thermal behavior on representative iPhones, iPads, and Apple-silicon Macs.
- Compare Swift output against the reference Qwen implementation for fixed Turkish and English fixtures, including normalization and last-token pooling.
- Run retrieval-quality evaluation before enabling 512- or 256-dimensional storage.
- Confirm the model unloads under memory pressure and that recall falls back without losing source text.

Core ML remains a possible future optimization, not the current implementation path. No maintained, validated Qwen3-Embedding Core ML recipe or artifact was found; tokenizer, attention mask, pooling, normalization, dynamic shapes, and quantization parity would all become app-owned validation work.
