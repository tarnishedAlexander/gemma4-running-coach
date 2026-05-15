# gemma4-running-coach

On-device **Gemma 4 E2B** (text + vision + audio + live coaching mode) running on iPhone — two parallel implementations.

> 📱 **Target:** iPhone 16 Pro (A18 Pro, 8 GB RAM)
> 🧠 **Model:** Gemma 4 E2B (4.65 B raw / ~2 B effective params, multimodal)
> 🎯 **Goal:** running-coach app that works fully on-device, including in airplane mode

---

## Getting started

### Prerequisites

| Dependency | Why | Where |
|---|---|---|
| **Mac on Apple Silicon, macOS 14+** | Required for Xcode 16 + Metal toolchain | — |
| **Xcode 16 or newer** | iOS app build + signing | App Store |
| **`cmake` 3.28+** | `llama-cpp/` path only — needed to build llama.cpp + iOS XCFramework | [cmake.org/download](https://cmake.org/download/) (universal binary, no install needed) |
| **Apple ID + signing team** | Deploy to physical iPhone | Free personal team works for 7-day testing; paid Apple Developer Program ($99/yr) needed for the `Increased Memory Limit` entitlement that `litert-lm/` requires |
| **iPhone (target device)** | `litert-lm/`: iPhone 13 Pro / 6 GB+ RAM minimum. `llama-cpp/`: iPhone 8+ works for small models | — |

Everything else (XcodeGen, model weights, LiteRT-LM Swift package, etc.) is auto-fetched by the per-path `apply.sh` scripts. **Nothing needs manual install beyond what's in this table.**

### Quickstart

Pick the path you want and run its `apply.sh`. Both produce an unsigned `.app` ready for Xcode signing + iPhone deploy.

**Path 1 — `litert-lm/` (recommended for live coaching demo)**
```
git clone https://github.com/louis6962/gemma4-running-coach.git
cd gemma4-running-coach/litert-lm
./apply.sh                              # ~2 min, no model download
open ios-app/GemmaCoach.xcodeproj
# In Xcode: Signing & Capabilities → Automatically manage → pick Team
# Plug iPhone, ⌘R
# App downloads 2.6 GB Gemma 4 model on first launch from HuggingFace
```

**Path 2 — `llama-cpp/` (max control + iPhone deploy w/o entitlements)**
```
cd gemma4-running-coach/llama-cpp
./scripts/apply.sh                      # ~15-20 min, downloads + builds everything
open llama.cpp/examples/llama.swiftui/llama.swiftui.xcodeproj
# Same Xcode signing setup
# ⌘R, first install ~1-3 min (3.8 GB bundle includes model)
```

Each subdirectory has its own README with deploy details, prerequisites, and troubleshooting.

### Model files

Model weights are **not in git** (would exceed GitHub's 100 MB per-file limit). They're downloaded from Hugging Face — either automatically by `apply.sh`, or manually with the commands below.

| | Source repo | File | Size |
|---|---|---|---|
| LiteRT-LM model | [`litert-community/gemma-4-E2B-it-litert-lm`](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) | `gemma-4-E2B-it.litertlm` | 2.6 GB |
| llama.cpp text model | [`unsloth/gemma-4-E2B-it-GGUF`](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF) | `gemma-4-E2B-it-Q4_K_M.gguf` | 2.9 GB |
| llama.cpp vision projector | same repo | `mmproj-F16.gguf` | 940 MB |

**Total disk if you build both paths:** ~6.5 GB models + ~500 MB cloned llama.cpp source + ~5 GB Xcode build artifacts.

#### Manual download commands

If you'd rather pull models yourself (or `apply.sh` fails behind a proxy), these are the exact commands:

**LiteRT-LM model — for `litert-lm/`.** The iOS app downloads this on first launch via the bundled `ModelDownloader`, so manual download is only needed if you want to pre-stage on the device sandbox or test the macOS LiteRT-LM CLI:

```bash
mkdir -p ~/work/evan/gemma_models
curl -L -o ~/work/evan/gemma_models/gemma-4-E2B-it.litertlm \
  https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm
```

**llama.cpp models — for `llama-cpp/`.** These get bundled INTO the iOS app at build time, so they must sit in `Resources/models/` BEFORE `xcodebuild` runs. Run from inside `llama-cpp/` after `apply.sh` step 1 (cloning llama.cpp) has happened:

```bash
TARGET_DIR=llama.cpp/examples/llama.swiftui/llama.swiftui/Resources/models
mkdir -p "$TARGET_DIR"

curl -L -o "$TARGET_DIR/gemma-4-E2B-it-Q4_K_M.gguf" \
  https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf

curl -L -o "$TARGET_DIR/mmproj-F16.gguf" \
  https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mmproj-F16.gguf
```

Verify file sizes after download:

```bash
ls -lh ~/work/evan/gemma_models/*.litertlm
ls -lh llama-cpp/llama.cpp/examples/llama.swiftui/llama.swiftui/Resources/models/*.gguf
```

Expect: 2.6 GB litertlm, 2.9 GB Q4_K_M, 940 MB mmproj. If anything is shorter, the download failed mid-stream — re-run the `curl`.

### Source repositories used (linked from per-path scripts)

| Component | Repo | Purpose |
|---|---|---|
| llama.cpp upstream | [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) | Inference engine for `llama-cpp/` path |
| LiteRT-LM Swift wrapper | [`mylovelycodes/LiteRTLM-Swift`](https://github.com/mylovelycodes/LiteRTLM-Swift) | Community Swift package for `litert-lm/` path |
| LiteRT-LM upstream | [`google-ai-edge/LiteRT-LM`](https://github.com/google-ai-edge/LiteRT-LM) | Underlying C++ runtime |
| XcodeGen | [`yonaskolb/XcodeGen`](https://github.com/yonaskolb/XcodeGen) | Auto-generates `.xcodeproj` from `project.yml` |

---

## Two implementations, side by side

| | [`llama-cpp/`](./llama-cpp/) | [`litert-lm/`](./litert-lm/) |
|---|---|---|
| **Runtime** | [llama.cpp](https://github.com/ggml-org/llama.cpp) + custom XCFramework with `tools/mtmd` | [LiteRT-LM](https://ai.google.dev/edge/litert-lm) via [`mylovelycodes/LiteRTLM-Swift`](https://github.com/mylovelycodes/LiteRTLM-Swift) |
| **Model format** | GGUF (Q4_K_M, ~2.9 GB) + mmproj-F16 (~940 MB) | `.litertlm` bundle (~2.6 GB) |
| **iOS app size** | 3.8 GB (model bundled in .app) | 40 MB (model downloaded on first launch) |
| **Lines of integration code** | ~150 (LibLlama + mtmd Swift bridge) | ~4 lines for happy path |
| **Vision** | ✅ wired via `mtmd` C API | ✅ built-in `engine.vision()` |
| **Audio** | ❌ would need parallel mtmd-audio path | ✅ built-in `engine.audio()` (mic recorder + 16 kHz WAV pipeline included) |
| **Live coaching mode** (TTS + trigger loop + background audio) | ❌ not built | ✅ wired (`LiveSession.swift`, `CoachSpeaker.swift`) |
| **Multimodal (image + audio together)** | ❌ | ✅ `engine.multimodal()` |
| **MTP (multi-token prediction)** | ❌ | ✅ from LiteRT-LM v0.11+ |
| **ANE access** | ❌ Metal GPU only | ❌ Metal GPU only (audio encoder pinned to CPU at model level — deliberate Google optimization, not a constraint) |
| **Min device** | iPhone 8 / A11 (small models) | iPhone 13 Pro / 6 GB+ RAM |
| **Trust model** | All source you can audit | Includes a prebuilt binary `CLiteRTLM.xcframework` from a small community repo |
| **Build status** | ✅ `BUILD SUCCEEDED` for `generic/iOS` | ✅ `BUILD SUCCEEDED` for `generic/iOS` |

Both end up unsigned `.app` bundles ready for Xcode signing + iPhone deploy.

## Performance reference (Gemma 4 E2B on Mac mini M4, Metal)

These numbers are from the macOS CLI of each runtime — directly comparable since both saturate the same Metal GPU:

| Backend | Prefill (pp256) | Decode (tg128) |
|---|---|---|
| llama.cpp | **758 tok/s** | 57 tok/s |
| LiteRT-LM (CLI) | 202 tok/s | 69 tok/s |
| MLX (reference) | 203 tok/s | ~85 tok/s |

iPhone 16 Pro estimate (~3-4× slower for memory-bandwidth-bound inference):
- Decode: **~15-20 tok/s on either path**
- Image processing (CLIP → 256 image tokens): **~2-4 sec one-time per image**

See [`litert-lm/TESTING_PARITY.md`](./litert-lm/TESTING_PARITY.md) for three real ways to test on actual iPhone hardware (Xcode WiFi pairing, BrowserStack cloud iPhone, macOS CPU throttling).

## Architecture notes

- [`docs/ARCHITECTURE_PERCEPTION_GATE.md`](./docs/ARCHITECTURE_PERCEPTION_GATE.md) — design note on splitting perception (ANE) from reasoning (GPU); not implemented, future direction
- [`UPDATES/2026-05-15-live-mode.md`](./UPDATES/2026-05-15-live-mode.md) — written status update for team

## License

Apache 2.0 for code that derives from llama.cpp / LiteRT-LM. MIT for everything else in this repo. Gemma 4 model weights are governed by [Google's Gemma Terms of Use](https://ai.google.dev/gemma/terms).
