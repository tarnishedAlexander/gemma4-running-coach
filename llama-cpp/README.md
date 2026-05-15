# llama-cpp/ — Gemma 4 E2B on iPhone via llama.cpp + mtmd

Path #1 of two parallel implementations in this repo. Uses [llama.cpp](https://github.com/ggml-org/llama.cpp) with the `tools/mtmd` multimodal pipeline for vision. **Text + vision; audio not yet wired** (would require pulling latest llama.cpp where Gemma 4 audio Conformer was merged Apr 12 2026 in PR #21421).

For audio + live coaching mode, see the sibling [`litert-lm/`](../litert-lm/) implementation.

## Layout

```
llama-cpp/
├── README.md                          # this file
├── RUNTIME_STATUS.md                  # detailed build + perf notes
├── patches/                           # 4 modified Swift+script files vs upstream llama.cpp
│   ├── LibLlama.swift                 # +mtmd integration (~79 lines)
│   ├── LlamaState.swift               # +mmproj loader, image overload (~49 lines)
│   ├── ContentView.swift              # +PhotosPicker UI (~45 lines)
│   └── build-xcframework.sh           # +LLAMA_BUILD_TOOLS=ON for mtmd
└── scripts/
    ├── apply.sh                       # one-shot: clone llama.cpp + overlay + build
    └── build_ios_xcframework.sh       # iOS-only XCFramework workaround
```

## Prerequisites

- **macOS 14+ (Sonoma) on Apple Silicon** — required for Xcode 16 + Metal
- **Xcode 16+** — install from App Store
- **`cmake` 3.28+** — needed to build llama.cpp + the iOS XCFramework
  - If not present: download the universal binary from [cmake.org/download](https://cmake.org/download/), or:
    ```
    curl -sL -o /tmp/cmake.tgz \
      "https://github.com/Kitware/CMake/releases/download/v3.31.5/cmake-3.31.5-macos-universal.tar.gz"
    tar -xzf /tmp/cmake.tgz -C ~/local/
    ln -sf ~/local/cmake-3.31.5-macos-universal/CMake.app/Contents/bin/cmake ~/.local/bin/cmake
    ```
- **Apple ID + signing team** (for actual iPhone deploy; free personal team works for 7-day testing)

## Build

```
./scripts/apply.sh
```

That script:
1. Clones llama.cpp into `./llama.cpp/` (skip if already present)
2. Overlays the four patched files into the iOS example
3. Downloads `gemma-4-E2B-it-Q4_K_M.gguf` (~2.9 GB) and `mmproj-F16.gguf` (~940 MB) into the iOS app's `Resources/models/`
4. Builds the iOS-only XCFramework via `scripts/build_ios_xcframework.sh` (~5-10 min)
5. Builds `llama.swiftui.app` for `generic/platform=iOS`, unsigned, Debug

Output: `llama.cpp/examples/llama.swiftui/build_ios/Build/Products/Debug-iphoneos/llama.swiftui.app` (~3.8 GB — model + mmproj bundled in the .app).

## Model sources

- Text model: [`unsloth/gemma-4-E2B-it-GGUF`](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF) → `gemma-4-E2B-it-Q4_K_M.gguf`
- Vision projector: same repo → `mmproj-F16.gguf`

Alternatives that also work: `ggml-org/gemma-4-E2B-it-GGUF` (Q8_0 + bf16 only), `lmstudio-community/gemma-4-E2B-it-GGUF` (Q4_K_M + Q6_K + Q8_0 + mmproj-BF16).

## Deploy to physical iPhone

1. `open ./llama.cpp/examples/llama.swiftui/llama.swiftui.xcodeproj`
2. Select the `llama.swiftui` target → "Signing & Capabilities" tab → tick **"Automatically manage signing"** → pick your Team
3. Bundle ID `com.bachittle.llama-swift` may collide with another developer's; if Xcode complains, change to `com.<yourname>.llama-gemma4`
4. Plug iPhone in, select destination, **⌘R**
5. First install takes 1-3 min (3.8 GB bundle copy)
6. App is airplane-mode ready — model is bundled, no first-launch download

## Performance reference

On Mac mini M4 with Metal:
```
| model                    |  size   | params | backend  | threads |  test  |       t/s |
| gemma4 E2B Q4_K - Medium | 2.88GiB | 4.65 B | MTL,BLAS |    8    | pp256  |  758 ± 1  |
| gemma4 E2B Q4_K - Medium | 2.88GiB | 4.65 B | MTL,BLAS |    8    | tg128  |  57 ± 0.04|
```

Expected on iPhone 16 Pro (~3-4× slower for memory-bandwidth-bound inference):
- Prefill: ~200 tok/s
- Decode: ~15-20 tok/s
- TTFT for image query: ~3-7 sec cold

See [RUNTIME_STATUS.md](./RUNTIME_STATUS.md) for full architecture + caveat detail.

## When to use this path

- ✅ You want full control over sampling / KV cache / custom samplers
- ✅ You don't trust prebuilt binaries from small community repos
- ✅ You need to support pre–iPhone 13 devices (works on iPhone 8+ with smaller models)
- ✅ You want to leverage the broader llama.cpp ecosystem (Ollama, LM Studio compatibility)

## When to use [`litert-lm/`](../litert-lm/) instead

- ✅ You want vision + audio + multimodal in one API
- ✅ You want live coaching mode (built in `litert-lm/`)
- ✅ You want MTP (multi-token prediction, ~2× decode speedup)
- ✅ You want fewer lines of integration code (~4 lines vs ~150)
