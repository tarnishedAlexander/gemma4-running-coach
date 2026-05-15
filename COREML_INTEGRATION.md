# CoreML-LLM Integration: From Upstream Repo to Running Coach App

> **Branch:** `main2`  
> **Date:** 2026-05-15  
> **App:** GemmaCoach — an on-device multimodal running coach for visually impaired athletes  
> **Model:** Gemma 4 E2B (2-billion parameter, multimodal: text + vision + audio)  
> **Runtime:** [CoreML-LLM](https://github.com/john-rocky/CoreML-LLM) v1.9.0 by john-rocky

---

## Table of Contents

1. [Why We Switched to CoreML-LLM](#1-why-we-switched-to-coreml-llm)
2. [Upstream Library Architecture](#2-upstream-library-architecture)
3. [What the Upstream Code Does](#3-what-the-upstream-code-does)
4. [The Problem We Hit: Background URLSession Hang](#4-the-problem-we-hit-background-urlsession-hang)
5. [Our Solution: GemmaDownloader](#5-our-solution-gemmadownloader)
6. [File-by-File Breakdown](#6-file-by-file-breakdown)
7. [Model File Structure on Disk](#7-model-file-structure-on-disk)
8. [EngineModel: Wrapping CoreMLLLM for SwiftUI](#8-enginemodel-wrapping-coremlllm-for-swiftui)
9. [Multimodal Pipeline for the Running Coach](#9-multimodal-pipeline-for-the-running-coach)
10. [Performance Characteristics](#10-performance-characteristics)
11. [Architecture Diagram](#11-architecture-diagram)

---

## 1. Why We Switched to CoreML-LLM

The project originally targeted Google's **LiteRT-LM** runtime (the community Swift wrapper `mylovelycodes/LiteRTLM-Swift`). After building and deploying to a physical iPhone, the engine consistently failed with:

```
Load failed: Failed to create engine settings
litert_lm_engine_create returned NULL
```

Binary analysis of the `CLiteRTLM.xcframework` revealed that the prebuilt `.dylib` expected backend strings `"gpu_artisan"` / `"cpu_artisan"` / `"xnnpack"` — not the documented `"gpu"` / `"cpu"`. Even after correcting the backend strings, `litert_lm_engine_settings_create` itself returned `NULL`, indicating a fundamental incompatibility between the prebuilt binary and either the model file format or the specific iOS version.

**CoreML-LLM** was chosen as the replacement because:

| Criterion | LiteRT-LM | CoreML-LLM |
|---|---|---|
| Runtime | Google's TensorFlow Lite | Apple's CoreML (native) |
| Acceleration | GPU (Metal) | ANE + CPU (Apple Neural Engine) |
| iOS minimum | 17.0 | 18.0 |
| Model format | `.task` TFLite | `.mlmodelc` compiled CoreML |
| Multimodal | Text only (at time of testing) | Text + Vision + Audio |
| Deployment | SPM binary xcframework | SPM source package |
| Gemma 4 E2B | Broken on device | 34 tok/s on A19 Pro |

---

## 2. Upstream Library Architecture

The upstream `john-rocky/CoreML-LLM` package is structured as follows:

```
Sources/CoreMLLLM/
├── CoreMLLLM.swift              ← Public API (load, stream, generate)
├── ModelDownloader.swift        ← HuggingFace download manager
├── ModelConfig.swift            ← Loads model_config.json
├── ChunkedEngine.swift          ← 4-chunk decode engine
├── Gemma4StatefulEngine.swift   ← Stateful MLState KV-cache variant
├── Gemma4StatefulMultimodalEngine.swift
├── ImageProcessor.swift         ← CGImage → model tensor
├── AudioProcessor.swift         ← [Float] PCM → mel spectrogram
├── EmbeddingLookup.swift        ← embed_tokens_q8.bin INT8 lookup
├── PrefixCache.swift            ← KV-cache prefix reuse
├── SpeculativeLoop.swift        ← Speculative decoding (optional)
└── VideoProcessor.swift         ← Video frame sampling
```

### Public API Surface

```swift
// Load (download if needed, then compile)
public static func load(
    from directory: URL,
    computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
    onProgress: ((String) -> Void)? = nil
) async throws -> CoreMLLLM

// Convenience overload — uses ModelDownloader internally
public static func load(
    model: ModelDownloader.ModelInfo,
    computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
    onProgress: ((String) -> Void)? = nil
) async throws -> CoreMLLLM

// Streaming generation (returns AsyncStream<String>)
public func stream(
    _ prompt: String,
    image: CGImage? = nil,
    audio: [Float]? = nil,
    maxTokens: Int = 2048
) async throws -> AsyncStream<String>

// Buffered single-shot generation
public func generate(
    _ prompt: String,
    image: CGImage? = nil,
    audio: [Float]? = nil,
    maxTokens: Int = 2048
) async throws -> String

// Multi-turn conversation variants
public func stream(_ messages: [Message], ...) async throws -> AsyncStream<String>
public func generate(_ messages: [Message], ...) async throws -> String
```

### ModelDownloader

`ModelDownloader` is an `@Observable` singleton (`ModelDownloader.shared`) that manages downloading model files from HuggingFace. Model identities are typed as static properties on a nested `ModelInfo` struct:

```swift
public static let gemma4e2b = ModelInfo(
    id: "gemma4-e2b",
    name: "Gemma 4 E2B (4-chunk legacy)",
    size: "5.4 GB",
    downloadURL: "https://huggingface.co/mlboydaisuke/gemma-4-E2B-coreml/resolve/n1024",
    folderName: "gemma4-e2b"
)
```

Observable progress properties:
```swift
public var isDownloading: Bool   // active download in progress
public var isPaused: Bool
public var progress: Double      // 0.0 → 1.0
public var status: String        // "120 / 5400 MB"
public var downloadingModelId: String?
```

---

## 3. What the Upstream Code Does

### Download Flow (`ModelDownloader.download(_:)`)

```
User calls download(_:)
        │
        ▼
localModelURL(for:) ──► model cached? ──► return cached URL immediately
        │ no
        ▼
withCheckedThrowingContinuation { ... }
        │
        ├── DispatchQueue.main.async
        │       └── runAfterAdoption {
        │               buildHuggingFaceFileList(model)  // hardcoded file manifest
        │               fillDownloadSlots()              // start up to 4 concurrent tasks
        │           }
        │
        ├── URLSessionDownloadDelegate.didWriteData
        │       └── DispatchQueue.main.async { updateProgress() }
        │
        └── URLSessionDownloadDelegate.didFinishDownloadingTo
                └── move temp → dest, fillDownloadSlots() (next file)
                        └── when all done → finishDownload()
                                ├── hardlink prefill weights from decode chunks
                                └── continuation.resume(returning: localURL)
```

### Load Flow (`CoreMLLLM.load(from:)`)

```
CoreMLLLM.load(from: modelDirectory)
        │
        ├── Read model_config.json  → context length, model type
        ├── Load tokenizer.json     → SentencePiece/BPE vocab
        ├── Load embed_tokens_q8.bin → INT8 embedding table
        ├── Compile chunk1-4.mlmodelc with MLComputeUnits
        ├── Compile prefill_chunk1-4.mlmodelc
        ├── (optional) Compile vision.mlmodelc
        ├── (optional) Compile audio.mlmodelc
        └── Return CoreMLLLM instance ready to generate
```

### Inference Flow

```
llm.stream(prompt, image: cgImage, audio: floats)
        │
        ├── ImageProcessor: CGImage → 896×896 RGB tensor (SigLIP format)
        ├── AudioProcessor: [Float] → mel spectrogram → audio.mlmodelc → embeddings
        ├── EmbeddingLookup: tokenize prompt → INT8 lookup in embed_tokens_q8.bin
        ├── ChunkedEngine.prefill(): process full context through prefill chunks
        ├── ChunkedEngine.decode(): autoregressive decode loop
        │       ├── chunk1 → chunk2 → chunk3 → chunk4 (pipeline)
        │       └── KV-cache managed in-process
        └── yield token strings via AsyncStream<String>
```

---

## 4. The Problem We Hit: Background URLSession Hang

The upstream `ModelDownloader` uses `URLSessionConfiguration.background(withIdentifier:)`:

```swift
// From upstream ModelDownloader.swift
let config = URLSessionConfiguration.background(
    withIdentifier: "com.coreml-llm.model-download"
)
config.isDiscretionary = false
config.sessionSendsLaunchEvents = true
config.timeoutIntervalForResource = 7200
session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
```

**Background URLSession on iOS requires the app to implement:**

```swift
// In AppDelegate or @UIApplicationDelegateAdaptor
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    // Reconnect to background session, call completionHandler when done
}
```

Without this, the system daemon (`nsurlsessiond`) buffers the download events but never delivers them to our app's delegate. The result:

- `didWriteData` never fires → `progress` stays `0.0` forever
- `didFinishDownloadingTo` never fires → `finishDownload()` never called
- `continuation.resume(returning:)` never called → `download()` hangs indefinitely

Additionally, `ModelDownloader` uses a task-adoption pattern (`runAfterAdoption`) that waits for `session.getAllTasks { }` to complete before starting downloads. In some race conditions with our `@MainActor` call site, this adoption callback could be queued behind other main-thread work and delay download start.

**Symptom:** Progress bar stuck at 0% for 10+ minutes with no error shown, because the hanging continuation never throws either.

---

## 5. Our Solution: GemmaDownloader

We reverse-engineered the exact file manifest from `ModelDownloader.buildHuggingFaceFileList()` and rewrote the download layer as a focused, foreground-URLSession downloader dedicated to this app.

### Key Design Decisions

| Decision | Reason |
|---|---|
| `URLSessionConfiguration.default` (foreground) | Delegate callbacks fire immediately without app-delegate setup |
| One `URLSession` per file | Clean lifecycle — session and delegate deallocate when file completes |
| `URLSessionDownloadTask` (not `dataTask`) | Streams to disk via OS temp file — no memory pressure for 2.35 GB files |
| Sequential download, largest-first | Simple error handling; large files dominate time so sorting gives steady progress |
| `@MainActor` class | Direct `@Published` mutations from progress callbacks without extra dispatch |
| `withCheckedThrowingContinuation` | Clean async/await bridge per file — errors propagate naturally |
| Skip existing non-zero-byte files | Resumable across app relaunches |
| Hardlink prefill weights post-download | Saves 682 MB of duplicate disk space (same as upstream `finishDownload`) |

### How It Works

```
EngineModel.loadIfNeeded()  [@MainActor]
        │
        ├── GemmaDownloader.download()
        │       │
        │       ├── Create Documents/Models/gemma4-e2b/
        │       ├── Count already-downloaded bytes → start progress correctly
        │       ├── Filter: files missing or zero-byte
        │       ├── Sort: largest estimatedBytes first
        │       │
        │       └── for each file:
        │               downloadOne(from: HF_URL, to: localPath)
        │                       │
        │                       ├── withCheckedThrowingContinuation
        │                       ├── URLSession(config: .default, delegate: FileDelegate)
        │                       ├── session.downloadTask(with: url).resume()
        │                       │
        │                       ├── FileDelegate.didWriteData
        │                       │       └── Task { @MainActor } → onProgress(Double, String)
        │                       │               └── EngineModel.status = .downloading(progress:)
        │                       │
        │                       └── FileDelegate.didFinishDownloadingTo
        │                               ├── check HTTP 200
        │                               ├── FileManager.moveItem(temp → dest)
        │                               └── continuation.resume(.success(bytes))
        │
        ├── linkPrefillWeights()  — hardlink decode → prefill weight.bin files
        │
        └── return Documents/Models/gemma4-e2b/
                │
                ▼
        CoreMLLLM.load(from: modelDir, computeUnits: .cpuAndNeuralEngine)
                │
                └── onProgress: String → EngineModel.loadingMessage
```

---

## 6. File-by-File Breakdown

### `GemmaDownloader.swift` (new — our code)

**What it does:**  
Downloads all Gemma 4 E2B model files from HuggingFace to `Documents/Models/gemma4-e2b/` using a foreground `URLSession`. Reports byte-accurate progress. Performs post-download weight linking.

**Key types:**

```swift
struct GemmaFile {
    let remotePath: String     // relative to baseURL (HuggingFace)
    let localPath: String      // relative to modelDirectory
    let estimatedBytes: Int64  // used for progress denominator
}

@MainActor
final class GemmaDownloader {
    var onProgress: ((Double, String) -> Void)?
    func download() async throws -> URL  // → Documents/Models/gemma4-e2b/
}

private final class FileDelegate: NSObject, URLSessionDownloadDelegate {
    // One instance per file. Calls onBytes for progress, onDone for completion.
}
```

**Upstream correspondence:**  
`GemmaDownloader` replaces `ModelDownloader.shared.download(ModelInfo.gemma4e2b)`.  
`FileDelegate` replaces `ModelDownloader`'s `URLSessionDownloadDelegate` extension.  
`linkPrefillWeights()` replaces `ModelDownloader.finishDownload()`'s weight-sharing logic.

---

### `EngineModel.swift` (heavily modified)

**Original (LiteRT-LM):**
```swift
import LiteRTLMSwift

private var engine: LiteRTLMEngine?

func loadIfNeeded() async {
    let e = LiteRTLMEngine(modelPath: url, backend: "gpu_artisan")
    try await e.load()
    engine = e
}

func generateText(_ prompt: String, maxTokens: Int = 256) async {
    let stream = engine.generateStreaming(prompt: formatted, maxTokens: maxTokens)
    for try await chunk in stream { output += chunk }
}
```

**Current (CoreML-LLM):**
```swift
import CoreMLLLM

private var llm: CoreMLLLM?

func loadIfNeeded() async {
    // Phase 1: our custom downloader with real progress
    let downloader = GemmaDownloader()
    downloader.onProgress = { [weak self] (progress, message) in
        self?.status = .downloading(progress: progress)
        self?.loadingMessage = message
    }
    let modelDir = try await downloader.download()

    // Phase 2: CoreML compile + load
    let model = try await CoreMLLLM.load(
        from: modelDir,
        computeUnits: .cpuAndNeuralEngine,
        onProgress: { [weak self] msg in
            Task { @MainActor [weak self] in self?.loadingMessage = msg }
        }
    )
    llm = model
}

func generateText(_ prompt: String, maxTokens: Int = 256) async {
    // AsyncStream<String> (non-throwing) — different from LiteRT's AsyncThrowingStream
    let stream = try await llm.stream(formatted, maxTokens: maxTokens)
    for await chunk in stream { output += chunk }
}
```

**Key differences from upstream usage:**  
- We don't use `CoreMLLLM.load(model:)` because it calls `ModelDownloader.shared.download()` internally — the broken background URLSession path
- We call `CoreMLLLM.load(from: directory)` directly after our own download
- `stream()` returns `AsyncStream<String>` (not `AsyncThrowingStream`) — loop uses `for await`, not `for try await`

---

### `project.yml` (modified)

```yaml
# Before (LiteRT-LM)
deploymentTarget:
  iOS: "17.0"
packages:
  LiteRTLMSwift:
    url: https://github.com/mylovelycodes/LiteRTLM-Swift.git
    branch: main
postBuildScripts:
  - name: Sign Nested Dylibs   # needed because LiteRT ships unsigned dylibs
    script: |
      find "${CODESIGNING_FOLDER_PATH}" -name "*.dylib" | while read dylib; do
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${dylib}"
      done

# After (CoreML-LLM)
deploymentTarget:
  iOS: "18.0"               # CoreML-LLM requires iOS 18
packages:
  CoreMLLLM:
    url: https://github.com/john-rocky/CoreML-LLM.git
    from: "1.9.0"
# postBuildScripts removed — CoreML-LLM is pure Swift, no dylibs to re-sign
```

---

### `AudioRecorder.swift` (minor fix)

Fixed deprecated iOS 17 `AVFoundation` APIs:

```swift
// Before (deprecated in iOS 17)
AVAudioSession.sharedInstance().recordPermission
AVAudioSession.requestRecordPermission { granted in ... }
session.setCategory(.playAndRecord, options: [.allowBluetooth])

// After (iOS 17+)
AVAudioApplication.shared.recordPermission
await AVAudioApplication.requestRecordPermission()
session.setCategory(.playAndRecord, options: [.allowBluetoothHFP])
```

---

### `LiveSession.swift` (minor fix)

Removed the `import LiteRTLMSwift` statement that was left after switching backends. `LiveSession` only uses `EngineModel` and `CoachSpeaker` — no direct runtime dependency.

---

### `ContentView.swift` (UI enhanced)

Added explicit download UX:

```swift
// Idle state: explicit button instead of auto-load
case .idle:
    Button("Download & Load Model") {
        Task { await engine.loadIfNeeded() }
    }

// Downloading: real progress bar + live status string from GemmaDownloader
case .downloading(let p):
    ProgressView(value: max(p, 0.005), total: 1.0)
    Text(engine.loadingMessage)   // "1240 / 5400 MB"

// Loading: indeterminate spinner + CoreMLLLM phase message
case .loading:
    ProgressView()
    Text(engine.loadingMessage)   // "Loading tokenizer…", "Compiling chunk1…"

// Error: message + Retry button
case .error(let msg):
    Label(msg, systemImage: "xmark.octagon.fill")
    Button("Retry") { Task { await engine.loadIfNeeded() } }
```

---

## 7. Model File Structure on Disk

After a successful download, `Documents/Models/gemma4-e2b/` contains:

```
gemma4-e2b/
├── chunk1.mlmodelc/                    # Decode chunk 1 (SWA layers 1-6)
│   ├── weights/weight.bin              # 155 MB  — ANE weight binary
│   ├── coremldata.bin                  # CoreML model descriptor
│   ├── model.mil                       # MIL IR (for debugging)
│   ├── metadata.json                   # Context length, compute hints
│   └── analytics/coremldata.bin
├── chunk2.mlmodelc/                    # 134 MB
├── chunk3.mlmodelc/                    # 325 MB
├── chunk4.mlmodelc/                    # 527 MB  — final layer + lm_head
│
├── prefill_chunk1.mlmodelc/            # Prefill variant of chunk1 (T=N mode)
│   ├── weights/weight.bin              # ← hardlink to chunk1/weights/weight.bin
│   ├── coremldata.bin                  # downloaded (different graph)
│   └── model.mil
├── prefill_chunk2.mlmodelc/            # hardlinked from chunk2
├── prefill_chunk3.mlmodelc/            # hardlinked from chunk3
├── prefill_chunk4.mlmodelc/            # hardlinked from chunk4
│
├── vision.mlmodelc/                    # SigLIP vision encoder — 320 MB
├── vision_video.mlmodelc/             # Video-grade encoder — 338 MB
├── audio.mlmodelc/                    # Conformer audio encoder — 295 MB
│
├── hf_model/
│   ├── tokenizer.json                  # BPE vocabulary — 30 MB
│   ├── tokenizer_config.json
│   └── config.json                     # HuggingFace model config
│
├── embed_tokens_q8.bin                 # INT8 token embeddings — 403 MB
├── embed_tokens_scales.bin             # Scale factors — 512 KB
├── embed_tokens_per_layer_q8.bin       # Per-layer embeddings — 2.35 GB ← largest file
├── embed_tokens_per_layer_scales.bin   # Scale factors — 512 KB
├── per_layer_projection.bin            # Projection weights — 27 MB
├── per_layer_norm_weight.bin
│
├── cos_sliding.npy                     # RoPE tables (sliding window)
├── sin_sliding.npy
├── cos_full.npy                        # RoPE tables (full attention)
├── sin_full.npy
│
├── mel_filterbank.bin                  # Mel filterbank for audio preprocessing
├── audio_config.json
├── output_proj_weight.npy              # Audio projection — 3 MB
├── output_proj_bias.npy
├── embed_proj_weight.npy               # Audio embedding projection — 4.7 MB
└── model_config.json                   # Context length, model variant flags
```

**Total on disk: ~5.4 GB** (prefill weights don't add extra space due to hardlinks)

---

## 8. EngineModel: Wrapping CoreMLLLM for SwiftUI

`EngineModel` is the single source of truth for model state, exposed to SwiftUI via `@Published` properties and `@MainActor` isolation.

### Status State Machine

```
idle ──[tap Download]──► downloading(0.0..1.0) ──► loading ──► ready
 ▲                                                              │
 └──────────────────────── error(msg) ◄─────────────────────────┘
                                │
                         [tap Retry]
```

### Prompt Formatting

Gemma 4 uses the `<start_of_turn>` / `<end_of_turn>` chat template (replacing the `<|turn>` tokens used by some LiteRT examples):

```swift
let formatted = """
<start_of_turn>user
\(prompt)<end_of_turn>
<start_of_turn>model
"""
```

### Audio Input Pipeline

Voice coaching input (from `AudioRecorder`) is WAV data. CoreMLLLM's audio encoder expects `[Float]` 16 kHz mono PCM, normalised to `[-1, 1]`:

```swift
private func wavDataToFloat(_ data: Data) -> [Float] {
    let headerSize = 44                   // skip WAV header
    let payload    = data.count > headerSize ? data.advanced(by: headerSize) : data
    let sampleCount = payload.count / 2
    var floats = [Float](repeating: 0, count: sampleCount)
    payload.withUnsafeBytes { ptr in
        let base = ptr.baseAddress!.assumingMemoryBound(to: Int16.self)
        for i in 0 ..< sampleCount {
            floats[i] = Float(base[i]) / 32768.0    // Int16 → [-1, 1]
        }
    }
    return floats
}
```

### Image Input Pipeline

Running form photos (from Photos picker or camera) are `Data`. CoreMLLLM's vision encoder expects a `CGImage`:

```swift
private func makeImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
```

---

## 9. Multimodal Pipeline for the Running Coach

### Text Coaching (`generateText`)

Basic voice coaching prompt:

```
User: "My pace dropped to 5:30/km in the last mile. What should I focus on?"
Model: [streams text tokens via AsyncStream<String>]
→ CoachSpeaker.speak() — AVSpeechSynthesizer reads tokens aloud
```

### Form Analysis (`generateVision`)

Camera photo → running form feedback:

```
User: [photo of runner] "Analyse my running form and tell me what to fix."
       │
       ├── CGImage → vision.mlmodelc → 196 image patch embeddings
       ├── Prompt tokens → embed_tokens_q8.bin
       └── Combined → prefill → decode → streaming text
→ CoachSpeaker reads feedback aloud (critical for visually impaired users)
```

### Voice Prompt (`generateAudio`)

Microphone recording → coaching response:

```
User: [10s audio clip] "I'm out of breath, what's wrong?"
       │
       ├── WAV Data → [Float] PCM → mel spectrogram → audio.mlmodelc
       ├── Audio embeddings + prompt tokens
       └── Decode → streaming text
→ CoachSpeaker reads coaching aloud
```

### Live Coaching Mode (`LiveSession` + `streamCoach`)

Every N seconds (user-adjustable 5–60 s), fires a fresh inference with accumulated context. Designed for continuous coaching during a run:

```swift
// streamCoach: streaming with per-chunk TTS callback
let stream = try await llm.stream(formatted, maxTokens: 80)
for await chunk in stream {
    output += chunk
    onChunk(chunk)          // → CoachSpeaker buffers and speaks each chunk
}
```

---

## 10. Performance Characteristics

All numbers from `CoreMLLLM.tokensPerSecond` on device:

| Device | Compute Units | Decode tok/s |
|---|---|---|
| iPhone 17 (A19 Pro) | ANE + CPU | ~34 |
| iPhone 16 Pro (A18 Pro) | ANE + CPU | ~28 |
| iPhone 15 Pro (A17 Pro) | ANE + CPU | ~20 |

**Time to First Token (TTFT):** ~2–4 s for short prompts (context prefill).  
**Live mode latency:** With `maxTokens: 80` and a 20 tok/s device, expect ~4 s generation + ~2 s TTFT = ~6 s per coaching burst — well within the 10–60 s trigger interval.

**Memory:** ~6 GB peak during model load (ANE weights + CPU fallback buffers). The `com.apple.developer.kernel.increased-memory-limit` entitlement in `GemmaCoach.entitlements` is required.

---

## 11. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        GemmaCoach App                        │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐   ┌───────────────┐  │
│  │  ContentView  │    │  LiveSession  │   │  AudioRecorder│  │
│  │  (SwiftUI)   │    │  (timer loop) │   │  (AVFoundation│  │
│  └──────┬───────┘    └──────┬───────┘   └───────┬───────┘  │
│         │                   │                   │           │
│         └───────────────────┴───────────────────┘           │
│                             │                               │
│                    ┌────────▼────────┐                      │
│                    │   EngineModel   │  @MainActor           │
│                    │  ObservableObject│  @Published state    │
│                    └────────┬────────┘                      │
│                             │                               │
│              ┌──────────────┴──────────────┐                │
│              │                             │                │
│    ┌─────────▼──────────┐    ┌────────────▼──────────┐      │
│    │  GemmaDownloader   │    │     CoreMLLLM          │      │
│    │  (our code)        │    │  (upstream library)    │      │
│    │                    │    │                        │      │
│    │  • foreground      │    │  • ChunkedEngine       │      │
│    │    URLSession       │    │  • ImageProcessor      │      │
│    │  • FileDelegate    │    │  • AudioProcessor      │      │
│    │  • byte progress   │    │  • EmbeddingLookup     │      │
│    │  • prefill links   │    │  • AsyncStream<String> │      │
│    └─────────┬──────────┘    └────────────┬──────────┘      │
│              │                            │                  │
│    ┌─────────▼──────────┐    ┌────────────▼──────────┐      │
│    │   HuggingFace CDN   │    │  Apple Neural Engine  │      │
│    │   (5.4 GB, one-time)│    │  + CPU (on-device)    │      │
│    └────────────────────┘    └───────────────────────┘      │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                    CoachSpeaker                        │  │
│  │             AVSpeechSynthesizer (TTS)                  │  │
│  │     speaks each token chunk aloud for visually         │  │
│  │     impaired runners — no screen reading required      │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Summary of Changes from Upstream

| File | Change |
|---|---|
| `project.yml` | iOS 17→18, LiteRTLMSwift→CoreMLLLM, removed dylib signing script |
| `EngineModel.swift` | Full rewrite: LiteRTLMEngine→CoreMLLLM, custom download flow |
| `GemmaDownloader.swift` | **New** — our foreground URLSession downloader, replaces ModelDownloader |
| `AudioRecorder.swift` | Fixed deprecated AVAudioSession → AVAudioApplication APIs |
| `LiveSession.swift` | Removed `import LiteRTLMSwift` |
| `ContentView.swift` | Added explicit Download button, real progress bar, retry on error |

The core inference API (`stream`, `generate`, `AsyncStream<String>`) is used as-is from the upstream library. The only upstream component we replaced is `ModelDownloader` — specifically its broken background URLSession download mechanism.
