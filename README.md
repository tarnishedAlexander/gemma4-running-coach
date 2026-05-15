# gemma4-running-coach

On-device **Gemma 4 E2B** (text + vision) running on iPhone — two parallel implementations.

> 📱 **Target:** iPhone 16 Pro (A18 Pro, 8 GB RAM)
> 🧠 **Model:** Gemma 4 E2B (4.65 B raw / ~2 B effective params, multimodal)
> 🎯 **Goal:** running-coach app that works fully on-device, including in airplane mode

---

## Two implementations, one repo

| | [`llama-cpp/`](./llama-cpp/) | [`litert-lm/`](./litert-lm/) |
|---|---|---|
| **Runtime** | [llama.cpp](https://github.com/ggml-org/llama.cpp) + custom XCFramework with `tools/mtmd` | [LiteRT-LM](https://ai.google.dev/edge/litert-lm) via the [`mylovelycodes/LiteRTLM-Swift`](https://github.com/mylovelycodes/LiteRTLM-Swift) community package |
| **Model format** | GGUF (Q4_K_M, ~2.9 GB) + mmproj-F16 (~940 MB) | `.litertlm` bundle (~2.6 GB) |
| **iOS app size** | 3.8 GB (model bundled in .app) | 40 MB (model downloaded on first launch) |
| **Lines of integration code** | ~150 (LibLlama + mtmd Swift bridge) | ~4 lines for happy path |
| **Vision** | ✅ wired via `mtmd` C API | ✅ built-in `engine.vision()` |
| **Audio** | ❌ would need parallel mtmd-audio path | ✅ built-in `engine.audio()` |
| **Multimodal (image + audio together)** | ❌ | ✅ `engine.multimodal()` |
| **MTP (multi-token prediction)** | ❌ | ✅ from LiteRT-LM v0.11+ |
| **ANE access** | ❌ Metal GPU only | ⚠️ depends on what backends the prebuilt xcframework was compiled with |
| **Min device** | iPhone 8 / A11 (small models) | iPhone 13 Pro / 6 GB+ RAM |
| **Trust model** | All source you can audit | Includes a prebuilt binary `CLiteRTLM.xcframework` from a small community repo |
| **Build status** | ✅ `BUILD SUCCEEDED` for `generic/iOS` | ✅ `BUILD SUCCEEDED` for `generic/iOS` |
| **Quickstart** | `cd llama-cpp && ./scripts/apply.sh` | `cd litert-lm && ./apply.sh` |

Both end up unsigned `.app` bundles ready for Xcode signing + iPhone deploy. See each subdirectory's README for the full build steps and the per-file deploy walkthrough.

## Performance reference (Gemma 4 E2B on Mac mini M4, Metal)

These numbers are from the macOS CLI of each runtime — directly comparable since both saturate the same Metal GPU:

| Backend | Prefill (pp256) | Decode (tg128) |
|---|---|---|
| llama.cpp | **758 tok/s** | 57 tok/s |
| LiteRT-LM (CLI) | 202 tok/s | 69 tok/s |
| MLX (reference) | 203 tok/s | ~85 tok/s |

iPhone 16 Pro estimate (~3-4× slower for memory-bandwidth-bound inference):
- Decode: **~15-20 tok/s on llama.cpp**, **~30-40 tok/s on LiteRT-LM with MTP enabled**
- Image processing (CLIP → 256 image tokens): ~2-4 sec one-time per image on either

## When to pick which

**Pick `llama-cpp/`** if you want maximum control over sampling, custom sampler chains, RAG plumbing, or you don't trust prebuilt binaries. It's the path the broader community uses (Ollama, LM Studio, every local-LLM iOS app on the App Store).

**Pick `litert-lm/`** if you want the audio + vision + multimodal API with minimal Swift code, MTP for free, and you're OK with iPhone 13 Pro+ as your floor and a small-community Swift wrapper. For the running-coach use case (prompt + photo + voice → coaching response), this is the more direct fit.

## Repo layout

```
gemma4-running-coach/
├── README.md                              # this file
├── llama-cpp/
│   ├── RUNTIME_STATUS.md                  # detailed build/perf notes for llama.cpp path
│   ├── patches/                           # 4 modified Swift/script files vs upstream llama.cpp
│   └── scripts/
│       ├── apply.sh                       # clone llama.cpp + overlay patches + build
│       └── build_ios_xcframework.sh       # iOS-only XCFramework builder (works around visionOS issue)
└── litert-lm/
    ├── README.md
    ├── apply.sh                           # one-shot: install xcodegen + build
    └── ios-app/
        ├── project.yml                    # XcodeGen spec
        └── GemmaCoach/                    # SwiftUI app (App / View / EngineModel + assets)
```

## License

Apache 2.0 for code that derives from llama.cpp / LiteRT-LM. MIT for everything else in this repo. Gemma 4 model weights are governed by [Google's Gemma Terms of Use](https://ai.google.dev/gemma/terms).
