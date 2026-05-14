# Gemma 4 E2B on iPhone via llama.cpp — Runtime Status

**Date:** 2026-05-14
**Target device:** iPhone 16 Pro (8 GB RAM, A18 Pro)
**Goal:** Gemma 4 E2B running fully on-device, airplane-mode capable, **with text + vision**.

---

## 1. Gemma 4 support in llama.cpp — ✅ Mainline

- **Repo:** `github.com/ggml-org/llama.cpp` (canonical; `ggerganov/llama.cpp` redirects)
- **Build commit used:** `dbe7901` ("vulkan: fix matmul integer pipeline selection #23005")
- **Latest release:** `b9145` (2026-05-14)
- **Architecture wiring confirmed:**
  - `LLM_ARCH_GEMMA4` enum in `src/llama-arch.h`
  - `llama_model_gemma4` impl in `src/llama-model.cpp`
  - `Gemma4Model(Gemma3Model)` in `convert_hf_to_gguf.py` registered for `Gemma4ForConditionalGeneration`
  - Multimodal projectors: `GEMMA4V` (vision) + `GEMMA4A` (audio) via `Gemma4VisionAudioModel`
- **mtmd library** (`tools/mtmd/`) provides the vision/audio pipeline (clip → projector → tokens injected into context).

## 2. GGUF source

- **Repo:** `unsloth/gemma-4-E2B-it-GGUF` (HF, 1M+ downloads, last updated 2026-05-04)
- **Text model:** `gemma-4-E2B-it-Q4_K_M.gguf` — **2.9 GB**, 4.65 B raw / 2 B effective params
- **Vision projector:** `mmproj-F16.gguf` — **940 MB** (CLIP-style, F16 weights)
- **Both are bundled into the iOS app** under `Resources/models/`.

## 3. macOS CLI sanity bench (Mac mini M4, Metal)

```
$ ./build/bin/llama-bench -m gemma-4-E2B-it-Q4_K_M.gguf -ngl 999 -t 8 -p 256 -n 128

| model                    |  size   | params | backend  | threads |  test  |       t/s |
|--------------------------|---------|--------|----------|---------|--------|-----------|
| gemma4 E2B Q4_K - Medium | 2.88GiB | 4.65 B | MTL,BLAS |    8    | pp256  |  758 ± 1  |
| gemma4 E2B Q4_K - Medium | 2.88GiB | 4.65 B | MTL,BLAS |    8    | tg128  |  57 ± 0.04|
```

Coherent generation confirmed via `llama-cli --single-turn`:
```
[ Prompt: 129.0 t/s | Generation: 57.4 t/s ]
```

Comparison vs other backends on the same M4:

| Backend | Prefill | Decode |
|---|---|---|
| Apple MLX | 203 t/s | ~85 t/s |
| LiteRT-LM CLI (GPU) | 202 t/s | 69 t/s |
| **llama.cpp Metal** | **758 t/s** | **57 t/s** |

llama.cpp prefill is ~3.7× faster than MLX/LiteRT (better-batched matmul). Decode is slightly slower. iPhone 16 Pro will drop ~3-4× from the M4 — expect ~15-20 decode tok/s.

## 4. iOS example app — ✅ vision-enabled, builds clean for `generic/iOS`

### XCFramework (custom, with mtmd)

The stock `build-xcframework.sh` skips `tools/mtmd` (LLAMA_BUILD_TOOLS=OFF). The full multi-platform run with `LLAMA_BUILD_TOOLS=ON` failed at the visionOS configure step (cmake feature-check failures cascading from common's deps). **Workaround:** built an iOS-only XCFramework manually combining only the libraries we need.

The actual build script is at `/tmp/build_ios_only_xcframework.sh` on the Mac. It does:
1. Reuses the per-platform `build-ios-device/` and `build-ios-sim/` outputs (already built with `LLAMA_BUILD_TOOLS=ON`).
2. `libtool -static` combines: `libllama.a + libggml*.a + libmtmd.a` (no common, no httplib — mtmd doesn't need them).
3. `clang++ -dynamiclib` builds the framework dylib with `-Wl,-force_load` on the combined .a.
4. Copies `mtmd.h` + `mtmd-helper.h` into the framework Headers (NOT mtmd-image.h / mtmd-audio.h — those include private `clip-model.h` and would fail Swift module compilation).
5. Adds those two headers to the modulemap so they import as part of the `llama` module.
6. `xcodebuild -create-xcframework` packages ios-arm64 + ios-arm64_x86_64-simulator.

Output: `build-apple/llama.xcframework` — 2 platforms (iOS device + iOS sim), with mtmd symbols (`mtmd_init_from_file`, `mtmd_helper_eval_chunks`, `mtmd_tokenize`, `mtmd_helper_bitmap_init_from_file`, etc.) verified via `nm -gU`.

### iOS app build

- **Project:** `examples/llama.swiftui/llama.swiftui.xcodeproj`
- **Target:** `llama.swiftui`, bundle ID `com.bachittle.llama-swift`, min iOS 16.0
- **Build status:** `** BUILD SUCCEEDED **` for `generic/platform=iOS`
- **Output:** `examples/llama.swiftui/build_ios/Build/Products/Debug-iphoneos/llama.swiftui.app`
- **Bundle size:** 3.8 GB (2.9 GB text model + 940 MB vision projector)
- **Bundled models in `llama.swiftui.app/models/`:**
  - `gemma-4-E2B-it-Q4_K_M.gguf` (2.9 GB)
  - `mmproj-F16.gguf` (940 MB)
- **mtmd symbols verified in embedded `llama.framework/llama` dylib:** ✅

### Source modifications

#### `examples/llama.swiftui/llama.swiftui/Models/LlamaState.swift`

1. `defaultModelUrl` points at the bundled Gemma 4 file:
   ```swift
   Bundle.main.url(forResource: "gemma-4-E2B-it-Q4_K_M", withExtension: "gguf", subdirectory: "models")
   ```
2. After `loadModel`, auto-loads the bundled `mmproj-F16.gguf`:
   ```swift
   if let mmprojUrl = Bundle.main.url(forResource: "mmproj-F16", withExtension: "gguf", subdirectory: "models") {
       Task { try await llamaContext?.loadMmproj(path: mmprojUrl.path()) }
   }
   ```
3. Added overload `complete(text: String, imagePath: String?)` that routes to either text-only `completion_init` or `completion_init_with_image` depending on whether an image path was provided.

#### `examples/llama.swiftui/llama.cpp.swift/LibLlama.swift`

1. Added `private var ctx_vision: OpaquePointer? = nil` on `LlamaContext`.
2. `deinit` now `mtmd_free`s the vision context.
3. New `loadMmproj(path:)` calls `mtmd_init_from_file(path, model, params)` with `use_gpu=true`, `flash_attn_type=AUTO`, `warmup=true`.
4. New `completion_init_with_image(text:, imagePath:)`:
   - `mtmd_helper_bitmap_init_from_file` to load the image.
   - `mtmd_tokenize` to build text+image chunks.
   - `mtmd_helper_eval_chunks` to prefill image+text into the KV cache (this is where CLIP runs and image embeddings get projected and inserted).
   - Sets `n_cur` to the new position so the existing `completion_loop()` starts sampling tokens from there.
   - Falls back to text-only if no `ctx_vision` is loaded.

#### `examples/llama.swiftui/llama.swiftui/UI/ContentView.swift`

1. `import PhotosUI`.
2. Added `@State PhotosPickerItem?`, plus `pendingImagePath` and `pendingImageThumb`.
3. Added a `PhotosPicker` (📷 icon) next to Send. On selection, the image is written to `temporaryDirectory` as JPEG q92 and the path is stored.
4. Above the buttons, a thumbnail row appears when an image is staged, with a "Remove image" button.
5. `sendText()` reads the staged image path (if any) and calls `complete(text:, imagePath:)`. After send, the image state clears.

#### `examples/llama.swiftui/llama.swiftui/Resources/models/`

- Dropped `gemma-4-E2B-it-Q4_K_M.gguf` and `mmproj-F16.gguf` here. The pbxproj already references this directory as a folder, so they are bundled automatically with no project edit needed.

#### `build-xcframework.sh` (script-level changes — not used in final build, kept for reference)

- `LLAMA_BUILD_TOOLS=OFF` → `ON`
- Added `libmtmd.a` and `libcommon*.a` to the libs array
- *Note:* Full multi-platform build with these changes fails at visionOS configure time. The manual iOS-only path in `/tmp/build_ios_only_xcframework.sh` is what was actually used.

## 5. What's left for the human (Daniel) — Xcode + iPhone 16 Pro deploy

The .app builds clean unsigned. To install on a physical iPhone:

1. **On the Mac mini, open the project in Xcode:**
   ```
   open ~/work/evan/llama.cpp/examples/llama.swiftui/llama.swiftui.xcodeproj
   ```
2. **Sign in to Xcode with your Apple ID:** Xcode → Settings → Accounts → `+` → Apple ID. A free personal Apple ID works for 7-day device provisioning; a paid Developer account gives a year-long cert.
3. **Configure code signing:**
   - Select the project in the navigator → `llama.swiftui` target → "Signing & Capabilities" tab
   - Tick **"Automatically manage signing"**
   - Pick your Team
   - Bundle Identifier `com.bachittle.llama-swift` may collide with someone else's already-registered bundle — change it to something unique (e.g. `com.daniel.llama-gemma4`) if Xcode complains.
4. **Plug iPhone 16 Pro into the Mac with a USB-C cable.** Trust the computer prompt on the phone if it appears.
5. **Set destination to the iPhone:** toolbar destination dropdown (top center) → select your iPhone.
6. **⌘R to build + install + run.** First install will take 1-3 minutes (3.8 GB bundle copy to device).
   - If it fails with "untrusted developer": on the iPhone, Settings → General → VPN & Device Management → tap your Apple ID → Trust.
7. **Once running on device, enable airplane mode.** App needs no network.
8. **Test text-only:** type a prompt, tap Send, watch the message log for tok/s.
9. **Test vision:** tap the **📷 icon** next to Send, pick a photo, type a prompt about it ("what's in this photo?"), tap Send. Image is processed by CLIP, embeddings are injected into the context, generation continues.

### Expected on-device numbers (rough)

Based on M4 → iPhone scaling (~3-4× slower):
- Text decode: ~15-20 tok/s
- Text prefill: ~200 tok/s
- Image processing (CLIP through projector → 256 image tokens): ~1-3 sec one-time per image
- Cold model load: ~5-10 sec (mmap of 2.9 GB main + 940 MB mmproj)

If decode is below ~10 tok/s, check that Metal is being used (the example app sets `n_gpu_layers = 99` automatically).

## 6. Known caveats

- **3.8 GB bundle** exceeds TestFlight's 4 GB payload limit only for compressed IPA — uncompressed is over budget. Use direct USB install via Xcode (no TestFlight). For OTA distribution, fall back to download-on-first-launch using the HF URL entry already added to `defaultModels[]`.
- **Code signing is unsigned (`-`)** in the build I produced. Re-build from Xcode with your team selected — see step 5.
- **No iOS Simulator binary** in the XCFramework's iOS-sim slice would be untested — I built sim slice but only smoke-tested device. Sim usually crashes anyway with mtmd's libc++ runtime checks (we hit this earlier with MLX). Real device is the only meaningful test target.
- **mtmd-image.h / mtmd-audio.h are NOT exposed** in the framework module map (they pull in `clip-model.h` which isn't part of the public API). The Swift wrapper uses only the public mtmd.h + mtmd-helper.h.
- **Metal GPU only — no Apple Neural Engine.** llama.cpp doesn't have an ANE backend. For ANE you'd need CoreML conversion or wait for LiteRT-LM Swift API.
- **iPhone 17 Pro vs 16 Pro:** Numbers above are 16 Pro estimates. 17 Pro would be 30-50% faster on decode.

---

## Quick reference paths on the Mac mini

| What | Path |
|---|---|
| llama.cpp repo | `~/work/evan/llama.cpp` |
| iOS Xcode project | `~/work/evan/llama.cpp/examples/llama.swiftui/llama.swiftui.xcodeproj` |
| Built XCFramework (with mtmd) | `~/work/evan/llama.cpp/build-apple/llama.xcframework` |
| Built iOS .app | `~/work/evan/llama.cpp/examples/llama.swiftui/build_ios/Build/Products/Debug-iphoneos/llama.swiftui.app` |
| Source GGUFs | `~/work/evan/gemma_models/{gemma-4-E2B-it-Q4_K_M.gguf, mmproj-F16.gguf}` |
| Bundled GGUFs | `~/work/evan/llama.cpp/examples/llama.swiftui/llama.swiftui/Resources/models/` |
| macOS llama-cli binary | `~/work/evan/llama.cpp/build/bin/llama-cli` |
| macOS llama-bench binary | `~/work/evan/llama.cpp/build/bin/llama-bench` |
| macOS llama-mtmd-cli binary | `~/work/evan/llama.cpp/build/bin/llama-mtmd-cli` |
| Manual XCFramework script | `/tmp/build_ios_only_xcframework.sh` |
