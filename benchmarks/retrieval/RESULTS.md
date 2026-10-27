# Retrieval benchmark results

XQuAD, 1190 parallel Turkish/English questions over 240 Wikipedia paragraphs per language. Retriever = the app's real `HybridMemoryRetriever` (local BM25 + hash + concept scoring, reciprocal-rank fusion with k = 60, per-profile weights, relevance gates). Cluster bootstrap B = 10000 over gold paragraphs.

## 1. Configuration selection (DEV half: even-indexed paragraphs)

| config | macro-MRR@10 (DEV) |
|---|---|
| bge-m3 | 0.955 ← best single |
| bge-m3+qwen3-emb-0.6b | 0.954 ← best fusion |
| nomic-v1.5*0.1+bge-m3+qwen3-emb-0.6b | 0.953 |
| nomic-v1.5*0.25+bge-m3+qwen3-emb-0.6b | 0.951 |
| nomic-v1.5*0.5+bge-m3+qwen3-emb-0.6b | 0.947 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.936 |
| qwen3-emb-0.6b | 0.928 |
| nomic-v1.5+bge-m3 | 0.896 |
| nomic-v1.5+qwen3-emb-0.6b | 0.872 |
| nomic-v1.5 | 0.766 |
| local-only | 0.736 |

## 2. Held-out TEST half (596 questions per setting)


### en->en  (240 candidates)

| config | MRR@10 [95% CI] | R@1 | R@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| local-only | 0.954 [0.936, 0.970] | 0.926 | 0.988 | 0.993 | 0.964 |
| bge-m3 | 0.982 [0.971, 0.991] | 0.968 | 0.998 | 1.000 | 0.986 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.987 [0.979, 0.994] | 0.978 | 1.000 | 1.000 | 0.991 |
| bge-m3+qwen3-emb-0.6b | 0.987 [0.979, 0.994] | 0.978 | 1.000 | 1.000 | 0.991 |

| paired comparison (ΔMRR@10) | Δ [95% CI] | p |
|---|---|---|
| bge-m3+qwen3-emb-0.6b vs bge-m3 | +0.006 [+0.001, +0.012] | 0.0340 |
| bge-m3+qwen3-emb-0.6b vs local-only | +0.034 [+0.019, +0.049] | 0.0002 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3 | +0.006 [+0.001, +0.012] | 0.0583 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3+qwen3-emb-0.6b | +0.000 [-0.003, +0.002] | 1.0000 |

### en->mixed  (480 candidates)

| config | MRR@10 [95% CI] | R@1 | R@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| local-only | 0.939 [0.918, 0.958] | 0.904 | 0.983 | 0.990 | 0.952 |
| bge-m3 | 0.980 [0.969, 0.990] | 0.968 | 0.997 | 1.000 | 0.985 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.986 [0.977, 0.994] | 0.977 | 0.998 | 1.000 | 0.990 |
| bge-m3+qwen3-emb-0.6b | 0.985 [0.976, 0.993] | 0.975 | 0.998 | 1.000 | 0.989 |

| paired comparison (ΔMRR@10) | Δ [95% CI] | p |
|---|---|---|
| bge-m3+qwen3-emb-0.6b vs bge-m3 | +0.005 [-0.001, +0.012] | 0.1249 |
| bge-m3+qwen3-emb-0.6b vs local-only | +0.046 [+0.028, +0.065] | 0.0001 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3 | +0.006 [+0.001, +0.013] | 0.0369 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3+qwen3-emb-0.6b | +0.001 [+0.000, +0.003] | 0.2529 |

### en->tr  (240 candidates)

| config | MRR@10 [95% CI] | R@1 | R@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| local-only | 0.287 [0.233, 0.342] | 0.221 | 0.383 | 0.414 | 0.318 |
| bge-m3 | 0.894 [0.863, 0.921] | 0.829 | 0.975 | 0.997 | 0.919 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.855 [0.818, 0.890] | 0.767 | 0.975 | 0.993 | 0.890 |
| bge-m3+qwen3-emb-0.6b | 0.919 [0.894, 0.941] | 0.864 | 0.983 | 0.995 | 0.938 |

| paired comparison (ΔMRR@10) | Δ [95% CI] | p |
|---|---|---|
| bge-m3+qwen3-emb-0.6b vs bge-m3 | +0.025 [+0.009, +0.042] | 0.0025 |
| bge-m3+qwen3-emb-0.6b vs local-only | +0.632 [+0.577, +0.685] | 0.0001 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.038 [-0.061, -0.017] | 0.0005 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3+qwen3-emb-0.6b | -0.063 [-0.088, -0.041] | 0.0001 |

### tr->en  (240 candidates)

| config | MRR@10 [95% CI] | R@1 | R@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| local-only | 0.319 [0.263, 0.375] | 0.270 | 0.398 | 0.406 | 0.341 |
| bge-m3 | 0.914 [0.887, 0.937] | 0.861 | 0.983 | 0.992 | 0.933 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.825 [0.789, 0.859] | 0.740 | 0.946 | 0.977 | 0.862 |
| bge-m3+qwen3-emb-0.6b | 0.891 [0.863, 0.919] | 0.839 | 0.965 | 0.985 | 0.914 |

| paired comparison (ΔMRR@10) | Δ [95% CI] | p |
|---|---|---|
| bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.022 [-0.040, -0.005] | 0.0167 |
| bge-m3+qwen3-emb-0.6b vs local-only | +0.572 [+0.518, +0.626] | 0.0001 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.089 [-0.117, -0.064] | 0.0001 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3+qwen3-emb-0.6b | -0.067 [-0.090, -0.046] | 0.0001 |

### tr->mixed  (480 candidates)

| config | MRR@10 [95% CI] | R@1 | R@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| local-only | 0.897 [0.867, 0.924] | 0.859 | 0.945 | 0.963 | 0.913 |
| bge-m3 | 0.964 [0.948, 0.979] | 0.943 | 0.988 | 0.998 | 0.973 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.952 [0.932, 0.971] | 0.926 | 0.985 | 0.995 | 0.963 |
| bge-m3+qwen3-emb-0.6b | 0.959 [0.940, 0.975] | 0.936 | 0.988 | 0.995 | 0.968 |

| paired comparison (ΔMRR@10) | Δ [95% CI] | p |
|---|---|---|
| bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.006 [-0.014, +0.003] | 0.1808 |
| bge-m3+qwen3-emb-0.6b vs local-only | +0.062 [+0.038, +0.089] | 0.0001 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.012 [-0.020, -0.004] | 0.0045 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3+qwen3-emb-0.6b | -0.006 [-0.012, -0.000] | 0.0607 |

### tr->tr  (240 candidates)

| config | MRR@10 [95% CI] | R@1 | R@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| local-only | 0.900 [0.870, 0.928] | 0.859 | 0.955 | 0.970 | 0.917 |
| bge-m3 | 0.967 [0.952, 0.980] | 0.946 | 0.992 | 0.998 | 0.975 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.948 [0.927, 0.966] | 0.916 | 0.985 | 0.997 | 0.960 |
| bge-m3+qwen3-emb-0.6b | 0.961 [0.943, 0.977] | 0.938 | 0.993 | 0.998 | 0.970 |

| paired comparison (ΔMRR@10) | Δ [95% CI] | p |
|---|---|---|
| bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.006 [-0.013, +0.002] | 0.1300 |
| bge-m3+qwen3-emb-0.6b vs local-only | +0.061 [+0.037, +0.087] | 0.0001 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.019 [-0.031, -0.009] | 0.0004 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3+qwen3-emb-0.6b | -0.013 [-0.022, -0.005] | 0.0017 |

## 3. Aggregate over the six settings (TEST)

| config | macro-MRR@10 | worst-setting MRR@10 | macro-R@1 |
|---|---|---|---|
| bge-m3+qwen3-emb-0.6b ◀ selected on DEV | 0.950 | 0.891 | 0.922 |
| bge-m3 ◀ selected on DEV | 0.950 | 0.894 | 0.919 |
| nomic-v1.5*0.1+bge-m3+qwen3-emb-0.6b | 0.950 | 0.890 | 0.921 |
| nomic-v1.5*0.25+bge-m3+qwen3-emb-0.6b | 0.948 | 0.888 | 0.918 |
| nomic-v1.5*0.5+bge-m3+qwen3-emb-0.6b | 0.943 | 0.876 | 0.910 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.926 | 0.825 | 0.884 |
| qwen3-emb-0.6b | 0.921 | 0.800 | 0.880 |
| nomic-v1.5+bge-m3 | 0.887 | 0.729 | 0.831 |
| nomic-v1.5+qwen3-emb-0.6b | 0.858 | 0.621 | 0.801 |
| nomic-v1.5 | 0.745 | 0.378 | 0.692 |
| local-only | 0.716 | 0.287 | 0.673 |

Pooled over 6 settings (3576 query-setting pairs, 120 paragraph clusters):

| comparison | ΔMRR@10 [95% CI] | p |
|---|---|---|
| bge-m3+qwen3-emb-0.6b vs bge-m3 | +0.000 [-0.006, +0.007] | 0.9160 |
| bge-m3+qwen3-emb-0.6b vs local-only | +0.234 [+0.213, +0.255] | 0.0001 |
| bge-m3 vs local-only | +0.234 [+0.214, +0.254] | 0.0001 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs bge-m3 | -0.024 [-0.032, -0.017] | 0.0001 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b vs local-only | +0.210 [+0.190, +0.229] | 0.0001 |

Relative reduction of macro-MRR shortfall (1 - MRR): bge-m3+qwen3-emb-0.6b vs bge-m3: +0.7%; vs local-only: +82.5%.


# Fusion-function replication and ablation

## 1. Replication check

Python re-implementation of the current blend (min-max cosine semantic term) reproduces the Swift retriever's rank for **42840/42840 = 100.00%** of query×setting×config cases (6 configs × 6 settings × 1190 queries). The Swift harness assigns candidate UUIDs in index order, so the retriever's UUID tie-break equals this script's stable sort. With random UUIDs the agreement was 99.45%: every residual difference was an exact local-score tie.

Lowest per-cell agreement: tr->tr / local-only = 100.00%; |ΔMRR| max over cells = 0.0000.

## 2. Ablation of the fusion function — macro-MRR@10 over six settings


**DEV (even paragraphs)**

| variant | local-only | nomic | bge-m3 | qwen3 | bge+qwen | all3 |
|---|---|---|---|---|---|---|
| current (min-max cosine, 0.42 lexical) | 0.736 | 0.766 | 0.955 | 0.928 | 0.954 | 0.936 |
| previous (rank-percentile, 0.42 lexical) | 0.736 | 0.763 | 0.855 | 0.862 | 0.881 | 0.848 |
| minmax-cosine, lexical=0.2 | 0.736 | 0.732 | 0.954 | 0.920 | 0.952 | 0.935 |
| minmax-cosine, lexical=0.1 | 0.736 | 0.711 | 0.951 | 0.913 | 0.947 | 0.931 |
| plain RRF(local + profiles), k=60 | 0.745 | 0.734 | 0.837 | 0.826 | 0.879 | 0.851 |
| dense-only (mean cosine) | 0.745 | 0.662 | 0.944 | 0.898 | 0.942 | 0.940 |

**TEST (odd paragraphs, held out)**

| variant | local-only | nomic | bge-m3 | qwen3 | bge+qwen | all3 |
|---|---|---|---|---|---|---|
| current (min-max cosine, 0.42 lexical) | 0.716 | 0.745 | 0.950 | 0.921 | 0.950 | 0.926 |
| previous (rank-percentile, 0.42 lexical) | 0.716 | 0.735 | 0.841 | 0.843 | 0.865 | 0.832 |
| minmax-cosine, lexical=0.2 | 0.716 | 0.713 | 0.958 | 0.911 | 0.951 | 0.930 |
| minmax-cosine, lexical=0.1 | 0.716 | 0.692 | 0.956 | 0.907 | 0.951 | 0.927 |
| plain RRF(local + profiles), k=60 | 0.726 | 0.711 | 0.827 | 0.813 | 0.871 | 0.838 |
| dense-only (mean cosine) | 0.726 | 0.643 | 0.951 | 0.900 | 0.951 | 0.941 |

Worst-setting MRR@10 on TEST (robustness):

| variant | local-only | nomic | bge-m3 | qwen3 | bge+qwen | all3 |
|---|---|---|---|---|---|---|
| current (min-max cosine, 0.42 lexical) | 0.287 | 0.378 | 0.894 | 0.800 | 0.891 | 0.825 |
| previous (rank-percentile, 0.42 lexical) | 0.287 | 0.368 | 0.587 | 0.633 | 0.671 | 0.594 |
| minmax-cosine, lexical=0.2 | 0.287 | 0.346 | 0.929 | 0.807 | 0.902 | 0.842 |
| minmax-cosine, lexical=0.1 | 0.287 | 0.323 | 0.930 | 0.808 | 0.903 | 0.841 |
| plain RRF(local + profiles), k=60 | 0.298 | 0.358 | 0.545 | 0.541 | 0.676 | 0.625 |
| dense-only (mean cosine) | 0.298 | 0.282 | 0.930 | 0.807 | 0.920 | 0.896 |

## 3. DEV-selected variant vs current blend (paired, TEST, pooled over six settings)

| config | DEV-selected variant | current MRR | selected MRR | ΔMRR@10 [95% CI] | p |
|---|---|---|---|---|---|
| nomic | current (min-max cosine, 0.42 lexical) | 0.745 | 0.745 | +0.000 [+0.000, +0.000] | 1.0000 |
| bge-m3 | current (min-max cosine, 0.42 lexical) | 0.950 | 0.950 | +0.000 [+0.000, +0.000] | 1.0000 |
| qwen3 | current (min-max cosine, 0.42 lexical) | 0.921 | 0.921 | +0.000 [+0.000, +0.000] | 1.0000 |
| bge+qwen | current (min-max cosine, 0.42 lexical) | 0.950 | 0.950 | +0.000 [+0.000, +0.000] | 1.0000 |
| all3 | dense-only (mean cosine) | 0.926 | 0.941 | +0.015 [+0.007, +0.024] | 0.0003 |

## 3b. Effect of the shipped change: previous rank-percentile vs current min-max cosine (paired, TEST, pooled)

| config | previous MRR | current MRR | ΔMRR@10 [95% CI] | p |
|---|---|---|---|---|
| nomic | 0.735 | 0.745 | +0.010 [+0.001, +0.018] | 0.0319 |
| bge-m3 | 0.841 | 0.950 | +0.109 [+0.096, +0.122] | 0.0001 |
| qwen3 | 0.843 | 0.921 | +0.078 [+0.067, +0.089] | 0.0001 |
| bge+qwen | 0.865 | 0.950 | +0.085 [+0.075, +0.096] | 0.0001 |
| all3 | 0.832 | 0.926 | +0.094 [+0.082, +0.106] | 0.0001 |

## 4. Isolating the multi-embedding step: RRF (rank) vs mean-cosine (score) fusion, dense-only, TEST

| combination | best single (macro-MRR) | RRF-fused | mean-cosine-fused |
|---|---|---|---|
| bge-m3 + qwen3 | 0.951 (bge-m3) | 0.936 | 0.951 |
| nomic + bge-m3 + qwen3 | 0.951 (bge-m3) | 0.827 | 0.941 |

# XQuAD: embedding models and fusions (real retriever)

1190 questions x 6 settings (tr/en monolingual, cross-lingual, bilingual store). TEST = odd paragraphs (596 questions per setting); selection on DEV only. Paragraph-cluster bootstrap.

| config | macro-MRR@10 TEST [95% CI] | cross-lingual MRR (tr→en, en→tr) | worst setting |
|---|---|---|---|
| qwen3-emb-4b+bge-m3+embeddinggemma-300m | 0.967 [0.955, 0.978] | 0.946 | 0.934 |
| qwen3-emb-4b+bge-m3 | 0.965 [0.953, 0.976] | 0.939 | 0.936 |
| qwen3-emb-4b+bge-m3+arctic-embed-l-v2 | 0.965 [0.953, 0.975] | 0.939 | 0.932 |
| qwen3-emb-4b+embeddinggemma-300m+arctic-embed-l-v2 | 0.965 [0.952, 0.975] | 0.943 | 0.929 |
| qwen3-emb-4b+nomic-v2-moe+arctic-embed-l-v2 | 0.964 [0.952, 0.974] | 0.937 | 0.929 |
| qwen3-emb-4b+embeddinggemma-300m+nomic-v2-moe | 0.963 [0.951, 0.975] | 0.938 | 0.925 |
| qwen3-emb-4b+arctic-embed-l-v2 | 0.963 [0.952, 0.974] | 0.935 | 0.925 |
| bge-m3+embeddinggemma-300m+arctic-embed-l-v2 | 0.963 [0.951, 0.974] | 0.939 | 0.931 |
| qwen3-emb-4b+bge-m3+nomic-v2-moe | 0.963 [0.951, 0.974] | 0.934 | 0.931 |
| qwen3-emb-4b+embeddinggemma-300m | 0.963 [0.950, 0.974] | 0.941 | 0.921 |
| bge-m3+embeddinggemma-300m | 0.962 [0.949, 0.973] | 0.938 | 0.923 |
| bge-m3+embeddinggemma-300m+nomic-v2-moe | 0.962 [0.949, 0.973] | 0.934 | 0.927 |
| qwen3-emb-4b+nomic-v2-moe | 0.961 [0.949, 0.972] | 0.927 | 0.917 |
| bge-m3+nomic-v2-moe+arctic-embed-l-v2 | 0.960 [0.948, 0.971] | 0.926 | 0.923 |
| embeddinggemma-300m+nomic-v2-moe+arctic-embed-l-v2 | 0.960 [0.947, 0.971] | 0.930 | 0.922 |
| embeddinggemma-300m+arctic-embed-l-v2 | 0.960 [0.947, 0.971] | 0.934 | 0.917 |
| bge-m3+arctic-embed-l-v2 | 0.958 [0.946, 0.970] | 0.926 | 0.925 |
| qwen3-emb-4b | 0.958 [0.946, 0.968] | 0.923 | 0.909 |
| embeddinggemma-300m+nomic-v2-moe | 0.958 [0.945, 0.969] | 0.925 | 0.911 |
| nomic-v2-moe+arctic-embed-l-v2 | 0.955 [0.942, 0.967] | 0.917 | 0.912 |
| bge-m3+nomic-v2-moe | 0.955 [0.942, 0.966] | 0.912 | 0.910 |
| embeddinggemma-300m | 0.953 [0.939, 0.965] | 0.928 | 0.903 |
| bge-m3+qwen3-emb-0.6b | 0.950 [0.936, 0.963] | 0.905 | 0.891 |
| bge-m3 | 0.950 [0.935, 0.963] | 0.904 | 0.894 |
| arctic-embed-l-v2 | 0.949 [0.935, 0.962] | 0.910 | 0.905 |
| e5-large-instruct | 0.948 [0.936, 0.959] | 0.894 | 0.892 |
| nomic-v2-moe | 0.942 [0.928, 0.956] | 0.882 | 0.869 |
| nomic-v1.5+bge-m3+qwen3-emb-0.6b | 0.926 [0.909, 0.941] | 0.840 | 0.825 |
| qwen3-emb-0.6b | 0.921 [0.903, 0.937] | 0.843 | 0.800 |
| nomic-v1.5 | 0.745 [0.720, 0.769] | 0.413 | 0.378 |
| local-only | 0.716 [0.692, 0.739] | 0.303 | 0.287 |

Selected on DEV: best single **qwen3-emb-4b**, best fusion **qwen3-emb-4b+bge-m3+nomic-v2-moe**.
TEST, fusion minus best single: ΔMRR@10 +0.005 [+0.001, +0.009], p = 0.0239.
