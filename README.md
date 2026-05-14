# gemma4-running-coach

On-device **Gemma 4 E2B** (text + vision) running on iPhone via **llama.cpp**.

This is the inference foundation for a running-coach app — the LLM lives entirely on the phone, works in airplane mode, and accepts both text prompts and photos through the standard iOS Photos picker.

> 📱 **Target:** iPhone 16 Pro (A18 Pro, 8 GB RAM)
> 🧠 **Model:** Gemma 4 E2B (4.65 B raw / ~2 B effective params, Q4_K_M GGUF, ~2.9 GB) + mmproj-F16 vision projector (~940 MB)
> ⚙️ **Runtime:** llama.cpp (commit `dbe7901`+) with `tools/mtmd` for vision

---

## What this repo is

A small overlay on top of [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp). It contains:

- **4 patched files** that extend the stock `examples/llama.swiftui` iOS example with Gemma 4 + vision:
  - `patches/LibLlama.swift` — adds `mtmd_context`, `loadMmproj()`, `completion_init_with_image()`
  - `patches/LlamaState.swift` — auto-loads bundled mmproj, new `complete(text:, imagePath:)` overload
  - `patches/ContentView.swift` — `PhotosPicker` UI, image staging, image-aware send
  - `patches/build-xcframework.sh` — enables `LLAMA_BUILD_TOOLS=ON` so `libmtmd.a` is built
- **`scripts/build_ios_xcframework.sh`** — manual iOS-only XCFramework build (the official multi-platform `build-xcframework.sh` fails at visionOS configure when `LLAMA_BUILD_TOOLS=ON`; this script combines the iOS device + sim outputs into a clean framework with mtmd headers exposed in the modulemap)
- **`scripts/apply.sh`** — one-shot: clones llama.cpp, overlays the patches, downloads the GGUFs, builds the iOS-only XCFramework
- **`RUNTIME_STATUS.md`** — detailed notes on what was built, on-device perf estimates, and the manual Xcode steps to deploy to a physical iPhone

---

## Quickstart (Mac w/ Xcode 26+)

```bash
git clone https://github.com/<you>/gemma4-running-coach.git
cd gemma4-running-coach
./scripts/apply.sh
```

That script:
1. Clones llama.cpp to `./llama.cpp/`
2. Overlays the four patched files into the iOS example
3. Downloads the GGUF (Gemma 4 E2B Q4_K_M, ~2.9 GB) and mmproj (~940 MB) into the iOS app's `Resources/models/`
4. Runs `cmake -B build` for macOS sanity (you can `llama-bench` against the GGUF if you want to verify Metal locally — ~57 decode tok/s on M4)
5. Runs the iOS-only XCFramework script (~5 min, builds the `llama.framework` with mtmd)
6. Builds `llama.swiftui.app` for `generic/platform=iOS` (unsigned)

After that, open `llama.cpp/examples/llama.swiftui/llama.swiftui.xcodeproj` in Xcode, set up your Apple ID team in *Signing & Capabilities*, plug in an iPhone, hit ⌘R. See **RUNTIME_STATUS.md** for the full deploy walkthrough.

---

## Why these specific changes

llama.cpp's stock iOS example (`examples/llama.swiftui`) is text-only. It links a Swift Package–style `llama.xcframework` that doesn't include `tools/mtmd` (the multimodal pipeline that handles CLIP image encoding + image-token injection). To get vision on iPhone:

1. **Build mtmd into the framework.** Stock `build-xcframework.sh` sets `LLAMA_BUILD_TOOLS=OFF`. Flipping it to ON pulls in mtmd, but the multi-platform pipeline trips over visionOS feature detection in `common/`. So we ship a focused iOS-only build script that only links what's needed (`libllama.a + libggml*.a + libmtmd.a`), excludes `common`/`httplib` (mtmd doesn't need them — verified via `target_link_libraries` in `tools/mtmd/CMakeLists.txt`), and exposes only the public mtmd headers (`mtmd.h`, `mtmd-helper.h`) in the framework modulemap. `mtmd-image.h` and `mtmd-audio.h` are excluded because they `#include "clip-model.h"` which isn't part of the public API.

2. **Wire the Swift side.** `LibLlama.swift` gains a `ctx_vision: OpaquePointer?` field, a `loadMmproj()` method, and a `completion_init_with_image()` method that calls `mtmd_helper_bitmap_init_from_file → mtmd_tokenize → mtmd_helper_eval_chunks` to prefill image tokens into the KV cache. After that, the existing `completion_loop()` continues sampling tokens normally. The `n_past` and `n_cur` accounting is identical to the text-only path.

3. **Bundle the GGUFs.** Both the main model and the mmproj are dropped into `Resources/models/`. The pbxproj already references that directory as a folder reference, so they're packaged into the .app bundle without any project-file edit. `LlamaState.swift` resolves them via `Bundle.main.url(forResource:withExtension:subdirectory:)`. App bundle ends up ~3.8 GB.

4. **UI.** A `PhotosPicker` button next to Send. On select, the image is written to `temporaryDirectory` as JPEG q92, and the path is passed to `complete(text:, imagePath:)`.

---

## Performance reference (Mac mini M4, llama.cpp Metal)

```
| model                    |  size   | params | backend  | threads |  test  |       t/s |
|--------------------------|---------|--------|----------|---------|--------|-----------|
| gemma4 E2B Q4_K - Medium | 2.88GiB | 4.65 B | MTL,BLAS |    8    | pp256  |  758 ± 1  |
| gemma4 E2B Q4_K - Medium | 2.88GiB | 4.65 B | MTL,BLAS |    8    | tg128  |  57 ± 0.04|
```

Expected on iPhone 16 Pro (~3-4× slower for memory-bandwidth-bound inference):
- Text decode: **~15-20 tok/s**
- Text prefill: **~200 tok/s**
- Image processing (CLIP → 256 image tokens): **~1-3 sec one-time per image**
- Cold load: **~5-10 sec** (mmap of 3.8 GB bundle)

---

## License

The patched Swift files inherit Apache 2.0 from llama.cpp upstream. This repo's README + scripts are MIT — do whatever.

The Gemma 4 model weights are governed by Google's [Gemma Terms of Use](https://ai.google.dev/gemma/terms).
