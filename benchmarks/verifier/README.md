# Memory-write verifier (pilot, days 1-3)

Does the user's message actually support the memory the app is about to store? The app's deterministic validator
(`AutomaticMemoryExtractor.parseAndValidate`) checks shape, evidence IDs, scope and confidence, not meaning. This
directory holds the pilot that measures how often stored memories are unsupported, the human labeling packet, the
on-device smoke test for a small multilingual NLI model, and the week-1 specification ([SPEC.md](SPEC.md)).

Nothing under `Packages/` or `Apps/` is changed by this phase.

## Layout

| path | what |
|---|---|
| `SPEC.md` | task definition, labels, data and training plan, comparison protocol, metrics, failure policy, integration point |
| `LABELING_GUIDE.md` | instructions for the two human annotators (worked examples, insufficient vs contradicts) |
| `llm.py` | chat client (OpenAI, OpenRouter, DeepInfra) charged to the shared spend ledger, phase cap $5 |
| `gen_conversations.py` | pilot pack: ~100 TR/EN/code-switched conversations written by Gemma 4 31B (DeepInfra) -> `data/conversations.jsonl`, `data/generation_log.md` |
| `Validate/` | SwiftPM harness around the real `AutomaticMemoryExtractor.request` and `parseAndValidate` (line protocol on stdin/stdout) |
| `extract.py` | the app's extraction prompt, message by message with memory state carried forward, two extractor families -> `data/extractions.<family>.jsonl`, `data/proposals.jsonl` |
| `make_packet.py` | blind, shuffled labeling sheets -> `work/labeling/packet_core.csv`, `packet_rest_A.csv`, `packet_rest_B.csv` (+ hidden `packet_key.csv`) |
| `preannotate.py` | LLM pre-annotation by a third family (DeepSeek V4.1 Flash), an ESTIMATE hidden from annotators -> `work/preannotation/` |
| `first_look.py` | validator pass counts per family, proposal counts, pre-annotation estimate, examples -> `work/first_look.md` |
| `smoke/` | on-device smoke test (`smoke_nli.py`, `pairs.jsonl`); reports in `work/smoke/*.json` |

`work/` is git-ignored (raw outputs, pre-annotations, converted models). `data/` is committed (fictional conversations,
extraction outputs, proposals; no keys).

## Reproduce

```sh
# keys in benchmarks/.env (git-ignored); the scratchpad venv has numpy; the ML venv has torch/transformers/coremltools/onnxruntime
swift build -c release --package-path Validate
python -I gen_conversations.py --count 100
python -I extract.py --families oa:gpt-6-luna di:Qwen/Qwen3.8-Flash
python -I make_packet.py --core 300
python -I preannotate.py            # estimate only
python -I first_look.py
python -I smoke/smoke_nli.py --model MoritzLaurer/multilingual-MiniLMv2-L6-mnli-xnli --models-dir <dir> --out work/smoke
```

## On-device smoke test (Mac, Apple M4 Pro; iPhone untested)

54 TR/EN/mixed premise-hypothesis pairs (`smoke/pairs.jsonl`), max length 128, batch 1. "Agreement with expected" is
against the labels I wrote for those pairs and only shows that zero-shot NLI is far from the task; parity columns are what
the smoke test is for. RSS figures are for the whole Python process with PyTorch and coremltools loaded and are not
device memory; the model file size is the number to plan with.

| model (MIT per downloaded card) | params | runtime | label parity with PyTorch | max logit diff | p50 / p95 ms | size |
|---|---|---|---|---|---|---|
| multilingual-MiniLMv2-L6-mnli-xnli | 107M (96M are the 250k-token embedding) | PyTorch fp32 | reference (30/54 expected) | - | 6.6 / 6.8 | 472 MB download |
| | | ONNX Runtime fp32 | 54/54 | 8e-6 | 5.8 / 5.9 | 428 MB |
| | | ONNX Runtime dynamic int8 | **4/54 (broken)** | 3.9 | 7.7 / 7.9 | 396 MB |
| | | Core ML fp32 (mlprogram) | 54/54 | 6e-6 | 1.6 / 2.1 | 428 MB |
| | | Core ML fp16 | 54/54 | 0.04 | 1.0 / 2.2 | - |
| | | Core ML int8 weights, CPU-only | 53/54 | 0.16 | 3.2 / 3.4 | **109 MB** |
| mDeBERTa-v3-base-mnli-xnli | 279M | PyTorch fp32 | reference (35/54 expected) | - | 42.9 / 43.6 | 578 MB download |
| | | ONNX Runtime fp32 | 54/54 | 6e-5 | 45.6 / 45.9 | 1,116 MB |
| | | ONNX Runtime dynamic uint8 | 35/54 | 6.7 | 59.2 / 60.2 | 917 MB |
| | | Core ML | **conversion failed** (`sqrt` on an int32 tensor in the relative-position code) | | | |

Findings: Core ML is the workable path for the small model (fp16 is bit-for-bit on labels, int8 weights cut the file to
109 MB with one flipped label out of 54; the int8 model crashed the GPU path and must be loaded CPU-only). ONNX dynamic
quantisation breaks both models. mDeBERTa does not convert to Core ML as is. Tokenizers are fast tokenizers with zero
unknown tokens on the Turkish pairs; on-device tokenization parity is not tested (no Swift tokenizer yet). Zero-shot
accuracy on my pairs is low for both models (30/54 and 35/54), which is the gap fine-tuning has to close.
Checked from the downloaded cards: both repos state `license: mit`; sizes above are measured. Not checked: ONNX Runtime
iOS packaging, Core ML behaviour on an actual iPhone.
