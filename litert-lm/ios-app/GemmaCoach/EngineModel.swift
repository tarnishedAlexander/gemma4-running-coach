// EngineModel.swift
// Wraps CoreMLLLM with @MainActor + @Published state for SwiftUI.

import CoreGraphics
import Foundation
import ImageIO
import CoreMLLLM

@MainActor
final class EngineModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(progress: Double)
        case loading
        case ready
        case generating
        case error(String)
    }

    @Published var status: Status = .idle
    @Published var modelPath: URL? = nil
    @Published var output: String = ""
    @Published var lastDecodeTokensPerSecond: Double = 0
    @Published var lastTimeToFirstToken: Double = 0
    @Published var lastTotalTime: Double = 0
    @Published var loadingMessage: String = ""

    private var llm: CoreMLLLM? = nil

    var isReady: Bool {
        if case .ready = status { return true }
        if case .generating = status { return true }
        return false
    }

    /// Download Gemma 4 E2B and load on ANE + CPU.
    /// Phase 1 — GemmaDownloader fetches files from HuggingFace with real byte progress.
    /// Phase 2 — CoreMLLLM.load() compiles and initialises the model.
    func loadIfNeeded() async {
        if llm != nil { return }
        if case .loading = status { return }
        if case .downloading = status { return }

        status = .downloading(progress: 0)
        loadingMessage = "Preparing…"

        let downloader = GemmaDownloader()
        downloader.onProgress = { [weak self] (progress: Double, message: String) in
            self?.status = .downloading(progress: progress)
            self?.loadingMessage = message
        }

        do {
            // Phase 1: download all model files (skips files already on disk)
            let modelDir = try await downloader.download()

            // Phase 2: compile & load model on ANE + CPU
            status = .loading
            loadingMessage = "Loading model…"

            let model = try await CoreMLLLM.load(
                from: modelDir,
                computeUnits: .cpuAndNeuralEngine,
                onProgress: { [weak self] msg in
                    Task { @MainActor [weak self] in
                        self?.loadingMessage = msg
                    }
                }
            )
            llm = model
            loadingMessage = ""
            status = .ready
        } catch {
            loadingMessage = ""
            status = .error("\(error)")
        }
    }

    /// Run a text-only streaming generation.
    func generateText(_ prompt: String, maxTokens: Int = 256) async {
        guard let llm else { status = .error("engine not loaded"); return }
        let formatted = "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        await runStreaming {
            try await llm.stream(formatted, maxTokens: maxTokens)
        }
    }

    /// Run a vision query (image + text).
    func generateVision(imageData: Data, prompt: String, maxTokens: Int = 512) async {
        guard let llm else { status = .error("engine not loaded"); return }
        let image = makeImage(from: imageData)
        let formatted = "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        await runStreaming {
            try await llm.stream(formatted, image: image, maxTokens: maxTokens)
        }
    }

    /// Audio understanding: transcribe / summarize / coach on an audio clip.
    func generateAudio(audioData: Data, prompt: String, maxTokens: Int = 512) async {
        guard let llm else { status = .error("engine not loaded"); return }
        let samples = wavDataToFloat(audioData)
        let formatted = "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        await runStreaming {
            try await llm.stream(formatted, audio: samples, maxTokens: maxTokens)
        }
    }

    /// Multimodal: image + audio + text in one call.
    func generateMultimodal(audioData: [Data], imagesData: [Data], prompt: String, maxTokens: Int = 1024) async {
        guard let llm else { status = .error("engine not loaded"); return }
        let samples = audioData.first.map { wavDataToFloat($0) }
        let image: CGImage? = imagesData.first.flatMap { makeImage(from: $0) }
        let formatted = "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
        await runStreaming {
            try await llm.stream(formatted, image: image, audio: samples, maxTokens: maxTokens)
        }
    }

    /// Streaming coaching with per-chunk callback — used by LiveSession for TTS pipeline.
    func streamCoach(history: [(role: String, content: String)], image: CGImage? = nil, onChunk: @MainActor @escaping (String) -> Void) async {
        guard let llm else { status = .error("engine not loaded"); return }
        var formatted = ""
        for msg in history {
            // Note: If role is system, we format it as user for Gemma as Gemma does not natively support system roles
            let role = msg.role == "system" ? "user" : msg.role
            formatted += "<start_of_turn>\(role)\n\(msg.content)<end_of_turn>\n"
        }
        formatted += "<start_of_turn>model\n"
        status = .generating
        output = ""
        let start = Date()
        var firstTok: Date? = nil
        var totalChars = 0
        do {
            let stream = try await llm.stream(formatted, image: image, maxTokens: 80)
            for await chunk in stream {
                if Task.isCancelled { break }
                if firstTok == nil { firstTok = Date() }
                output += chunk
                totalChars += chunk.count
                onChunk(chunk)
            }
            let end = Date()
            let total = end.timeIntervalSince(start)
            let ttft = firstTok?.timeIntervalSince(start) ?? 0
            let decodeT = end.timeIntervalSince(firstTok ?? start)
            let approxTok = max(1, totalChars / 4)
            lastTimeToFirstToken = ttft
            lastTotalTime = total
            lastDecodeTokensPerSecond = Double(approxTok) / max(decodeT, 0.001)
            status = .ready
        } catch is CancellationError {
            status = .ready
        } catch {
            status = .error("\(error)")
        }
    }

    // MARK: - Private helpers

    private func runStreaming(_ work: () async throws -> AsyncStream<String>) async {
        status = .generating
        output = ""
        let start = Date()
        var firstTok: Date? = nil
        var totalChars = 0
        do {
            let stream = try await work()
            for await chunk in stream {
                if firstTok == nil { firstTok = Date() }
                output += chunk
                totalChars += chunk.count
            }
            let end = Date()
            let total = end.timeIntervalSince(start)
            let ttft = firstTok?.timeIntervalSince(start) ?? 0
            let decodeT = end.timeIntervalSince(firstTok ?? start)
            let approxTok = max(1, totalChars / 4)
            lastTimeToFirstToken = ttft
            lastTotalTime = total
            lastDecodeTokensPerSecond = Double(approxTok) / max(decodeT, 0.001)
            status = .ready
        } catch {
            status = .error("\(error)")
        }
    }

    /// Decode image Data → CGImage; returns nil on failure (model will run text-only).
    private func makeImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Convert WAV Data (16 kHz mono Int16 PCM) → [Float] normalised to [-1, 1].
    /// Skips the 44-byte WAV header; falls back to treating the entire buffer as raw PCM.
    private func wavDataToFloat(_ data: Data) -> [Float] {
        let headerSize = 44
        let payload = data.count > headerSize ? data.advanced(by: headerSize) : data
        let sampleCount = payload.count / 2
        var floats = [Float](repeating: 0, count: sampleCount)
        payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0 ..< sampleCount {
                floats[i] = Float(base[i]) / 32768.0
            }
        }
        return floats
    }
}
