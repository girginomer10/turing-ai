"""On-device smoke test for an off-the-shelf multilingual NLI cross-encoder (Mac only).

Steps: download the model (into its own directory under --models-dir, treated as untrusted data), run PyTorch as the
reference, export to Core ML (coremltools) and ONNX (onnxruntime), compare decisions on smoke/pairs.jsonl, measure
p50/p95 latency and peak RSS, and try 8-bit weight quantisation for each converted runtime.
Writes <out>/<model-slug>.json and prints a summary. No API keys involved.

Run with the ML venv:  python -I smoke_nli.py --model MoritzLaurer/multilingual-MiniLMv2-L6-mnli-xnli
"""
import argparse, json, os, platform, resource, statistics, sys, time


def rss_mb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def percentile(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f, c = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--models-dir", required=True, help="each model is downloaded into its own subdirectory")
    ap.add_argument("--pairs", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "pairs.jsonl"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-len", type=int, default=128)
    ap.add_argument("--skip-coreml", action="store_true")
    ap.add_argument("--skip-onnx", action="store_true")
    a = ap.parse_args()

    import numpy as np
    import torch
    from huggingface_hub import snapshot_download, model_info
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    torch.set_num_threads(max(1, os.cpu_count() // 2))
    slug = a.model.replace("/", "__")
    local = os.path.join(a.models_dir, slug)
    os.makedirs(local, exist_ok=True)
    report = {"model": a.model, "platform": platform.platform(), "machine": platform.machine(),
              "torch": torch.__version__, "python": sys.version.split()[0], "max_len": a.max_len}
    try:
        info = model_info(a.model)
        card = info.cardData or {}
        report["card"] = {"license": card.get("license"), "sha": info.sha,
                          "tags": [t for t in (info.tags or []) if "license" in t or "base_model" in t][:6]}
    except Exception as e:  # offline or no metadata; the files on disk still carry the card
        report["card"] = {"error": type(e).__name__}
    path = snapshot_download(a.model, local_dir=local, allow_patterns=["*.json", "*.txt", "*.model", "*.safetensors", "README.md"])
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs)
    report["download_bytes"] = size
    readme = os.path.join(path, "README.md")
    if os.path.exists(readme):
        head = open(readme, encoding="utf-8", errors="replace").read(2000)
        lic = [l for l in head.splitlines() if l.lower().startswith("license")]
        report["card"]["readme_license_line"] = lic[0] if lic else None

    pairs = [json.loads(l) for l in open(a.pairs, encoding="utf-8") if l.strip()]
    tok = AutoTokenizer.from_pretrained(path)
    model = AutoModelForSequenceClassification.from_pretrained(path).eval()
    id2label = {int(k): v.lower() for k, v in model.config.id2label.items()}
    report["id2label"] = id2label
    report["parameters"] = sum(p.numel() for p in model.parameters())

    def encode(p):
        return tok(p["premise"], p["hypothesis"], return_tensors="np", padding="max_length", truncation=True, max_length=a.max_len)

    enc = [encode(p) for p in pairs]
    report["tokenizer"] = {"class": type(tok).__name__, "fast": getattr(tok, "is_fast", None),
                           "max_tokens_used": int(max(int(e["attention_mask"].sum()) for e in enc)),
                           "unk_count": int(sum((e["input_ids"] == tok.unk_token_id).sum() for e in enc)) if tok.unk_token_id is not None else None}

    # --- PyTorch reference ---
    def torch_logits(e):
        with torch.no_grad():
            inputs = {k: torch.from_numpy(v) for k, v in e.items() if k in ("input_ids", "attention_mask", "token_type_ids")}
            return model(**inputs).logits[0].numpy()

    for e in enc[:3]:
        torch_logits(e)  # warm-up
    ref, lat = [], []
    for e in enc:
        t0 = time.perf_counter(); ref.append(torch_logits(e)); lat.append((time.perf_counter() - t0) * 1000)
    ref = np.stack(ref)
    pred = [id2label[int(i)] for i in ref.argmax(1)]
    agree_expected = sum(p == q["expected"] for p, q in zip(pred, pairs))
    by_lang = {}
    for p, q in zip(pred, pairs):
        by_lang.setdefault(q["lang"], [0, 0]); by_lang[q["lang"]][1] += 1; by_lang[q["lang"]][0] += p == q["expected"]
    report["pytorch"] = {"p50_ms": percentile(lat, .5), "p95_ms": percentile(lat, .95), "rss_mb_after": rss_mb(),
                         "agree_with_my_expected": f"{agree_expected}/{len(pairs)}", "by_lang": {k: f"{v[0]}/{v[1]}" for k, v in by_lang.items()},
                         "predictions": pred}
    print("pytorch", report["pytorch"]["p50_ms"], report["pytorch"]["agree_with_my_expected"], by_lang, flush=True)

    def save():
        os.makedirs(a.out, exist_ok=True)
        json.dump(report, open(os.path.join(a.out, slug + ".json"), "w"), indent=1, ensure_ascii=False)

    def compare(name, logits_fn, quant_note=None):
        save()  # a native crash inside a converted runtime must not lose the earlier results
        try:
            for e in enc[:3]:
                logits_fn(e)
            out, lt = [], []
            for e in enc:
                t0 = time.perf_counter(); out.append(np.asarray(logits_fn(e), dtype=np.float32).reshape(-1)); lt.append((time.perf_counter() - t0) * 1000)
            out = np.stack(out)
            labels_same = int((out.argmax(1) == ref.argmax(1)).sum())
            report[name] = {"ok": True, "label_agreement_with_pytorch": f"{labels_same}/{len(pairs)}",
                            "max_abs_logit_diff": float(np.abs(out - ref).max()), "mean_abs_logit_diff": float(np.abs(out - ref).mean()),
                            "p50_ms": percentile(lt, .5), "p95_ms": percentile(lt, .95), "rss_mb_after": rss_mb(),
                            "agree_with_my_expected": f"{sum(id2label[int(i)] == q['expected'] for i, q in zip(out.argmax(1), pairs))}/{len(pairs)}",
                            "note": quant_note}
            print(name, report[name]["label_agreement_with_pytorch"], report[name]["max_abs_logit_diff"], report[name]["p50_ms"], flush=True)
        except Exception as e:
            report[name] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:400]}"}
            print(name, "FAILED", report[name]["error"], flush=True)

    uses_tt = "token_type_ids" in enc[0]

    # --- ONNX Runtime ---
    if not a.skip_onnx:
        try:
            import onnxruntime as ort
            onnx_path = os.path.join(a.out, slug + ".onnx")
            names = ["input_ids", "attention_mask"] + (["token_type_ids"] if uses_tt else [])
            sample = tuple(torch.from_numpy(enc[0][n]) for n in names)
            torch.onnx.export(model, sample, onnx_path, input_names=names, output_names=["logits"], opset_version=17,
                              dynamo=False, dynamic_axes={n: {0: "b", 1: "s"} for n in names} | {"logits": {0: "b"}})
            report["onnx_bytes"] = os.path.getsize(onnx_path)
            sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
            # the exporter drops inputs the graph never reads (DeBERTa-v2 ignores token_type_ids), so feed only what exists
            onnx_names = [i.name for i in sess.get_inputs()]
            compare("onnxruntime_fp32", lambda e: sess.run(None, {n: e[n].astype(np.int64) for n in onnx_names})[0])
            try:
                from onnxruntime.quantization import quantize_dynamic, QuantType
                q_path = os.path.join(a.out, slug + ".int8.onnx")
                # QUInt8 (the onnxruntime default) and skipping the embedding gather keep the activations' dynamic range;
                # QInt8 on every MatMul broke this model (2/54 label agreement in the first run).
                quantize_dynamic(onnx_path, q_path, weight_type=QuantType.QUInt8, op_types_to_quantize=["MatMul"])
                report["onnx_int8_bytes"] = os.path.getsize(q_path)
                qsess = ort.InferenceSession(q_path, providers=["CPUExecutionProvider"])
                q_names = [i.name for i in qsess.get_inputs()]
                compare("onnxruntime_int8", lambda e: qsess.run(None, {n: e[n].astype(np.int64) for n in q_names})[0], "dynamic uint8 MatMul weights")
            except Exception as e:
                report["onnxruntime_int8"] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:300]}"}
        except Exception as e:
            report["onnx_export"] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:400]}"}
            print("onnx export FAILED", report["onnx_export"]["error"], flush=True)

    # --- Core ML ---
    if not a.skip_coreml:
        try:
            import coremltools as ct

            class Wrapped(torch.nn.Module):
                def __init__(self, m):
                    super().__init__(); self.m = m

                def forward(self, input_ids, attention_mask, token_type_ids=None):
                    if token_type_ids is None:
                        return self.m(input_ids=input_ids, attention_mask=attention_mask).logits
                    return self.m(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids).logits

            names = ["input_ids", "attention_mask"] + (["token_type_ids"] if uses_tt else [])
            sample = [torch.from_numpy(enc[0][n]).to(torch.int32) for n in names]
            traced = torch.jit.trace(Wrapped(model).eval(), sample)
            inputs = [ct.TensorType(name=n, shape=(1, a.max_len), dtype=np.int32) for n in names]
            mlmodel = ct.convert(traced, inputs=inputs, outputs=[ct.TensorType(name="logits")], convert_to="mlprogram",
                                 minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT32)
            ml_path = os.path.join(a.out, slug + ".mlpackage")
            mlmodel.save(ml_path)
            report["coreml_bytes"] = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(ml_path) for f in fs)
            compare("coreml_fp32", lambda e: mlmodel.predict({n: e[n].astype(np.int32) for n in names})["logits"])
            try:
                mlmodel16 = ct.convert(traced, inputs=inputs, outputs=[ct.TensorType(name="logits")], convert_to="mlprogram",
                                       minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
                compare("coreml_fp16", lambda e: mlmodel16.predict({n: e[n].astype(np.int32) for n in names})["logits"], "fp16 compute (default on device)")
            except Exception as e:
                report["coreml_fp16"] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:300]}"}
            try:
                from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
                cfg = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
                q8 = linear_quantize_weights(mlmodel, cfg)
                q8_path = os.path.join(a.out, slug + ".int8.mlpackage")
                q8.save(q8_path)
                report["coreml_int8_bytes"] = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(q8_path) for f in fs)
                # The GPU (MPSGraph) path crashed the process with an MLIR assertion on the int8 model in the first run;
                # load it CPU-only, which is also the conservative choice for a background job on a phone.
                q8cpu = ct.models.MLModel(q8_path, compute_units=ct.ComputeUnit.CPU_ONLY)
                compare("coreml_int8_cpu", lambda e: q8cpu.predict({n: e[n].astype(np.int32) for n in names})["logits"], "int8 linear symmetric weights, CPU-only compute units")
            except Exception as e:
                report["coreml_int8"] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:300]}"}
        except Exception as e:
            report["coreml_convert"] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:400]}"}
            print("coreml convert FAILED", report["coreml_convert"]["error"], flush=True)

    report["peak_rss_mb_process"] = rss_mb()
    save()
    print("wrote", os.path.join(a.out, slug + ".json"))


if __name__ == "__main__":
    main()
