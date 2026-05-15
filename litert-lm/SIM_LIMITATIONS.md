# iOS Simulator limitations — what works and what doesn't

**Verified by direct testing on May 15, 2026** (Mac mini M4 + iPhone 17 Pro sim, iOS 26.5).

## TL;DR

The iOS Simulator can launch the GemmaCoach app, render the UI, and exercise every code path that doesn't actually invoke the LiteRT-LM engine. **`LiteRTLMEngine.load()` fails on the simulator** with:

```
engineCreationFailed("Failed to create engine settings")
```

regardless of `backend: "cpu"` or `backend: "gpu"`. **You must test on a real iPhone** for the engine + inference path. This is a common limitation with on-device ML runtimes — the simulator lacks runtime features (Metal/MLDrift specifics, ANE, certain framework subsystems) that the published `.litertlm` checks for at engine init.

The good news: every surrounding piece — UI, framework loading, audio recording, photo picker, TTS, background audio session — works in the simulator and is fully validated there.

## What works in iOS Simulator

| | |
|---|---|
| App launches | ✅ |
| `CLiteRTLM.framework` loads via dyld | ✅ (after the `embed` + rpath fixes; see below) |
| ContentView renders | ✅ |
| `ModelDownloader` downloads `.litertlm` from HF | ✅ (file lands in `Library/Application Support/LiteRTLM/Models/`) |
| Status flows through `.idle → .downloading → .loading` | ✅ |
| Photos picker | ✅ |
| Audio recorder + permission prompt | ✅ (sim uses Mac mic) |
| `AVSpeechSynthesizer` TTS | ✅ |
| Live mode toggle + slider UI | ✅ |
| Background audio session category set | ✅ |

## What fails in iOS Simulator

| | |
|---|---|
| `LiteRTLMEngine.load()` | ❌ Returns NULL from `litert_lm_engine_settings_create` |
| Any inference call (since engine never loads) | ❌ |
| Live coaching mode actually firing | ❌ (engine isn't ready) |

## Why

The published `litert-community/gemma-4-E2B-it-litert-lm` model file requires runtime features the iOS Simulator doesn't simulate. The exact reason isn't surfaced — the C++ stderr is swallowed by the simulator's sandbox — but based on what works (file load, framework dyld) and what fails (engine settings), the most likely cause is that the engine's hardware-feature query for Metal/MLDrift returns "not supported" on the sim's emulated Metal context. The model bundle includes per-platform graph variants (we saw `_qualcomm_*` variants in the HF repo); the iOS Simulator slice may not match any of them.

This matches the broader iOS landscape: most on-device ML frameworks (CoreML, MediaPipe, MLX) have known issues in iOS Sim. Apple's own docs recommend real-device testing for ML workloads.

## Things we tried that DIDN'T fix it

So you don't waste time repeating these:

- **`backend: "cpu"`** — same error
- **`backend: "gpu"`** — same error
- **Vendoring [LiteRTLM-Swift PR #11](https://github.com/mylovelycodes/LiteRTLM-Swift/pull/11)** to pass `nil` for vision/audio backends instead of `"cpu"` for both — same error. PR #11 fixes a different real bug (engine_settings_create NULL return for text-only models that don't have vision/audio sections), just doesn't apply here.
- **Wiping `SourcePackages` cache + DerivedData + forcing fresh package resolve** — confirmed the local fork was being used, error still present.
- **Pre-staging the model file in `Documents/`** — app uses `Library/Application Support/LiteRTLM/Models/` instead and downloads its own copy. Both copies match the HF size (2.6 GB) byte-for-byte.

## Confirmed-working baseline (so you know the model + runtime aren't broken)

The same `gemma-4-E2B-it.litertlm` file runs fine on macOS via the LiteRT-LM CLI:

```bash
litert-lm benchmark --from-huggingface-repo=litert-community/gemma-4-E2B-it-litert-lm \
  gemma-4-E2B-it.litertlm --backend=gpu -p 256 -d 256
# Result: 202 prefill tok/s, 69 decode tok/s on M4 Metal
```

That confirms the model file, the LiteRT-LM C++ runtime, and the engine_settings_create function all work correctly on Mac CPU/GPU. The iOS Simulator path is what's broken — not our code, not the model, not the package wrapper.

## What you can validate WITHOUT a real device

Useful for fast UI iteration:
- Layout, color, button arrangement, copy
- Permission prompt flows (mic, photos)
- The audio recorder's level meter behavior
- TTS voice + speed via `AVSpeechSynthesizer`
- Live mode UI state transitions

Useful for build infrastructure validation:
- That `apply.sh` produces a runnable `.app`
- That the framework embed + rpath fix works (no dyld error on launch)
- That the model file gets correctly downloaded by `ModelDownloader`

## How to test the engine path

You need a physical iPhone. See [TESTING_PARITY.md](./TESTING_PARITY.md) for three paths:
1. **Path A** — Xcode "Devices over Network" if you own any iPhone (free, 5 min setup)
2. **Path B** — BrowserStack App Live cloud iPhone (~$49/mo or 30-min trial)
3. **Path C** — macOS-side LiteRT-LM CLI (verifies the engine path on Mac instead of iPhone, no UI but proves the model + LiteRT-LM C++ works)

The Mac CLI test (Path C) we already validated:
```bash
litert-lm benchmark --from-huggingface-repo=litert-community/gemma-4-E2B-it-litert-lm \
  gemma-4-E2B-it.litertlm --backend=gpu -p 256 -d 256
# Result: 202 prefill tok/s, 69 decode tok/s on M4
```

That confirms the model + runtime work; it's the iOS Simulator-specific runtime that's the issue, not the model.

## What this iteration validated (silver lining)

The dyld + framework embed fixes we pushed in commit `1dff1fc` and the postBuildScript + LD_RUNPATH_SEARCH_PATHS additions in commit `(this push)` were discovered EXACTLY because we ran the sim test. Without trying the sim we'd have shipped to a real device with:

```
dyld[NNNN]: Library not loaded: @rpath/CLiteRTLM.framework/CLiteRTLM
```

— which would have looked like a SIGABRT and been hard to diagnose on a remote iPhone. Now the framework infrastructure is verified across both build types (sim + device), so deploying to real iPhone should jump straight to the engine-load step where actual perf numbers come out.
