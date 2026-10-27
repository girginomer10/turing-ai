# Provider model catalog

Last reviewed: 2026-09-05

All 50 provider presets are researched. Bundled IDs are discovery suggestions, never proof of account entitlement. Only conversational text output supported by the app's existing transports is offered. Installed models and user-named deployments remain connection-specific. No credentials or paid inference were used in research.

| Provider | Bundled chat IDs | Coverage |
| --- | ---: | --- |
| openai | 54 | documented |
| google | 14 | documented |
| anthropic | 11 | documented |
| xai | 1 | documented |
| meta | 2 | accountSpecific |
| mistral | 12 | documented |
| cohere | 13 | documented |
| deepseek | 3 | documented |
| qwen | 94 | documented |
| kimi | 4 | documented |
| zai | 19 | documented |
| minimax | 8 | documented |
| ai21 | 2 | documented |
| perplexity | 4 | documented |
| openrouter | 360 | publicCatalog |
| huggingface | 136 | publicCatalog |
| aiml_api | 354 | publicCatalog |
| deepinfra | 103 | publicCatalog |
| tinfoil | 7 | publicCatalog |
| vercel_ai | 249 | publicCatalog |
| poe | 238 | publicCatalog |
| microsoft_foundry | 0 | accountSpecific |
| amazon_bedrock | 36 | documented |
| tencent_tokenhub | 38 | accountSpecific |
| baidu_qianfan | 50 | accountSpecific |
| voyage_ai | 0 | documented |
| jina_ai | 0 | documented |
| ollama | 0 | accountSpecific |
| lm_studio | 0 | accountSpecific |
| local_ai | 0 | accountSpecific |
| vllm | 0 | accountSpecific |
| sglang | 0 | accountSpecific |
| llama_cpp | 0 | accountSpecific |
| jan | 0 | accountSpecific |
| custom | 0 | accountSpecific |
| groq | 9 | documented |
| together_ai | 18 | documented |
| fireworks_ai | 20 | documented |
| cerebras | 3 | publicCatalog |
| sambanova | 7 | publicCatalog |
| nvidia_nim | 61 | documented |
| nebius | 20 | publicCatalog |
| hyperbolic | 0 | unavailable |
| baseten | 16 | documented |
| scaleway | 12 | documented |
| digitalocean | 53 | documented |
| featherless_ai | 7073 | publicCatalog |
| chutes | 14 | publicCatalog |
| siliconflow | 85 | documented |
| novita_ai | 118 | publicCatalog |

## openai

Documented Responses + streaming + text-output models and active snapshots. Retired aliases removed using shutdown dates. Nonstreaming Pro, realtime/media-only and restricted specialized models are excluded from this chat adapter. Older models scheduled for future retirement are still included.

- [Official source 1](https://developers.openai.com/api/docs/models/all)
- [Official source 2](https://developers.openai.com/api/docs/deprecations)
- [Official source 3](https://developers.openai.com/api/docs/models/gpt-6-astra)
- [Official source 4](https://developers.openai.com/api/docs/models/gpt-5.6-sol)
- [Official source 5](https://developers.openai.com/api/docs/models/gpt-5.6-terra)
- [Official source 6](https://developers.openai.com/api/docs/models/gpt-5.6-luna)
- [Official source 7](https://developers.openai.com/api/docs/models/chat-latest)
- [Official source 8](https://developers.openai.com/api/docs/models/gpt-4)
- [Official source 9](https://developers.openai.com/api/docs/models/gpt-4-turbo)
- [Official source 10](https://developers.openai.com/api/docs/models/gpt-4.1)
- [Official source 11](https://developers.openai.com/api/docs/models/gpt-4.1-mini)
- [Official source 12](https://developers.openai.com/api/docs/models/gpt-4.1-nano)
- [Official source 13](https://developers.openai.com/api/docs/models/gpt-4o)
- [Official source 14](https://developers.openai.com/api/docs/models/gpt-4o-mini)
- [Official source 15](https://developers.openai.com/api/docs/models/gpt-5)
- [Official source 16](https://developers.openai.com/api/docs/models/gpt-5-mini)
- [Official source 17](https://developers.openai.com/api/docs/models/gpt-5-nano)
- [Official source 18](https://developers.openai.com/api/docs/models/gpt-5-pro)
- [Official source 19](https://developers.openai.com/api/docs/models/gpt-5.1)
- [Official source 20](https://developers.openai.com/api/docs/models/gpt-5.2)
- [Official source 21](https://developers.openai.com/api/docs/models/gpt-5.2-pro)
- [Official source 22](https://developers.openai.com/api/docs/models/gpt-5.3-codex)
- [Official source 23](https://developers.openai.com/api/docs/models/gpt-5.4)
- [Official source 24](https://developers.openai.com/api/docs/models/gpt-5.4-mini)
- [Official source 25](https://developers.openai.com/api/docs/models/gpt-5.4-nano)
- [Official source 26](https://developers.openai.com/api/docs/models/gpt-5.4-pro)
- [Official source 27](https://developers.openai.com/api/docs/models/gpt-5.5)
- [Official source 28](https://developers.openai.com/api/docs/models/o1)
- [Official source 29](https://developers.openai.com/api/docs/models/o3)
- [Official source 30](https://developers.openai.com/api/docs/models/o3-mini)
- [Official source 31](https://developers.openai.com/api/docs/models/o4-mini)

## google

Current documented conversational Gemini and hosted Gemma models. Retired versions, media generators, live/TTS, embeddings and dedicated agents omitted. Authenticated paginated models API can expose additional aliases.

- [Official source 1](https://ai.google.dev/gemini-api/docs/models)
- [Official source 2](https://ai.google.dev/gemini-api/docs/models/gemini-3.1-pro-preview)
- [Official source 3](https://ai.google.dev/gemma/docs/core/gemma_on_gemini_api)

## anthropic

All active general Claude API model IDs in lifecycle table. Restricted Mythos and retired models excluded; account models endpoint remains available.

- [Official source 1](https://platform.claude.com/docs/en/models/overview)
- [Official source 2](https://platform.claude.com/docs/en/about-claude/model-deprecations)

## xai

Current official general chat model. Older model aliases route to replacements and are not distinct models; multi-agent variants require Responses and are excluded.

- [Official source 1](https://docs.x.ai/developers/models)
- [Official source 2](https://docs.x.ai/developers/model-capabilities/text/multi-agent)

## meta

Preserved existing exact IDs. Current public developer catalog is access restricted/dynamic; no additional hosted API IDs could be verified. This is incomplete public coverage.

- [Official source 1](https://www.meta.ai/developers)

## mistral

Current chat model cards and supported aliases. Model lifecycle retirement table overrides older card existence; retired Devstral, Magistral, Medium3.1 and Small3.2 omitted. OCR/transcription/moderation/embedding-only endpoints excluded.

- [Official source 1](https://docs.mistral.ai/models)

## cohere

Live general Chat models in official table, including Aya multilingual models. Translation-only, deprecated, rerank and embeddings excluded.

- [Official source 1](https://docs.cohere.com/docs/models)

## deepseek

All current documented API model IDs; historical V3/R1 aliases are not distinct current models.

- [Official source 1](https://api-docs.deepseek.com/quick_start/pricing)
- [Official source 2](https://api-docs.deepseek.com/news/news260821/)

## qwen

International Singapore pricing tables only, using most recent heading at each level. Includes text/code/vision and hosted third-party conversational families. Regional-only, audio, translation-only, OCR and embedding models excluded. Account catalog/deployment availability can differ.

- [Official source 1](https://www.alibabacloud.com/help/en/model-studio/model-pricing)
- [Official source 2](https://www.alibabacloud.com/help/en/model-studio/getting-started/models)

## kimi

All four current text/vision/coding models. K2.5 and moonshot-v1 retired August31; K2 retired May25; old aliases excluded.

- [Official source 1](https://platform.kimi.ai/docs/models)

## zai

Documented Chat Completion model enum including vision and Flash variants. Phone-specific, OCR, audio and image generators excluded.

- [Official source 1](https://docs.z.ai/api-reference/llm/chat-completion)
- [Official source 2](https://docs.z.ai/guides/llm/glm-5.3)

## minimax

All eight documented OpenAI-compatible language models, preserving exact capitalization and highspeed variants.

- [Official source 1](https://platform.minimax.io/docs/api-reference/text-openai-api)

## ai21

Both hosted Chat request enum IDs. Jamba2 open-weight product names do not establish additional hosted API IDs; private deployment names remain custom.

- [Official source 1](https://docs.ai21.com/reference/jamba-1-6-api-ref)
- [Official source 2](https://docs.ai21.com/docs/jamba-foundation-models)

## perplexity

Full documented Sonar range for the existing Sonar adapter. sonar-reasoning is deprecated. Router private preview uses separate /router/v1 endpoints and needs account approval, so its unrelated routed IDs are excluded. Existing /chat/completions remains an explicitly supported alias for canonical /v1/sonar.

- [Official source 1](https://docs.perplexity.ai/docs/sonar/models)
- [Official source 2](https://docs.perplexity.ai/docs/sonar/models/sonar-reasoning-pro)
- [Official source 3](https://docs.perplexity.ai/docs/router/quickstart)
- [Official source 4](https://docs.perplexity.ai/docs/sonar/openai-compatibility)

## openrouter

Fetched complete public default text-output catalog (431 records, total_count431, no pagination parameters). Excluded 2 dedicated safety models. Image/audio-capable models retained when they support text output. Batch-only suffixed IDs excluded from interactive streaming.

- [Official source 1](https://openrouter.ai/api/v1/models)

## huggingface

Public router catalog: only text-output models with at least one live provider. Base IDs permit automatic routing; optional provider/:fastest suffixes are not separate models. Excluded dedicated safety models.

- [Official source 1](https://router.huggingface.co/v1/models)

## aiml_api

Full public registry filtered to type=openai/chat-completions; deduplicated IDs. Excludes Responses-only, Anthropic-only, embeddings, images, video, speech and dedicated safety IDs. Current response is an object with data array, not the legacy top-level array.

- [Official source 1](https://api.aimlapi.com/models)

## deepinfra

Full public /v1/models registry filtered by metadata.tags containing chat; excludes dedicated safety model and all embedding/media tasks.

- [Official source 1](https://api.deepinfra.com/v1/models)

## tinfoil

All public type=chat entries advertising the supported endpoint. Safety, embedding, audio, TTS, tools and document processing excluded.

- [Official source 1](https://inference.tinfoil.sh/v1/models)

## vercel_ai

All public language models. Excludes dedicated safety models, embedding, video, image, speech, transcription, realtime and reranking entries.

- [Official source 1](https://ai-gateway.vercel.sh/v1/models)

## poe

Public models/bots with text output, respecting explicit endpoint restrictions when present. Public bots are valid model IDs; image/video/audio-only bots excluded. Account tier and bot availability still apply.

- [Official source 1](https://api.poe.com/v1/models)

## microsoft_foundry

Request model is the user-chosen deployment name on the resource-specific endpoint. Global foundation-model IDs cannot be safely offered as ready deployments; enter the deployed name. No account credentials or management API were queried.

- [Official source 1](https://learn.microsoft.com/en-us/azure/foundry/how-to/deploy-models-managed)
- [Official source 2](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/working-with-models)

## amazon_bedrock

Only models with Chat Completions support in AWS compatibility table; exact IDs read from each model card. Claude, Nova, legacy Llama and other APIs excluded; safeguard excluded. Region/account availability applies. Most use bedrock-mantle.REGION.api.aws/v1; GPT-5.6 canonical IDs require mantle /openai/v1, while bedrock-runtime /openai/v1 requires documented geo/global inference IDs. Those account/region routing aliases are not separate models. Bundled list excludes GPT5.6 because it requires /openai/v1 instead of the preset /v1.

- [Official source 1](https://docs.aws.amazon.com/bedrock/latest/userguide/models-api-compatibility.html)
- [Official source 2](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions-mantle.html)
- [Official source 3](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html)
- [Official source 4](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-1.html)
- [Official source 5](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-12b-it.html)
- [Official source 6](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html)
- [Official source 7](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-4b-it.html)
- [Official source 8](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-minimax-minimax-m2.html)
- [Official source 9](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-minimax-minimax-m2-1.html)
- [Official source 10](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-minimax-minimax-m2-5.html)
- [Official source 11](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-devstral-2-123b.html)
- [Official source 12](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-magistral-small-2509.html)
- [Official source 13](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-ministral-14b-3-0.html)
- [Official source 14](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-ministral-3-8b.html)
- [Official source 15](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-ministral-3b.html)
- [Official source 16](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-mistral-large-3.html)
- [Official source 17](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-voxtral-mini-3b-2507.html)
- [Official source 18](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-voxtral-small-24b-2507.html)
- [Official source 19](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-moonshot-ai-kimi-k2-5.html)
- [Official source 20](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-nvidia-nvidia-nemotron-nano-9b-v2.html)
- [Official source 21](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-nvidia-nvidia-nemotron-nano-12b-v2-vl-bf16.html)
- [Official source 22](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-nvidia-nemotron-nano-3-30b.html)
- [Official source 23](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-nvidia-nemotron-super-3-120b.html)
- [Official source 24](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html)
- [Official source 25](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-terra.html)
- [Official source 26](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-luna.html)
- [Official source 27](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html)
- [Official source 28](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-20b.html)
- [Official source 29](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-235b-a22b-2507.html)
- [Official source 30](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html)
- [Official source 31](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-480b-a35b-instruct.html)
- [Official source 32](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-next.html)
- [Official source 33](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-next-80b-a3b.html)
- [Official source 34](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-vl-235b-a22b.html)
- [Official source 35](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-coder-30b-a3b-instruct.html)
- [Official source 36](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-writer-palmyra-vision-7b.html)
- [Official source 37](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-xai-grok-4-3.html)
- [Official source 38](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-xai-grok-4-6.html)
- [Official source 39](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-zai-glm-4-7.html)
- [Official source 40](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-zai-glm-4-7-flash.html)
- [Official source 41](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-zai-glm-5.html)

## tencent_tokenhub

Complete language/text-output understanding IDs from the API usage table, including documented DeepSeek aliases. Public GET/v1/models returns401 and requires the account key. Guangzhou vs Singapore endpoints are service-region-specific; refresh returns actual online account catalog. Image/video/3D/embedding generation excluded.

- [Official source 1](https://cloud.tencent.com/document/product/1823/130078)

## baidu_qianfan

All unique model-parameter IDs in documented text generation, visual understanding and deep-thinking tables. OCR/image generation/editing/vector/rerank/speech excluded. Public catalog fetch returned403; authenticated regional/account catalog remains authoritative.

- [Official source 1](https://cloud.baidu.com/doc/qianfan-docs/s/7m95lyy43)
- [Official source 2](https://cloud.baidu.com/doc/qianfan-api/s/Dmba8k71y)

## voyage_ai

Embedding-only provider. Listed current and still-accessible legacy dense text models separately. Deprecated v1/pilot IDs, open-weight-only voyage-4-nano, contextualized endpoint models and rerankers excluded.

- [Official source 1](https://docs.voyageai.com/docs/embeddings)

## jina_ai

Embedding-only provider. Exact text-capable dense embedding IDs from current OpenAPI discriminator. ColBERT multi-vector and ELSER sparse outputs excluded because the app expects one dense vector per input; rerankers/classifiers use other endpoints.

- [Official source 1](https://api.jina.ai/openapi.json)
- [Official source 2](https://jina.ai/embeddings/)

## ollama

Installed models are exposed by /v1/models (native /api/tags). Official library is a download catalog; adding every tag would not install them. Verified example tags gpt-oss:20b, qwen3:8b, qwen3-vl:8b, llama3.2 are suggestions only, not an exhaustive available model list.

- [Official source 1](https://docs.ollama.com/api/openai-compatibility)
- [Official source 2](https://ollama.com/library?sort=popular)

## lm_studio

GET /api/v1/models reports local available models, key identifiers and type=llm versus embedding; use that live catalog.

- [Official source 1](https://lmstudio.ai/docs/developer/rest/list)

## local_ai

Model names come from installed model configurations. Use the configured server /v1/models; downloadable gallery is not the running server catalog.

- [Official source 1](https://localai.io/docs/features/text-generation/)

## vllm

Served model IDs are runtime /v1/models names and can be changed with --served-model-name. Supported architecture list is not an available account model list.

- [Official source 1](https://docs.vllm.ai/en/latest/serving/online_serving/)

## sglang

Use configured server /v1/models names. The model path and serving configuration determine available IDs; supported model families are not installed models.

- [Official source 1](https://docs.sglang.io/docs/basic_usage/openai_api_completions)

## llama_cpp

Use /v1/models to list loaded/served models and aliases. GGUF filenames, aliases and router configuration are user-specific.

- [Official source 1](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

## jan

Jan explicitly requires YOUR_MODEL_ID from available models; use local API discovery after the server is started. No fixed global deployment names.

- [Official source 1](https://www.jan.ai/docs/desktop/api-server)

## custom

Endpoint and model IDs are entirely user-defined. OpenAI-compatible /models may be supported, but cannot assume a universal catalog; allow manual model identifiers.

- [Official source 1](https://localai.io/docs/features/text-generation/)
- [Official source 2](https://docs.vllm.ai/en/latest/serving/online_serving/)

## groq

All documented current general chat models and Compound systems. Llama3.1/3.3 and MiniMaxM2.7 require enterprise access according to current table. Whisper, Orpheus, Prompt Guard and GPT OSS Safeguard are separate speech/moderation tasks. Authenticated /models can further reflect account permissions.

- [Official source 1](https://console.groq.com/docs/models)

## together_ai

All current documented serverless Chat and Vision rows. Dedicated models require user-owned deployments and are not bundled as directly callable serverless IDs. Image/audio/embedding/rerank/moderation excluded.

- [Official source 1](https://docs.together.ai/docs/serverless/models)

## fireworks_ai

All current global serverless chat/vision model cards plus Fast routers. API IDs extracted from actual card code, not website slugs: Qwen3.8-Max page uses accounts/fireworks/models/qwen3p8-2p4t-a95b. US-only router IDs require separate us.api.fireworks.ai endpoint and are recorded separately in inference-exclusions.json. Embedding/reranker excluded.

- [Official source 1](https://fireworks.ai/models?modelTypes=Serverless&show=serverless)
- [Official source 2](https://docs.fireworks.ai/serverless/pricing)
- [Official source 3](https://docs.fireworks.ai/serverless/serving-paths)

## cerebras

All current public catalog rows are text generation. Live catalog supersedes old docs/deprecated examples.

- [Official source 1](https://api.cerebras.ai/public/v1/models)

## sambanova

All current public catalog rows are text generation. Live catalog supersedes old docs/deprecated examples.

- [Official source 1](https://api.sambanova.ai/v1/models)

## nvidia_nim

Current chat endpoint schemas and active model-page examples reconciled with the public catalog. Exact IDs come from model defaults in the API schemas, not page-title slugs. Public /models contains retired endpoints; explicit page deprecation notices override listing presence. Filtered retrieval, guard/reward, detector, OCR, translation-only, calibration, image/video-only and non-OpenAI VLM endpoints. Several older chat schemas remain documented while their model pages return soft404; these are retained as documented compatibility, not independently verified account access. Private/downloadable NIM inventories differ.

- [Official source 1](https://integrate.api.nvidia.com/v1/models)
- [Official source 2](https://docs.api.nvidia.com/nim/reference/llm-apis)
- [Official source 3](https://docs.api.nvidia.com/nim/reference/visual-models-apis)
- [Official source 4](https://build.nvidia.com/bigcode/starcoder2-15b)

## nebius

All current public text2text/image2text flavors excluding KimiK3, which current first-party UI explicitly excludes from Chat Completions exports. Models vary by region; default api.tokenfactory.nebius.com is eu-north1. Full per-model regions in nebius-model-regions.json; other regions require their documented base URL. User/account /v1/models is authoritative for configured endpoint.

- [Official source 1](https://tokenfactory.nebius.com/api/public/models_info)
- [Official source 2](https://tokenfactory.nebius.com/model-catalog.md)
- [Official source 3](https://docs.tokenfactory.nebius.com/api-reference/models/list-models)

## hyperbolic

Current fetched catalog contains only meta-llama/Llama-3.3-70B-Instruct with hidden:true; old supported-models URL redirects to GPU infrastructure docs. Cached search snippets list removed models and cannot establish current availability. No expanded verified models are supplied; preserve existing user model IDs/custom entry without claiming service shutdown. Authenticated /models returned401 without credentials.

- [Official source 1](https://app.hyperbolic.ai/models/)
- [Official source 2](https://www.hyperbolic.ai/docs/overview/overview)

## baseten

All16 current Model API slugs from official supported-models table. Custom Truss deployments have unique subdomains and are not generic model-API catalog IDs. Catalog authenticated via /v1/models.

- [Official source 1](https://docs.baseten.co/inference/model-apis/overview)

## scaleway

Current serverless text/code/vision rows after cross-checking dated EOL table, which overrides stale Yes cells. qwen3-coder-30b-a3b-instruct and pixtral-12b-2409 deprecated but still supported until2026-10-01. Already EOL gemma3, devstral2, voxtral and holo2 excluded. Dedicated-only quantization IDs excluded.

- [Official source 1](https://www.scaleway.com/en/docs/generative-apis/reference-content/supported-models/)

## digitalocean

All currently documented serverless foundation chat models. Explicit Responses-only GPT6Astra/GPT5.5/GPT5.4family omitted because the app uses chatCompletions for this provider; image/audio/video and dedicated-only rows omitted. Provider commercial-model/account access conditions still apply. GPT-5.2-pro and GPT-5.3-Codex have no Responses-only warning in the DigitalOcean table, unlike newer GPT entries; their actual hosted Chat Completions compatibility is untested.

- [Official source 1](https://docs.digitalocean.com/products/inference/details/models/)

## featherless_ai

Enumerated all25 declared pages:7,136 active conversational rows on pages1-8; pages9-25empty despite total_items24,160,total_pages25. Excluded recognizable dedicated-task IDs as documented in inference-exclusions.json. This is the full active template-capable catalog, not popularity picks. availability_on_current_plan=true should furtherfilter only authenticated calls; gating/HuggingFace access still applies. capabilities=chat returns only373active tagged rows and misses most fine-tunes.

- [Official source 1](https://featherless.ai/docs/api-reference-models)
- [Official source 2](https://api.featherless.ai/v1/models?conversational=true&page=1&per_page=1000)

## chutes

All 14 current LLM gateway models. Twelve records declare text output; two legacy rows (unsloth/Mistral-Nemo-Instruct-2407-TEE and Nemotron-3-Nano-Omni-30B-TEE) omit modality fields but remain conversational text models in the dedicated llm.chutes.ai catalog. The existing strict topLevelTextOutput parser silently drops those two.

- [Official source 1](https://llm.chutes.ai/v1/models)
- [Official source 2](https://chutes.ai/docs)

## siliconflow

Full official global ChatCompletionRequest and ChatCompletionVLMRequest model enums plus8recent current serverless cards missing from enum. IDs taken from page h2/API identifiers. Captioner-only and translation-only models excluded. No Chinese regional Pro/ namespaces invented for .com endpoint. API /models?type=text should refresh account availability.

- [Official source 1](https://docs.siliconflow.com/en/api-reference/chat-completions/chat-completions)
- [Official source 2](https://www.siliconflow.com/models)
- [Official source 3](https://www.siliconflow.com/models/gemma-4-12b-it)
- [Official source 4](https://www.siliconflow.com/models/glm-5-2)
- [Official source 5](https://www.siliconflow.com/models/hy3)
- [Official source 6](https://www.siliconflow.com/models/kimi-k2-7-code)
- [Official source 7](https://www.siliconflow.com/models/kimi-k3)
- [Official source 8](https://www.siliconflow.com/models/longcat-2-0)
- [Official source 9](https://www.siliconflow.com/models/minimax-m3)
- [Official source 10](https://www.siliconflow.com/models/nex-n2-pro)

## novita_ai

All118active status1 chat model entries with explicit chat/completions endpoint and text output;38status4 entries omitted. Catalog response includes richer model_type/endpoints/status/modalities than standard OpenAI model format, so use these fields instead of accepting all156 IDs.

- [Official source 1](https://api.novita.ai/openai/v1/models)
- [Official source 2](https://docs.novita.ai/api-reference/model-apis-llm-list-models)

## Maintenance

Update the bundled JSON from official current catalogs and lifecycle pages. Preserve exact ID casing and provider namespaces. Public catalogs can be stale (NVIDIA) or mix endpoints (AIML). Account/region-specific identifiers must not be invented. New catalog rows default disabled; explicit saved selections and limits survive updates. Large disabled bundled catalogs are not copied to SwiftData.
