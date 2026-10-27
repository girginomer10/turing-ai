# Synthetic personal-memory benchmark: results

8 fictional personas, 560 stored items, 360 queries (304 answerable, 56 unanswerable). Real `HybridMemoryRetriever`, three local embedding models. Two-stage (persona → query) bootstrap, B = 4000. No parameter was tuned on this data except the abstention thresholds in §8 and §10 (DEV personas p1,p3,p5,p7 → TEST p2,p4,p6,p8).

## 1. Each persona's own store (60-75 candidates), current retriever

| config | MRR@10 [95% CI] | R@1 | R@3 | gold injected (top-6) | nDCG@10 | false recall (unanswerable) |
|---|---|---|---|---|---|---|
| bge-m3 | 0.828 [0.778, 0.875] | 0.724 | 0.921 | 0.970 | 0.868 | 100% (6.0 items) |
| bge-m3+qwen3-emb-0.6b | 0.817 [0.767, 0.861] | 0.724 | 0.901 | 0.944 | 0.857 | 100% (6.0 items) |
| nomic-v1.5*0.1+bge-m3+qwen3-emb-0.6b | 0.812 [0.761, 0.858] | 0.720 | 0.901 | 0.941 | 0.852 | 100% (6.0 items) |
| qwen3-emb-0.6b | 0.770 [0.718, 0.818] | 0.684 | 0.849 | 0.905 | 0.810 | 100% (6.0 items) |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.726 [0.673, 0.776] | 0.609 | 0.816 | 0.905 | 0.780 | 100% (6.0 items) |
| nomic-v1.5+bge-m3 | 0.683 [0.620, 0.746] | 0.586 | 0.737 | 0.836 | 0.738 | 100% (6.0 items) |
| nomic-v1.5+qwen3-emb-0.6b | 0.649 [0.588, 0.710] | 0.553 | 0.701 | 0.803 | 0.697 | 100% (6.0 items) |
| nomic-v1.5 | 0.550 [0.475, 0.620] | 0.474 | 0.605 | 0.664 | 0.586 | 100% (6.0 items) |
| local-only | 0.440 [0.376, 0.507] | 0.382 | 0.464 | 0.523 | 0.472 | 98% (5.4 items) |

*MRR@10 by subset (per-persona stores).*

## 2. By query type

| query type | n | local-only | bge-m3 | bge-m3+qwen3-emb-0.6b | nomic-v1.5+bge-m3+qwen3-emb-0.6b |
|---|---|---|---|---|---|
| direct | 56 | 0.884 | 0.956 | 0.945 | 0.936 |
| paraphrase | 96 | 0.243 | 0.773 | 0.806 | 0.773 |
| cross_lingual | 80 | 0.065 | 0.705 | 0.643 | 0.365 |
| hard_negative | 72 | 0.775 | 0.936 | 0.925 | 0.901 |

## 3. By query language

| query language | n | local-only | bge-m3 | bge-m3+qwen3-emb-0.6b | nomic-v1.5+bge-m3+qwen3-emb-0.6b |
|---|---|---|---|---|---|
| tr | 159 | 0.480 | 0.877 | 0.846 | 0.756 |
| en | 145 | 0.396 | 0.774 | 0.785 | 0.693 |

## 4. By kind of the gold item

| gold item kind | n | local-only | bge-m3 | bge-m3+qwen3-emb-0.6b | nomic-v1.5+bge-m3+qwen3-emb-0.6b |
|---|---|---|---|---|---|
| topic | 125 | 0.444 | 0.838 | 0.847 | 0.764 |
| event | 77 | 0.518 | 0.849 | 0.836 | 0.731 |
| message | 55 | 0.356 | 0.839 | 0.810 | 0.693 |
| document | 47 | 0.404 | 0.754 | 0.713 | 0.654 |

## 5. Pooled store (all personas together, ~500 candidates)

| config | MRR@10 [95% CI] | R@1 | gold injected (top-6) | false recall |
|---|---|---|---|---|
| local-only | 0.348 [0.287, 0.410] | 0.289 | 0.441 | 100% |
| bge-m3 | 0.599 [0.538, 0.666] | 0.497 | 0.776 | 100% |
| bge-m3+qwen3-emb-0.6b | 0.624 [0.565, 0.686] | 0.520 | 0.776 | 100% |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.553 [0.489, 0.620] | 0.464 | 0.691 | 100% |

## 6. Before both changes (rank-percentile blend, 14-day event fade) vs current retriever, same data, paired

| config | previous MRR | current MRR | ΔMRR@10 [95% CI] | p | Δ gold-injected |
|---|---|---|---|---|---|
| bge-m3+qwen3-emb-0.6b | 0.572 | 0.817 | +0.244 [+0.200, +0.291] | 0.0003 | +0.151 |
| qwen3-emb-0.6b | 0.522 | 0.770 | +0.249 [+0.204, +0.295] | 0.0003 | +0.148 |
| nomic-v1.5*0.1+bge-m3+qwen3-emb-0.6b | 0.560 | 0.812 | +0.252 [+0.210, +0.297] | 0.0003 | +0.148 |
| nomic-v1.5 | 0.422 | 0.550 | +0.128 [+0.085, +0.174] | 0.0003 | +0.118 |
| nomic-v1.5+bge-m3 | 0.488 | 0.683 | +0.194 [+0.155, +0.237] | 0.0003 | +0.164 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.519 | 0.726 | +0.207 [+0.166, +0.248] | 0.0003 | +0.184 |
| bge-m3 | 0.543 | 0.828 | +0.285 [+0.239, +0.332] | 0.0003 | +0.168 |
| local-only | 0.393 | 0.440 | +0.047 [+0.023, +0.077] | 0.0003 | +0.036 |
| nomic-v1.5+qwen3-emb-0.6b | 0.474 | 0.649 | +0.175 [+0.134, +0.217] | 0.0003 | +0.151 |

False recall on unanswerable queries (bge-m3+qwen3-emb-0.6b): previous 100% → current 100%.

## 6b. Event-fade change alone: legacy 14-day/0.15 fade vs the standard policy (same min-max retriever), paired

| config | subset | legacy fade MRR | standard MRR | ΔMRR@10 [95% CI] | p |
|---|---|---|---|---|---|
| bge-m3+qwen3-emb-0.6b | answer is an event (n=77) | 0.480 | 0.836 | +0.356 [+0.262, +0.453] | 0.0003 |
| bge-m3+qwen3-emb-0.6b | answer is not an event (n=227) | 0.818 | 0.810 | -0.008 [-0.020, -0.001] | 0.0008 |
| local-only | answer is an event (n=77) | 0.305 | 0.518 | +0.213 [+0.116, +0.327] | 0.0003 |
| local-only | answer is not an event (n=227) | 0.423 | 0.414 | -0.009 [-0.021, -0.002] | 0.0003 |

## 7. Paired comparisons (current retriever, per-persona stores)

| comparison | ΔMRR@10 [95% CI] | p |
|---|---|---|
| bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.011 [-0.035, +0.014] | 0.3717 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.102 [-0.140, -0.066] | 0.0003 |
| bge-m3+qwen3-emb-0.6b vs local-only | +0.377 [+0.318, +0.435] | 0.0003 |
| bge-m3 vs local-only | +0.387 [+0.332, +0.442] | 0.0003 |

## 8. Can the retriever abstain? (top-1 relevance as an answerable-vs-unanswerable detector)

| config | AUROC (all) | false recall at app defaults | τ chosen on DEV (keeps 90% of answerable) | TEST: answerable kept | TEST: unanswerable still recalled |
|---|---|---|---|---|---|
| local-only | 0.484 | 98% | 0.432 | 89% | 89% |
| bge-m3 | 0.435 | 100% | 0.556 | 91% | 96% |
| bge-m3+qwen3-emb-0.6b | 0.446 | 100% | 0.561 | 91% | 100% |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.446 | 100% | 0.536 | 92% | 100% |

## 9. Events fade by design: MRR@10 of event-gold queries by age of the gold item (current retriever)

| age of gold event | n | local-only | bge-m3 | bge-m3+qwen3-emb-0.6b | nomic-v1.5+bge-m3+qwen3-emb-0.6b |
|---|---|---|---|---|---|
| <= 14 days | 57 | 0.516 | 0.854 | 0.833 | 0.698 |
| 15-45 days | 18 | 0.581 | 0.815 | 0.872 | 0.833 |
| > 45 days | 2 | 0.000 | 1.000 | 0.600 | 0.750 |
| (reference: lasting topics) | 125 | 0.444 | 0.838 | 0.847 | 0.764 |

## 10. Abstention with the raw embedding similarity instead of the blended relevance

Detector = the maximum cosine between the query and any item of the persona's store, per model. Threshold τ is the 10th percentile of that value over answerable DEV queries (keeps 90% of them); reported on TEST personas.

| model | AUROC | τ (DEV) | TEST: answerable kept | TEST: unanswerable still recalled |
|---|---|---|---|---|
| nomic-v1.5 | 0.533 | 0.632 | 94% | 89% |
| bge-m3 | 0.690 | 0.543 | 90% | 75% |
| qwen3-emb-0.6b | 0.508 | 0.455 | 87% | 89% |

# Model comparison on the synthetic personal-memory benchmark

8 personas, 304 answerable queries, per-persona stores, real retriever. Two-stage bootstrap B = 4000. DEV personas p1,p3,p5,p7 select, TEST personas p2,p4,p6,p8 confirm.

## A. Embedding models alone (all personas)

| model | MRR@10 [95% CI] | R@1 | gold injected (top-6) | direct | paraphrase | cross-lingual | hard neg. | embed s |
|---|---|---|---|---|---|---|---|---|
| arctic-embed-l-v2 | 0.882 [0.837, 0.923] | 0.809 | 0.977 | 0.979 | 0.869 | 0.776 | 0.943 | 34 |
| embeddinggemma-300m | 0.871 [0.825, 0.911] | 0.793 | 0.987 | 0.951 | 0.881 | 0.754 | 0.926 | 19 |
| nomic-v2-moe | 0.845 [0.801, 0.888] | 0.757 | 0.967 | 0.944 | 0.821 | 0.725 | 0.936 | - |
| qwen3-emb-4b | 0.845 [0.799, 0.888] | 0.753 | 0.967 | 0.924 | 0.862 | 0.705 | 0.915 | - |
| bge-m3 | 0.828 [0.780, 0.874] | 0.724 | 0.970 | 0.956 | 0.773 | 0.705 | 0.936 | - |
| qwen3-emb-0.6b | 0.770 [0.720, 0.819] | 0.684 | 0.905 | 0.921 | 0.750 | 0.548 | 0.927 | - |
| e5-large-instruct | 0.728 [0.654, 0.806] | 0.609 | 0.918 | 0.940 | 0.754 | 0.399 | 0.894 | 34 |
| nomic-v1.5 | 0.550 [0.475, 0.624] | 0.474 | 0.664 | 0.924 | 0.552 | 0.047 | 0.816 | - |
| local-only | 0.440 [0.374, 0.511] | 0.382 | 0.523 | 0.884 | 0.243 | 0.065 | 0.775 | - |

## B. Does fusing profiles help? (selection on DEV, report on TEST)

Best single on DEV: **embeddinggemma-300m**; best fusion on DEV: **embeddinggemma-300m+arctic-embed-l-v2** (from 22 candidate fusions of the top models).

| config | TEST MRR@10 [95% CI] | TEST R@1 | TEST gold injected |
|---|---|---|---|
| embeddinggemma-300m | 0.841 [0.771, 0.899] | 0.750 | 0.980 |
| embeddinggemma-300m+arctic-embed-l-v2 | 0.867 [0.796, 0.927] | 0.783 | 0.980 |

Fusion minus best single on TEST: ΔMRR@10 +0.026 [-0.003, +0.060], p = 0.080.

Top fusions by DEV MRR: embeddinggemma-300m+arctic-embed-l-v2 (0.908), embeddinggemma-300m+arctic-embed-l-v2+nomic-v2-moe (0.904), embeddinggemma-300m+nomic-v2-moe+bge-m3 (0.903), embeddinggemma-300m+arctic-embed-l-v2+qwen3-emb-4b (0.902), arctic-embed-l-v2+qwen3-emb-4b+bge-m3 (0.901).

## C. Second-stage reranking (first stage: bge-m3+qwen3-emb-0.6b, top 20 candidates)

The correct item is among the first stage's top 20 for 98.7% of answerable queries (upper bound for any reranker).

| pipeline | MRR@10 [95% CI] | R@1 | gold in top-6 | ΔMRR vs first stage [95% CI] | p |
|---|---|---|---|---|---|
| bge-m3+qwen3-emb-0.6b (no reranker) | 0.817 [0.769, 0.863] | 0.724 | 0.947 | - | - |
| + bge-reranker-v2-m3, reranker only | 0.933 [0.899, 0.962] | 0.898 | 0.984 | +0.116 [+0.069, +0.166] | 0.0003 |
| + bge-reranker-v2-m3, reranker + first stage (RRF) | 0.875 [0.833, 0.913] | 0.799 | 0.974 | +0.058 [+0.036, +0.083] | 0.0003 |
| + qwen3-rerank-0.6b, reranker only | 0.843 [0.796, 0.888] | 0.753 | 0.967 | +0.026 [-0.022, +0.074] | 0.2757 |
| + qwen3-rerank-0.6b, reranker + first stage (RRF) | 0.844 [0.802, 0.885] | 0.760 | 0.970 | +0.027 [+0.002, +0.055] | 0.0338 |
| + qwen3-rerank-4b, reranker only | 0.952 [0.924, 0.975] | 0.924 | 0.987 | +0.135 [+0.088, +0.186] | 0.0003 |
| + qwen3-rerank-4b, reranker + first stage (RRF) | 0.883 [0.847, 0.916] | 0.809 | 0.987 | +0.066 [+0.040, +0.094] | 0.0003 |

MRR@10 by query type, bge-m3+qwen3-emb-0.6b vs + qwen3-rerank-4b (reranker only):

| type | first stage | + reranker |
|---|---|---|
| direct | 0.945 | 0.991 |
| paraphrase | 0.806 | 0.929 |
| cross_lingual | 0.643 | 0.935 |
| hard_negative | 0.925 | 0.972 |

**Abstention with the reranker's top score (first stage bge-m3+qwen3-emb-0.6b).** DEV personas choose τ (keeps 90% of answerable queries), TEST confirms; today the app injects 6 items for 100% of unanswerable queries.

| reranker | AUROC | τ | TEST: answerable kept | TEST: unanswerable still injected | latency per query (20 docs) |
|---|---|---|---|---|---|
| bge-reranker-v2-m3 | 0.764 | -6.39 | 91% | 75% | 202 ms |
| qwen3-rerank-0.6b | 0.654 | 0.06754 | 88% | 79% | 956 ms |
| qwen3-rerank-4b | 0.833 | 0.553 | 86% | 54% | 4646 ms |

## C. Second-stage reranking (first stage: embeddinggemma-300m+arctic-embed-l-v2, top 20 candidates)

The correct item is among the first stage's top 20 for 99.7% of answerable queries (upper bound for any reranker).

| pipeline | MRR@10 [95% CI] | R@1 | gold in top-6 | ΔMRR vs first stage [95% CI] | p |
|---|---|---|---|---|---|
| embeddinggemma-300m+arctic-embed-l-v2 (no reranker) | 0.887 [0.843, 0.924] | 0.812 | 0.993 | - | - |
| + bge-reranker-v2-m3, reranker only | 0.942 [0.913, 0.970] | 0.905 | 0.993 | +0.055 [+0.014, +0.101] | 0.0053 |
| + bge-reranker-v2-m3, reranker + first stage (RRF) | 0.914 [0.886, 0.942] | 0.852 | 0.997 | +0.027 [+0.003, +0.060] | 0.0208 |
| + qwen3-rerank-0.6b, reranker only | 0.853 [0.808, 0.897] | 0.763 | 0.980 | -0.035 [-0.072, +0.006] | 0.0897 |
| + qwen3-rerank-0.6b, reranker + first stage (RRF) | 0.896 [0.856, 0.932] | 0.832 | 0.993 | +0.008 [-0.015, +0.033] | 0.4482 |
| + qwen3-rerank-4b, reranker only | 0.964 [0.944, 0.982] | 0.938 | 0.997 | +0.077 [+0.039, +0.122] | 0.0003 |
| + qwen3-rerank-4b, reranker + first stage (RRF) | 0.925 [0.896, 0.950] | 0.862 | 0.997 | +0.037 [+0.015, +0.068] | 0.0003 |

MRR@10 by query type, embeddinggemma-300m+arctic-embed-l-v2 vs + qwen3-rerank-4b (reranker only):

| type | first stage | + reranker |
|---|---|---|
| direct | 0.966 | 0.991 |
| paraphrase | 0.891 | 0.936 |
| cross_lingual | 0.783 | 0.960 |
| hard_negative | 0.938 | 0.986 |

**Abstention with the reranker's top score (first stage embeddinggemma-300m+arctic-embed-l-v2).** DEV personas choose τ (keeps 90% of answerable queries), TEST confirms; today the app injects 6 items for 100% of unanswerable queries.

| reranker | AUROC | τ | TEST: answerable kept | TEST: unanswerable still injected | latency per query (20 docs) |
|---|---|---|---|---|---|
| bge-reranker-v2-m3 | 0.769 | -6.312 | 91% | 71% | 192 ms |
| qwen3-rerank-0.6b | 0.659 | 0.07381 | 87% | 75% | 633 ms |
| qwen3-rerank-4b | 0.840 | 0.6394 | 84% | 50% | 4318 ms |

## E. Do query/document prefixes matter? (single model, formatted vs raw text, all personas)

| model | formatted MRR@10 | raw MRR@10 | ΔMRR@10 [95% CI] | p |
|---|---|---|---|---|
| embeddinggemma-300m | 0.871 | 0.799 | +0.073 [+0.037, +0.112] | 0.0003 |
| arctic-embed-l-v2 | 0.882 | 0.818 | +0.065 [+0.036, +0.099] | 0.0003 |
| e5-large-instruct | 0.728 | 0.673 | +0.055 [+0.017, +0.091] | 0.0043 |
| qwen3-emb-0.6b | 0.770 | 0.736 | +0.035 [-0.001, +0.074] | 0.0597 |
| nomic-v2-moe | 0.845 | 0.836 | +0.010 [-0.016, +0.036] | 0.4597 |
| nomic-v1.5 | 0.550 | 0.542 | +0.008 [-0.010, +0.025] | 0.3622 |

## F. Matryoshka truncation: smaller vectors, same model (all personas)

| model | dims | vector bytes per item (float32) | MRR@10 [95% CI] | ΔMRR vs full |
|---|---|---|---|---|
| embeddinggemma-300m | 768 | 3072 | 0.871 [0.825, 0.911] | - |
| embeddinggemma-300m | 512 | 2048 | 0.853 [0.808, 0.895] | -0.018 [-0.038, -0.002] |
| embeddinggemma-300m | 256 | 1024 | 0.820 [0.766, 0.874] | -0.051 [-0.086, -0.022] |
| embeddinggemma-300m | 128 | 512 | 0.800 [0.747, 0.849] | -0.072 [-0.105, -0.041] |
| arctic-embed-l-v2 | 1024 | 4096 | 0.882 [0.837, 0.923] | - |
| arctic-embed-l-v2 | 512 | 2048 | 0.879 [0.836, 0.920] | -0.004 [-0.019, +0.011] |
| arctic-embed-l-v2 | 256 | 1024 | 0.875 [0.834, 0.915] | -0.007 [-0.018, +0.003] |
| arctic-embed-l-v2 | 128 | 512 | 0.853 [0.809, 0.898] | -0.029 [-0.056, -0.002] |

## G. Ladder: from lexical search to the best pipeline (all personas)

| stage | MRR@10 [95% CI] | R@1 |
|---|---|---|
| lexical only (no embedding model) | 0.440 [0.374, 0.511] | 0.382 |
| nomic-embed v1.5 (the Tinfoil preset's default model) | 0.550 [0.475, 0.624] | 0.474 |
| bge-m3 + Qwen3-0.6B fused (earlier setup) | 0.817 [0.769, 0.863] | 0.724 |
| best single embedding: arctic-embed-l-v2 | 0.882 [0.837, 0.923] | 0.809 |
| best fusion (DEV): embeddinggemma-300m+arctic-embed-l-v2 | 0.887 [0.843, 0.924] | 0.812 |
| + bge-reranker-v2-m3 reranker | 0.942 [0.913, 0.970] | 0.905 |
| + qwen3-rerank-4b reranker | 0.964 [0.944, 0.982] | 0.938 |

# Hosted models, rerankers and LLM judges

Synthetic personal-memory benchmark, 304 answerable queries, per-persona stores, real retriever. Two-stage bootstrap B = 4000.

## 1. Every embedding model (alone, all personas)

| model | where | MRR@10 [95% CI] | R@1 | gold injected | cross-lingual MRR |
|---|---|---|---|---|---|
| voyage-4-large | hosted | 0.950 [0.922, 0.974] | 0.908 | 0.997 | 0.925 |
| di-nemotron-embed-8b-qp | hosted | 0.924 [0.892, 0.951] | 0.868 | 0.993 | 0.877 |
| voyage-4 | hosted | 0.923 [0.889, 0.954] | 0.859 | 0.997 | 0.874 |
| or-pplx-embed-4b | hosted | 0.905 [0.868, 0.939] | 0.839 | 0.990 | 0.861 |
| voyage-4-lite | hosted | 0.903 [0.869, 0.934] | 0.836 | 0.993 | 0.816 |
| arctic-embed-l-v2 | local Q8 | 0.882 [0.838, 0.922] | 0.809 | 0.977 | 0.776 |
| di-qwen3-emb-8b | hosted | 0.875 [0.831, 0.914] | 0.799 | 0.984 | 0.739 |
| di-embeddinggemma-300m | hosted | 0.873 [0.826, 0.911] | 0.796 | 0.987 | 0.761 |
| embeddinggemma-300m | local Q8 | 0.871 [0.826, 0.908] | 0.793 | 0.987 | 0.754 |
| or-gemini-embedding-2 | hosted | 0.870 [0.831, 0.909] | 0.773 | 0.987 | 0.795 |
| voyage-3-large | hosted | 0.867 [0.824, 0.907] | 0.780 | 0.987 | 0.771 |
| openai-3-large | hosted | 0.866 [0.820, 0.907] | 0.776 | 0.977 | 0.695 |
| cohere-embed-v4 | hosted | 0.856 [0.813, 0.897] | 0.783 | 0.954 | 0.684 |
| di-nemotron-embed-8b | hosted | 0.854 [0.809, 0.894] | 0.773 | 0.967 | 0.739 |
| or-gemini-embedding-001 | hosted | 0.849 [0.805, 0.889] | 0.757 | 0.980 | 0.701 |
| nomic-v2-moe | local Q8 | 0.845 [0.800, 0.887] | 0.757 | 0.967 | 0.725 |
| qwen3-emb-4b | local Q8 | 0.845 [0.800, 0.886] | 0.753 | 0.967 | 0.705 |
| bge-m3 | local Q8 | 0.828 [0.779, 0.872] | 0.724 | 0.970 | 0.705 |
| di-bge-m3 | hosted | 0.828 [0.779, 0.872] | 0.724 | 0.970 | 0.699 |
| di-embeddinggemma-2 | hosted | 0.773 [0.714, 0.829] | 0.645 | 0.957 | 0.581 |
| qwen3-emb-0.6b | local Q8 | 0.770 [0.719, 0.817] | 0.684 | 0.905 | 0.548 |
| openai-3-small | hosted | 0.760 [0.706, 0.809] | 0.658 | 0.898 | 0.469 |
| e5-large-instruct | local Q8 | 0.728 [0.654, 0.803] | 0.609 | 0.918 | 0.399 |
| or-mistral-embed | hosted | 0.636 [0.569, 0.702] | 0.530 | 0.809 | 0.189 |
| nomic-v1.5 | local Q8 | 0.550 [0.477, 0.621] | 0.474 | 0.664 | 0.047 |
| local-only | baseline | 0.440 [0.373, 0.508] | 0.382 | 0.523 | 0.065 |

Same model, local 8-bit GGUF vs hosted full precision: bge-m3 0.828 vs di-bge-m3 0.828; embeddinggemma-300m 0.871 vs di-embeddinggemma-300m 0.873.
Nemotron-Embed-8B with `query:`/`passage:` prefixes 0.924 vs raw 0.854 (Δ +0.069).

## 2. Rerankers on top of voyage-4-large (top 20)

The correct item is inside the first stage's top 20 for 100.0% of answerable queries.

| reranker | MRR@10 [95% CI] | R@1 | gold in top-6 | ΔMRR vs first stage | abstention AUROC | s / query |
|---|---|---|---|---|---|---|
| voyage-4-large alone | 0.950 [0.922, 0.974] | 0.908 | 1.000 | - | - | - |
| voyage-rerank-2.5 | 0.995 [0.983, 1.000] | 0.990 | 1.000 | +0.045 [+0.020, +0.074] | 0.938 | 0.30 |
| di-nemotron-rerank-8b | 0.982 [0.964, 0.995] | 0.967 | 1.000 | +0.033 [+0.012, +0.058] | 0.834 | 0.65 |
| cohere-rerank-v4-pro | 0.981 [0.965, 0.993] | 0.964 | 1.000 | +0.031 [+0.003, +0.063] | 0.882 | - |
| di-qwen3-rerank-8b | 0.980 [0.963, 0.993] | 0.961 | 1.000 | +0.030 [+0.002, +0.061] | 0.898 | 0.58 |
| voyage-rerank-2.5-lite | 0.974 [0.950, 0.992] | 0.951 | 0.997 | +0.024 [-0.005, +0.056] | 0.821 | 0.29 |
| di-qwen3-rerank-4b | 0.970 [0.951, 0.985] | 0.944 | 1.000 | +0.020 [-0.006, +0.049] | 0.811 | 0.86 |
| cohere-rerank-v3.5 | 0.968 [0.949, 0.985] | 0.941 | 1.000 | +0.018 [-0.007, +0.045] | 0.793 | - |
| di-qwen3-rerank-0.6b | 0.862 [0.823, 0.896] | 0.763 | 0.993 | -0.088 [-0.127, -0.049] | 0.645 | 0.66 |

## 3B. LLM judge, setting B (candidates = top 20 of voyage-4-large)

First attempt only, provider errors excluded (they are not model output). Strict = the app's previous decoder (any deviation rejects the whole answer); tolerant = the new decoder (first JSON value, bare arrays accepted, unknown IDs and confidence < 0.75 dropped, answers made only of invented IDs still rejected). Rejected answers fall back to ordinary ranking in the app and are left out of the two right-hand rates. Because rejected stored answers keep only their first 400 characters, tolerant validity is a lower bound.

| model | answers scored | strict valid | tolerant valid | answer selected (tolerant) | mean items | unanswerable: anything selected [95% Wilson] | answer in candidates | $ / 1k queries | s / query |
|---|---|---|---|---|---|---|---|---|---|
| oa_gpt-6-luna | 360 | 100.0% | 100.0% | 1.000 | 0.93 | 30% [20%, 43%] (17/56) | 1.000 | 0.14 | 2.1 |
| oa_gpt-6.1-sol | 360 | 100.0% | 100.0% | 1.000 | 0.98 | 21% [13%, 34%] (12/56) | 1.000 | 2.44 | 2.2 |
| or_anthropic_claude-haiku-5.5 | 360 | 100.0% | 100.0% | 0.993 | 1.09 | 32% [21%, 45%] (18/56) | 1.000 | 0.25 | 1.7 |
| or_anthropic_claude-sonnet-5.5 | 360 | 78.6% | 98.3% | 0.997 | 1.05 | 48% [35%, 61%] (26/54) | 1.000 | 3.80 | 1.7 |
| or_google_gemini-3.8-flash | 360 | 100.0% | 100.0% | 1.000 | 1.05 | 23% [14%, 36%] (13/56) | 1.000 | 1.44 | 4.4 |
| or_qwen_qwen3.8-flash | 359 | 97.5% | 100.0% | 1.000 | 1.01 | 30% [20%, 43%] (17/56) | 1.000 | 0.19 | 2.5 |

## 3A. LLM judge, setting A (the app's old pool: first 40 of the local lexical ranking)

First attempt only, provider errors excluded (they are not model output). Strict = the app's previous decoder (any deviation rejects the whole answer); tolerant = the new decoder (first JSON value, bare arrays accepted, unknown IDs and confidence < 0.75 dropped, answers made only of invented IDs still rejected). Rejected answers fall back to ordinary ranking in the app and are left out of the two right-hand rates. Because rejected stored answers keep only their first 400 characters, tolerant validity is a lower bound.

| model | answers scored | strict valid | tolerant valid | answer selected (tolerant) | mean items | unanswerable: anything selected [95% Wilson] | answer in candidates | $ / 1k queries | s / query |
|---|---|---|---|---|---|---|---|---|---|
| oa_gpt-6-luna | 360 | 99.4% | 99.4% | 0.808 | 0.81 | 38% [26%, 51%] (21/56) | 0.812 | 0.31 | 3.2 |
| oa_gpt-6.1-sol | 360 | 99.7% | 100.0% | 0.812 | 0.85 | 23% [14%, 36%] (13/56) | 0.812 | 5.78 | 2.3 |
| or_anthropic_claude-haiku-5.5 | 360 | 100.0% | 100.0% | 0.809 | 0.89 | 18% [10%, 30%] (10/56) | 0.812 | 0.51 | 1.8 |
| or_anthropic_claude-sonnet-5.5 | 276 | 76.8% | 97.1% | 0.792 | 0.92 | 41% [26%, 57%] (15/37) | 0.795 | 8.92 | 2.0 |
| or_google_gemini-3.8-flash | 360 | 100.0% | 100.0% | 0.812 | 0.88 | 11% [5%, 21%] (6/56) | 0.812 | 2.55 | 4.0 |
| or_qwen_qwen3.8-flash | 360 | 93.6% | 99.4% | 0.812 | 0.85 | 24% [14%, 36%] (13/55) | 0.812 | 0.48 | 3.3 |

## 4. When nothing answers: injecting less without losing the answer

Real retriever, candidates = top 20 of voyage-4-large. A cross-encoder keeps candidates above a probability threshold τ and injects at most six; an LLM judge selects the IDs that help (Smart memory prompt, setting B, tolerant decoding). x = share of unanswerable queries where anything is injected (lower is better), y = share of answerable queries whose answer is injected.

| method | τ | gold injected (answerable) | anything injected (unanswerable) | mean items (unanswerable) |
|---|---|---|---|---|
| cohere-rerank-v3.5 | 0 | 1.000 | 100% | 5.9 |
| cohere-rerank-v3.5 | 0.5 | 0.507 | 12% | 0.1 |
| cohere-rerank-v4-pro | 0 | 1.000 | 100% | 5.9 |
| cohere-rerank-v4-pro | 0.01 | 1.000 | 100% | 5.9 |
| cohere-rerank-v4-pro | 0.05 | 1.000 | 100% | 5.9 |
| cohere-rerank-v4-pro | 0.1 | 1.000 | 100% | 5.9 |
| cohere-rerank-v4-pro | 0.2 | 1.000 | 100% | 5.5 |
| cohere-rerank-v4-pro | 0.3 | 1.000 | 95% | 4.4 |
| cohere-rerank-v4-pro | 0.5 | 0.990 | 79% | 1.8 |
| cohere-rerank-v4-pro | 0.7 | 0.931 | 39% | 0.5 |
| cohere-rerank-v4-pro | 0.9 | 0.553 | 11% | 0.1 |
| di-qwen3-rerank-4b | 0 | 1.000 | 100% | 5.9 |
| di-qwen3-rerank-4b | 0.5 | 0.908 | 62% | 1.0 |
| di-qwen3-rerank-8b | 0 | 1.000 | 100% | 5.9 |
| di-qwen3-rerank-8b | 0.1 | 0.977 | 66% | 1.2 |
| di-qwen3-rerank-8b | 0.3 | 0.947 | 48% | 0.8 |
| di-qwen3-rerank-8b | 0.5 | 0.921 | 41% | 0.5 |
| di-qwen3-rerank-8b | 0.7 | 0.895 | 32% | 0.4 |
| di-qwen3-rerank-8b | 0.9 | 0.799 | 20% | 0.2 |
| voyage-rerank-2.5-lite | 0 | 0.997 | 100% | 5.9 |
| voyage-rerank-2.5-lite | 0.5 | 0.885 | 52% | 0.7 |
| voyage-rerank-2.5 | 0 | 1.000 | 100% | 5.9 |
| voyage-rerank-2.5 | 0.1 | 1.000 | 100% | 5.9 |
| voyage-rerank-2.5 | 0.2 | 1.000 | 100% | 5.9 |
| voyage-rerank-2.5 | 0.3 | 1.000 | 100% | 4.8 |
| voyage-rerank-2.5 | 0.4 | 1.000 | 95% | 2.1 |
| voyage-rerank-2.5 | 0.5 | 0.954 | 43% | 0.5 |
| LLM judge: oa_gpt-6-luna | - | 1.000 | 30% | - |
| LLM judge: oa_gpt-6.1-sol | - | 1.000 | 21% | - |
| LLM judge: or_anthropic_claude-haiku-5.5 | - | 0.993 | 32% | - |
| LLM judge: or_anthropic_claude-sonnet-5.5 | - | 0.997 | 48% | - |
| LLM judge: or_google_gemini-3.8-flash | - | 1.000 | 23% | - |
| LLM judge: or_qwen_qwen3.8-flash | - | 1.000 | 30% | - |

# Reranked pipelines through the real retriever

First stage: embeddinggemma-300m + arctic-embed-l-v2 (reciprocal-rank fusion), top 20. The reranker's probability picks the injected items (`HybridMemoryRetriever.select`, default limits: 6 items, 2 per container); candidates below tau are dropped. `blend:` feeds the reranker through the blended semantic term instead.

| pipeline | MRR@10 | R@1 | gold injected (answerable) | anything injected (unanswerable) | mean items (unanswerable) | utility |
|---|---|---|---|---|---|---|
| embeddinggemma-300m+arctic-embed-l-v2 | 0.887 | 0.812 | 0.990 | 100% | 6.0 | -0.010 |
| local-only | 0.440 | 0.382 | 0.523 | 98% | 5.4 | -0.459 |
| blend:embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-4b@embeddinggemma-300m+arctic-embed-l-v2~0 | 0.907 | 0.882 | 0.941 | 98% | 5.4 | -0.041 |
| embeddinggemma-300m+arctic-embed-l-v2>>bge-reranker-v2-m3@embeddinggemma-300m+arctic-embed-l-v2~0 | 0.942 | 0.905 | 0.990 | 100% | 6.0 | -0.010 |
| embeddinggemma-300m+arctic-embed-l-v2>>bge-reranker-v2-m3@embeddinggemma-300m+arctic-embed-l-v2~0.0005 | 0.922 | 0.888 | 0.964 | 88% | 2.1 | +0.089 |
| embeddinggemma-300m+arctic-embed-l-v2>>bge-reranker-v2-m3@embeddinggemma-300m+arctic-embed-l-v2~0.001 | 0.900 | 0.875 | 0.931 | 84% | 1.8 | +0.092 |
| embeddinggemma-300m+arctic-embed-l-v2>>bge-reranker-v2-m3@embeddinggemma-300m+arctic-embed-l-v2~0.01 | 0.757 | 0.747 | 0.770 | 45% | 0.5 | +0.323 |
| embeddinggemma-300m+arctic-embed-l-v2>>bge-reranker-v2-m3@embeddinggemma-300m+arctic-embed-l-v2~0.1 | 0.606 | 0.602 | 0.612 | 18% | 0.2 | +0.433 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-0.6b@embeddinggemma-300m+arctic-embed-l-v2~0 | 0.853 | 0.763 | 0.977 | 100% | 6.0 | -0.023 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-0.6b@embeddinggemma-300m+arctic-embed-l-v2~0.1 | 0.742 | 0.697 | 0.799 | 77% | 1.8 | +0.031 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-0.6b@embeddinggemma-300m+arctic-embed-l-v2~0.3 | 0.705 | 0.668 | 0.753 | 70% | 1.4 | +0.057 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-4b@embeddinggemma-300m+arctic-embed-l-v2~0 | 0.964 | 0.938 | 0.997 | 100% | 6.0 | -0.003 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-4b@embeddinggemma-300m+arctic-embed-l-v2~0.1 | 0.938 | 0.918 | 0.961 | 75% | 1.5 | +0.211 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-4b@embeddinggemma-300m+arctic-embed-l-v2~0.3 | 0.904 | 0.885 | 0.924 | 62% | 1.0 | +0.299 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-4b@embeddinggemma-300m+arctic-embed-l-v2~0.5 | 0.871 | 0.852 | 0.891 | 57% | 0.8 | +0.320 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-4b@embeddinggemma-300m+arctic-embed-l-v2~0.7 | 0.831 | 0.819 | 0.845 | 46% | 0.5 | +0.381 |
| embeddinggemma-300m+arctic-embed-l-v2>>qwen3-rerank-4b@embeddinggemma-300m+arctic-embed-l-v2~0.9 | 0.762 | 0.753 | 0.773 | 27% | 0.3 | +0.505 |

## Threshold chosen on DEV personas, confirmed on TEST personas

| reranker | tau (DEV) | TEST: gold injected, tau = 0 | TEST: gold injected, tau* | TEST: unanswerable injected, tau = 0 | TEST: unanswerable injected, tau* | TEST MRR@10 tau* |
|---|---|---|---|---|---|---|
| bge-reranker-v2-m3 | 0.1 | 0.987 | 0.592 | 100% | 18% | 0.580 |
| qwen3-rerank-0.6b | 0.1 | 0.987 | 0.816 | 100% | 75% | 0.731 |
| qwen3-rerank-4b | 0.9 | 0.993 | 0.757 | 100% | 29% | 0.742 |

# Event fade policy sweep

Config: bge-m3+qwen3-emb-0.6b. Events shifted older by [0, 30, 90, 365] days (counterfactual aging). Event-answer queries: 77 (DEV 35, TEST 42); other answerable queries: 227.

Selection on DEV personas (p1,p3,p5,p7): maximise mean event-query MRR over the four shifts, subject to the other-query MRR (mean over shifts) not dropping more than 0.01 below the legacy policy. Reported on TEST personas (p2,p4,p6,p8).

| policy | event MRR DEV (mean of shifts) | other MRR DEV | guardrail | TEST event MRR +0d | TEST event MRR +30d | TEST event MRR +90d | TEST event MRR +365d | TEST other MRR |
|---|---|---|---|---|---|---|---|---|
| 14d/floor 1 | 0.904 | 0.830 | FAIL | 0.881 | 0.876 | 0.872 | 0.866 | 0.769 |
| 45d/floor 1 | 0.904 | 0.830 | FAIL | 0.881 | 0.876 | 0.872 | 0.866 | 0.769 |
| 180d/floor 1 | 0.904 | 0.830 | FAIL | 0.881 | 0.876 | 0.872 | 0.866 | 0.769 |
| 45d/floor 0.4 + shield top-3 @0.85 ◀ chosen | 0.823 | 0.843 | ok | 0.826 | 0.789 | 0.785 | 0.748 | 0.783 |
| 14d/floor 0.15 + shield top-3 @0.85 | 0.818 | 0.843 | ok | 0.793 | 0.789 | 0.785 | 0.748 | 0.785 |
| 14d/floor 0.15 + shield top-5 @0.85 | 0.818 | 0.843 | ok | 0.793 | 0.789 | 0.785 | 0.752 | 0.785 |
| 14d/floor 0.15 + shield top-1 @0.85 | 0.815 | 0.844 | ok | 0.761 | 0.746 | 0.746 | 0.718 | 0.787 |
| 180d/floor 0.7 | 0.714 | 0.840 | ok | 0.870 | 0.760 | 0.532 | 0.506 | 0.786 |
| 45d/floor 0.7 | 0.637 | 0.843 | ok | 0.757 | 0.548 | 0.532 | 0.506 | 0.791 |
| 14d/floor 0.7 | 0.616 | 0.844 | ok | 0.596 | 0.548 | 0.532 | 0.506 | 0.794 |
| 14d/floor 0.15 + shield top-3 @0.7 | 0.616 | 0.844 | ok | 0.596 | 0.548 | 0.532 | 0.506 | 0.794 |
| 180d/floor 0.4 | 0.587 | 0.841 | ok | 0.870 | 0.760 | 0.519 | 0.083 | 0.786 |
| 180d/floor 0.15 | 0.573 | 0.841 | ok | 0.870 | 0.760 | 0.519 | 0.022 | 0.786 |
| 45d/floor 0.4 | 0.325 | 0.844 | ok | 0.752 | 0.272 | 0.088 | 0.083 | 0.791 |
| 45d/floor 0.15 | 0.295 | 0.844 | ok | 0.752 | 0.272 | 0.022 | 0.022 | 0.791 |
| 14d/floor 0.4 | 0.197 | 0.845 | ok | 0.463 | 0.089 | 0.088 | 0.083 | 0.794 |
| legacy 14d/floor .15 | 0.148 | 0.845 | ok | 0.454 | 0.022 | 0.022 | 0.022 | 0.794 |

Chosen on DEV: **45d/floor 0.4 + shield top-3 @0.85** (spec `45:0.4:3:0.85`).

## Chosen policy vs legacy and vs no fade, TEST personas, paired (two-stage bootstrap over 4 personas, so intervals are wide)

| subset | chosen − legacy ΔMRR [95% CI] | chosen − no fade ΔMRR [95% CI] |
|---|---|---|
| event answers, events aged +0d | +0.372 [+0.254, +0.507] | -0.055 [-0.107, -0.010] |
| event answers, events aged +30d | +0.767 [+0.651, +0.889] | -0.087 [-0.154, -0.019] |
| event answers, events aged +90d | +0.763 [+0.650, +0.880] | -0.087 [-0.148, -0.027] |
| event answers, events aged +365d | +0.726 [+0.601, +0.864] | -0.117 [-0.195, -0.034] |
| other answers, events aged +0d | -0.013 [-0.036, -0.001] | +0.007 [+0.000, +0.024] |
| other answers, events aged +365d | -0.007 [-0.025, +0.000] | +0.019 [+0.002, +0.043] |

# Blind re-annotation audit

Four independent annotator agents saw each persona's store and queries with no labels and no query types.

* Exact agreement on the answering item: **360/360 = 100.0%**
* Answerable queries: 304/304 = 100.0% agree; unanswerable: 56/56 = 100.0% agree
* Cohen's kappa on answerable-vs-unanswerable: 1.000

| query type | n | agreement |
|---|---|---|
| direct | 56 | 100.0% |
| paraphrase | 96 | 100.0% |
| cross_lingual | 80 | 100.0% |
| hard_negative | 72 | 100.0% |
| unanswerable | 56 | 100.0% |

Disagreements by kind: {}


# Dataset QC

8 personas, 560 items, 360 queries, 0 validation errors.

| persona | items | queries | topics | events | messages | documents | never-gold items |
|---|---|---|---|---|---|---|---|
| p1 | 73 | 45 | 21 | 13 | 29 | 10 | 35 (48%) |
| p2 | 73 | 45 | 22 | 13 | 28 | 10 | 35 (48%) |
| p3 | 71 | 45 | 23 | 13 | 25 | 10 | 37 (52%) |
| p4 | 71 | 45 | 23 | 13 | 25 | 10 | 35 (49%) |
| p5 | 69 | 45 | 22 | 12 | 25 | 10 | 31 (45%) |
| p6 | 69 | 45 | 22 | 12 | 25 | 10 | 31 (45%) |
| p7 | 67 | 45 | 20 | 12 | 25 | 10 | 29 (43%) |
| p8 | 67 | 45 | 20 | 12 | 25 | 10 | 29 (43%) |

| query type | n | tr | en | mean Jaccard(query, gold) | share with >=2 shared stems | share with 0 shared stems |
|---|---|---|---|---|---|---|
| direct | 56 | 27 | 29 | 0.211 | 95% | 0% |
| paraphrase | 96 | 50 | 46 | 0.033 | 11% | 51% |
| cross_lingual | 80 | 39 | 41 | 0.015 | 8% | 81% |
| hard_negative | 72 | 43 | 29 | 0.182 | 76% | 10% |
| unanswerable | 56 | 32 | 24 | n/a | n/a | n/a |

Item languages: {'tr': 285, 'en': 222, 'mixed': 53}. Gold-item kinds: {'message': 55, 'event': 77, 'topic': 125, 'document': 47}.
