# Third-party marks

Turing AI is an independent application and is not endorsed by, sponsored by, or affiliated with the providers shown in its interface. Provider names and logos are trademarks of their respective owners. Marks identify the selected connection or message source; they are not the application's own branding.

The app bundles artwork for all 49 named provider presets. The user-defined **Custom** connection keeps a neutral system icon because it has no single brand. Assets are local; displaying a logo makes no network request.

[ProviderLogoSources.json](../Brand/ProviderLogoSources.json) records each shipped image, official source page/download URL, SHA-256, and any technical adaptation. Sources were last reviewed on 2026-09-05. Official website icons, developer-documentation marks and provider-owned brand repositories are the only sources; third-party logo aggregators are not used.

Artwork retains its original geometry, proportions and colors. PNG conversion adds transparent padding without cropping. A neutral light tile preserves contrast for fixed-color marks in either theme. OpenRouter and Tinfoil ship their official light/dark theme variants. Tinfoil's 32-pixel minimum is checked against the actual display scale rather than treating points as pixels.

Specific credits and guidance:

- **OpenAI:** Blossom from the official developer-site header, rendered in black. [Brand guidelines](https://openai.com/brand/). Only identifies the OpenAI provider.
- **Anthropic:** official website touch icon. [Newsroom / press kit](https://www.anthropic.com/news).
- **Google:** official Google AI for Developers touch icon. [Brand Resource Center](https://about.google/brand-resource-center/).
- **xAI / SpaceXAI:** current light favicon from the official API documentation, preserving its published artwork. [Brand guidelines](https://x.ai/legal/brand-guidelines).
- **NVIDIA:** standalone published eye-mark SVG path from NVIDIA's homepage, retaining its transform and green fill.
- **llama.cpp:** official [ggml-org/llama.brand](https://github.com/ggml-org/llama.brand) icon. Licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) with the repository's additional [brand-use permission](https://github.com/ggml-org/llama.brand/blob/master/BRAND-USAGE.md) permitting identification and redistribution in software, including commercial use. Proportional PNG format conversion only.
- **OpenRouter:** official [sign-in repository](https://github.com/OpenRouterTeam/sign-in-with-openrouter/blob/main/public/openrouter-logo.svg), MIT licensed; copyright 2026 OpenRouter Contributors. Official light/dark artwork retained.
- **Tinfoil:** official [brand assets](https://tinfoil.sh/brand), black and white icon marks. Published minimum size respected.
- **Other providers:** official website / documentation icons and logos, individually attributed in the source manifest. All owners retain their trademark rights; a publicly served image is not a claim of endorsement or a general trademark license.

The full MIT license for the OpenRouter source asset follows.

```text
MIT License

Copyright (c) 2026 OpenRouter Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
