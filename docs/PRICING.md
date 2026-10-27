# Bundled model prices

Last reviewed: 2026-09-05

The app bundles reviewed standard paid-tier USD prices, loaded offline from `ModelPrices.json`. Prices are estimates, not an account bill or an entitlement check. There is no runtime pricing server, no credentials, no automatic free-tier assumption and no external billing request. Users can override both rates (including zero) and return to official defaults.

| Billing provider | Exact model/alias entries | Official source |
| --- | ---: | --- |
| OpenAI | 49 | [Pricing](https://developers.openai.com/api/docs/pricing) and exact model pages linked in the JSON |
| Google Gemini | 12 | [Developer API pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| Anthropic | 16 | [Pricing](https://platform.claude.com/docs/en/about-claude/pricing) |
| xAI | 1 | [Grok 4.6](https://docs.x.ai/developers/models/grok-4.6) |
| DeepSeek | 3 | [Models and pricing](https://api-docs.deepseek.com/quick_start/pricing/) |
| OpenRouter | 411 | [Public model/pricing API](https://openrouter.ai/api/v1/models) |

492 exact provider/model pairs; this is not all models on every provider. A price from the model's developer is never reused for another inference host. Custom endpoints, missing historical provenance, unlisted IDs, unsupported conditional prices and expired entries remain explicitly unpriced. Local runtimes are not automatically assigned zero: a local endpoint can represent a paid upstream route.

## Calculation and maintenance

- Match the immutable request provider kind and actual endpoint host plus exact model ID. Do not use the provider's editable current configuration to reprice old requests. Ranking usage records bounded kind/host snapshots in the V6 sidecar; older ranking records without these remain unknown.
- Apply long-context tiers per request before aggregating days/months. A month's total is never one long request. DeepSeek uses each receipt's UTC weekday/hour: peak weekdays 01:00–04:00 and 06:00–10:00, otherwise off-peak. Receipts near a tariff boundary are still estimates.
- OpenRouter prices are that gateway's published routing estimates, not the lab's direct rates. Convert its USD/token fields to USD/million tokens. Include text-output models with finite nonnegative prices, exclude dynamic negative-price routers and unsupported time-conditioned overrides. Its `min_prompt_tokens` threshold is strictly greater-than, as specified by the [official schema](https://github.com/OpenRouterTeam/terraform-provider-openrouter/blob/main/docs/data-sources/model.md). Absent override price fields inherit the base price. Preserve explicit free variants; never strip suffixes or guess aliases.
- GPT-4o's 2024-05-13 snapshot is deliberately not assigned the later default's price. Dated OpenAI aliases included here were listed on the fetched exact model page. Claude Sonnet 4.5 estimates above 200k input are disabled because this catalog does not verify that legacy long-context tariff.
- Google rates are paid-tier text/image-input estimates for text-output chat, not audio generation. Current Flash 3.6–3.8 promotional rates end on 2027-01-01; Sol's promotional guarantee is conservatively capped at 2026-11-21. The entire snapshot expires on 2026-12-05 (90 days after review); after that automatic estimates stop and the UI requests an app update. A rate's earlier deadline takes precedence. Never extend deadlines without rechecking sources.
- To refresh: recheck official source pages/API, update the review date and deadlines, review the JSON diff, run the pricing and usage tests, and ship the refreshed list with an app update. There is no unattended refresh job.
- Manual overrides take precedence and sync/backup with existing per-model preferences. Reset clears only the two prices, preserving favorites and capability settings. Reports recalculate retained history at the bundled/current override rates; this is not immutable historical invoice accounting.
- Missing usage is excluded from automatic estimates, with a visible count. Cached-token adjustments, discounts, free credits, tax, separate per-request/search/embedding/audio charges and deleted or temporary usage are excluded. Excluding cache adjustments can overestimate discounted requests. Unallocated historical memory retries remain unpriced.
