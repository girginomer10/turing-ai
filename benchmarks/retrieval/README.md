# Retrieval benchmark: single vs fused embedding profiles

Measures the app's real `HybridMemoryRetriever` (Swift, `Packages/MosaicCore`) on **XQuAD** (Artetxe et al., 2020):
1,190 parallel Turkish/English questions over 240 Wikipedia paragraphs per language. Six settings:
`tr->tr`, `en->en`, cross-lingual `tr->en` and `en->tr`, and a bilingual 480-paragraph store queried in
either language (`tr->mixed`, `en->mixed`, either-language counterpart counts as relevant).

Three local embedding models run through llama.cpp, with the same query/document prefixes the app uses
(`EmbeddingInputFormatter`): `nomic-embed-text-v1.5` (Q4_K_M, English-centric), `bge-m3` (Q8_0, multilingual),
`Qwen3-Embedding-0.6B` (Q8_0, multilingual). The retriever receives the cosine scores as `SemanticScoreSet`s,
exactly like production, so the lexical scoring, reciprocal-rank fusion (k = 60), gates and blend weights
under test are the shipped code. Candidate pool = whole corpus (the app prefilters to 96).

## Protocol

* **DEV/TEST split** by gold paragraph (even/odd index, paragraph-disjoint). Configurations are selected on DEV;
  headline numbers are TEST only.
* Metrics: MRR@10, Recall@{1,5,10}, nDCG@10. Intervals and p-values use a **paragraph-cluster bootstrap**
  (10,000 resamples) and a cluster sign-flip permutation test, because questions on one paragraph are correlated.
* `ablate.py` re-implements the shipped blend in Python, **verifies it reproduces the Swift ranks (100%, 42,840/42,840 cases)**, then
  swaps individual parts. This does not change the app; it quantifies headroom.

## Headline results (TEST, macro-MRR@10 over six settings, current retriever)

| config | MRR@10 | worst setting |
|---|---|---|
| no embedding model (local lexical only) | 0.716 | 0.287 |
| nomic only | 0.745 | 0.378 |
| qwen3 only | 0.921 | 0.800 |
| bge-m3 only | 0.950 | 0.894 |
| bge-m3 + qwen3, fused | 0.950 | 0.891 |
| all three, equal weight | 0.926 | 0.825 |

* The best profile (bge-m3) beats local-only by ΔMRR +0.234 (95% CI [+0.214, +0.254], p < 1e-4), an **82.4% cut** of the
  MRR shortfall (qwen3 alone: 72%) (1 − MRR). Cross-lingual MRR rises from ≈0.29–0.32 to ≈0.9.
* With the current blend, fusing bge-m3 + qwen3 **equals** the best single model (ΔMRR +0.000 [−0.006, +0.007],
  p = 0.92). Adding the English-centric model at equal weight *hurts* (−0.024 [−0.032, −0.017]); down-weighting it
  ×0.1 recovers the pair's score. Fusion's value here is avoiding lock-in to one vector space, not a measured accuracy gain.

## The change this benchmark drove

The first retriever turned each profile's score into a rank percentile (rank 1 vs 5 of ~240 differ by ≈0.007 of the
blended score), so lexical noise decided the final order. It now min-max scales each profile's raw cosine per query
(`HybridMemoryRetriever.swift`, mirrored in the Android port). Before → after on the same TEST half (paired, pooled):

| config | before | after | ΔMRR@10 [95% CI] |
|---|---|---|---|
| bge-m3 | 0.841 | 0.950 | +0.109 [+0.096, +0.122] |
| qwen3 | 0.843 | 0.921 | +0.078 [+0.067, +0.089] |
| bge-m3 + qwen3 | 0.865 | 0.950 | +0.085 [+0.075, +0.096] |
| all three | 0.832 | 0.926 | +0.094 [+0.082, +0.106] |

The offline ablation predicted exactly these numbers before the code change, and the rebuilt Swift retriever reproduces
them. A remaining finding: in cross-lingual settings ~26% of candidates tie at the minimum local score (zero lexical
overlap) and the retriever breaks ties by UUID string, i.e. arbitrarily. Index-ordered UUIDs in the harness make
runs deterministic; the Python replication of the *current* blend agrees on 100% (42,840/42,840) of cases.

## Eight embedding models (later run)

The same harness was rerun with eight local models (nomic v1.5, bge-m3, Qwen3-Embedding 0.6B/4B, EmbeddingGemma-300M, nomic v2 MoE,
multilingual-e5-large-instruct, Snowflake Arctic Embed L v2) and rank-fusion candidates among the top five. On TEST paragraphs
(macro over the six settings): Qwen3-4B 0.958, EmbeddingGemma 0.953, bge-m3 0.950, Arctic 0.949, e5 0.948, nomic v2 0.942,
Qwen3-0.6B 0.921, nomic v1.5 0.745, lexical only 0.716. The best fusion selected on DEV (Qwen3-4B + bge-m3 + nomic v2) beats the best
single model by +0.005 [+0.001, +0.009] (p = 0.024): at this ceiling fusion adds little. Full table: [RESULTS.md](RESULTS.md)
(`models_eval.py`). The personal-memory benchmark spreads the same models far more; see [../memory](../memory/README.md).

## Limitations

XQuAD is encyclopedic QA, not personal memory (shorter facts, confidence/importance multipliers, event decay);
the corpus is small (240 candidates per language) so monolingual settings have ceiling effects; models are local
quantized builds, hosted endpoints may differ; the weight sweep and fusion-function variants are exploratory
(selected on DEV, reported on TEST) and not yet applied to the app.

## Reproduce

```sh
brew install llama.cpp                      # llama-server
python3 -m venv .venv && .venv/bin/pip install numpy
# put bge-m3-Q8_0.gguf and Qwen3-Embedding-0.6B-Q8_0.gguf in $MODELS (Hugging Face: gpustack/bge-m3-GGUF, Qwen/Qwen3-Embedding-0.6B-GGUF)
.venv/bin/python embed_scores.py --models-dir "$MODELS"          # downloads XQuAD, writes work/scores/*.f32
swift run -c release --package-path Bench RetrievalBench work    # real retriever -> work/results.json, work/local/*.f32
.venv/bin/python analyze.py                                      # work/results.md
.venv/bin/python ablate.py                                       # work/ablation.md
```

Full tables: [RESULTS.md](RESULTS.md). XQuAD is CC BY-SA 4.0 and is downloaded at run time, not stored here.
