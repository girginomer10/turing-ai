#!/usr/bin/env python3
"""Build the two-page summary of the evaluation report (reuses styles and figures of build_report.py). Run: python3 build_summary.py"""
import os
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.platypus import BaseDocTemplate, Frame, PageTemplate, PageBreak, Spacer
from build_report import HERE, LM, TW, W, H, P, bullets, fig, table, cards, Numbered

OUT = os.path.join(HERE, "Turing-AI-retrieval-summary.pdf")
TITLE = "Evidence-Driven Memory Retrieval for a Multilingual, Provider-Agnostic AI Client"


def build():
    doc = BaseDocTemplate(OUT, pagesize=A4, leftMargin=LM, rightMargin=LM, topMargin=15 * mm, bottomMargin=18 * mm, title=TITLE, author="Ömer Girgin",
                          subject="Two-page summary: benchmarks, findings and product changes from the Turing AI project")
    doc.addPageTemplates([PageTemplate(id="p", frames=[Frame(LM, 18 * mm, TW, H - 33 * mm, id="f", leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)])])
    s = [P(TITLE, "title"), P("Two-page summary of the Turing AI evaluation", "subtitle"),
         P("Ömer Girgin · October 2026 · Code, data and full results: github.com/girginomer10/turing-ai, folder <b>benchmarks/</b>.", "byline"),
         cards([("0.44 → 0.995", "MRR@10 on personal memory, keyword search to the best pipeline (needs an embedding profile and a reranker; not the default)"),
                ("22 · 9 · 6", "embedding models (25 configurations) · rerankers · LLM judges"),
                ("+0.36", "MRR for finding events again after the fading fix (95% CI +0.26 to +0.45)"),
                ("21–48%", "of unanswerable queries still got memory injected by six LLM judges at the 0.75 bar (wide CIs)")]),
         Spacer(1, 3 * mm), P("Summary", "h2"),
         P("Turing AI is a native iOS, iPadOS and macOS app (with an Android port) where people bring their own provider keys and keep one local, portable memory across 50 provider presets. "
           "Whether that memory helps depends on retrieval: finding the right earlier fact in Turkish or English among near-duplicates, and staying silent when nothing applies. "
           "I built two reproducible benchmarks around the app's real Swift retriever, evaluated 22 embedding models, 9 rerankers and 6 LLM judges with bootstrap confidence intervals, and used the results to find and fix five defects and retune one setting. "
           "Quality is MRR@10: the average of 1/rank of the first correct memory in the top 10 (1 = always first, 0 = never found)."),
         fig("f10_ladder.png", "<b>Figure 1.</b> MRR@10 on the personal-memory benchmark for seven systems, from lexical search to a hosted two-stage pipeline (95% bootstrap CIs). "
             "The fully local pipeline (0.964) is not significantly different from Voyage-4-large alone (0.950; paired difference +0.015, CI &minus;0.013 to +0.042).", width=TW * 0.78),
         P("How it was measured", "h1")]
    s += bullets([
        "<b>Two datasets.</b> XQuAD (1,190 parallel Turkish/English questions) and a synthetic personal-memory set I built: 8 personas, 560 stored items, 360 queries including paraphrase, cross-lingual, hard-negative and 56 unanswerable ones.",
        "<b>Production code under test.</b> Everything runs the app's own retriever (<font name='DV-I'>HybridMemoryRetriever</font>); Python re-implementations reproduce the Swift ranks in 42,840 of 42,840 cases.",
        "<b>Protocol.</b> Choices (fusion, fade policy, confidence bar) were made on DEV personas and reported on disjoint TEST personas; comparisons use paired bootstrap differences. Four blind annotator agents agreed with all 360 labels (κ = 1.0), which checks validity, not realism. The hosted study cost about $10.",
    ])
    s += [PageBreak(), P("Findings", "h1")]
    s += bullets([
        "<b>Models differ far more on personal memory than on encyclopedic text</b> (0.55 to 0.95 against a 0.016 spread among strong models on XQuAD). Crossing languages separates them: nomic v1.5, Mistral embed and OpenAI text-embedding-3-small collapse (0.05, 0.19, 0.47) while Voyage-4-large keeps 0.925.",
        "<b>A reranker is the biggest second-stage win.</b> It lifts a fully local pipeline from 0.887 to 0.964 and a hosted one to 0.995, the benchmark's ceiling; a too-small reranker (Qwen3-0.6B) is worse than none. These numbers apply with Smart memory off. Fusing embedding models, by contrast, is not shown to help (+0.026, CI &minus;0.003 to +0.060).",
        "<b>Staying silent is the hard part.</b> All six LLM judges keep 99–100% of correct answers but inject on 21–48% of unanswerable queries. A higher selection bar (0.85, chosen on DEV) cut injection from 41% to 23% on TEST at 0.999 → 0.994 answers kept; counts are small, so the direction is dependable and the size is not.",
    ])
    s += [fig("f8_abstention.png", "<b>Figure 2.</b> Rerankers swept over thresholds (curves) against LLM judges (stars): dropping irrelevant injections costs correct answers. The comparison holds near 99% answer retention, not along the whole frontier.", width=TW * 0.7),
          P("What the benchmarks changed in the product", "h1"),
          table([["Finding", "Evidence", "Change in the app"],
                 ["Semantic score was a flat rank percentile, so lexical noise decided the order", "XQuAD 0.865 → 0.950; personal memory 0.572 → 0.733", "Per-query min-max cosine in the blend"],
                 ["Event weight halved every 14 days; a month-old event was nearly unfindable", "Answer-is-event MRR 0.48 → 0.84", "45-day half-life, 0.4 floor, shield for top-ranked events"],
                 ["Models need documented query/document prefixes; app sent raw text", "+0.073 EmbeddingGemma, +0.065 Arctic, +0.069 Nemotron-8B", "Correct formats per model; stored vectors rebuilt"],
                 ["Smart memory judged only the first 40 lexical matches, holding the answer for 81% of queries", "Embedding top 20 holds it for 100%", "Judge sees the embedding-ranked top 20"],
                 ["Strict JSON decoder discarded correct answers", "Claude Sonnet 5.5 valid answers 78.6% → 98.3%", "Tolerant decoder, still rejects invented IDs"],
                 ["Judges kept every entry rated ≥ 0.75", "Injection on unanswerable 41% → 23% (TEST, six judges)", "Selection bar raised to 0.85"]],
                [TW * 0.38, TW * 0.32, TW * 0.30]),
          Spacer(1, 2 * mm),
          P("<b>What a default user gets.</b> No embedding profile exists until the user adds one, so out of the box the app ranks lexically and Smart memory judges the first 40 matches. "
            "The 0.964 and 0.995 pipelines need an embedding profile, a reranker and Smart memory switched off.", "note")]
    doc.build(s, canvasmaker=Numbered)
    print("wrote", OUT)


if __name__ == "__main__":
    build()
