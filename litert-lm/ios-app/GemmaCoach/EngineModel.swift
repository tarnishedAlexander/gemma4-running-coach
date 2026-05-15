// EngineModel.swift
// Wraps LiteRTLMEngine with @MainActor + @Published state for SwiftUI.

import Foundation
import LiteRTLMSwift

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

    private var engine: LiteRTLMEngine? = nil

    /// Download Gemma 4 E2B (~2.6 GB) and load the engine.
    /// Idempotent — safe to call multiple times.
    func loadIfNeeded() async {
        guard engine == nil else { return }

        do {
            // 1) Download (no-op if already cached).
            let downloader = ModelDownloader()
            if !downloader.isDownloaded {
                status = .downloading(progress: 0)
                let pollTask = Task { @MainActor in
                    while !downloader.isDownloaded && !Task.isCancelled {
                        self.status = .downloading(progress: downloader.progress)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                try await downloader.download(from: ModelDownloader.defaultModelURL)
                pollTask.cancel()
            }
            modelPath = downloader.modelPath

            // 2) Load engine.
            status = .loading
            let e = LiteRTLMEngine(modelPath: downloader.modelPath)
            try await e.load()
            engine = e
            status = .ready
        } catch {
            status = .error("\(error)")
        }
    }

    /// Run a text-only generation.
    func generateText(_ prompt: String, maxTokens: Int = 256) async {
        guard let engine else { status = .error("engine not loaded"); return }
        let formatted = "<|turn>user\n\(prompt)\n<turn|>\n<|turn>model\n"
        await runStreaming { try await engine.generateStreaming(prompt: formatted, maxTokens: maxTokens) }
    }

    /// Run a vision query (image + plain text — the Conversation API handles formatting).
    func generateVision(imageData: Data, prompt: String, maxTokens: Int = 512) async {
        guard let engine else { status = .error("engine not loaded"); return }
        await run {
            try await engine.vision(imageData: imageData, prompt: prompt, maxTokens: maxTokens)
        }
    }

    /// Audio understanding: transcribe / summarize / coach on an audio clip.
    func generateAudio(audioData: Data, prompt: String, maxTokens: Int = 512) async {
        guard let engine else { status = .error("engine not loaded"); return }
        await run {
            try await engine.audio(audioData: audioData, prompt: prompt, format: .wav, maxTokens: maxTokens)
        }
    }

    /// Multimodal: image(s) + audio + text in one call.
    func generateMultimodal(audioData: [Data], imagesData: [Data], prompt: String, maxTokens: Int = 1024) async {
        guard let engine else { status = .error("engine not loaded"); return }
        await run {
            try await engine.multimodal(audioData: audioData, audioFormat: .wav,
                                        imagesData: imagesData, prompt: prompt, maxTokens: maxTokens)
        }
    }

    /// Single-shot (non-streaming) wrapper that times TTFT from start of generation.
    private func run(_ work: () async throws -> String) async {
        status = .generating
        output = ""
        let start = Date()
        do {
            let result = try await work()
            let total = Date().timeIntervalSince(start)
            output = result
            lastTotalTime = total
            // Approximate token count via 4-char heuristic; LiteRTLM doesn't expose token-level timing on the one-shot API.
            let approxTok = max(1, result.count / 4)
            lastDecodeTokensPerSecond = Double(approxTok) / max(total, 0.001)
            lastTimeToFirstToken = 0  // n/a for one-shot
            status = .ready
        } catch {
            status = .error("\(error)")
        }
    }

    /// Streaming wrapper: measures TTFT explicitly.
    private func runStreaming(_ work: () async throws -> AsyncThrowingStream<String, Error>) async {
        status = .generating
        output = ""
        let start = Date()
        var firstTok: Date? = nil
        var totalChars = 0
        do {
            let stream = try await work()
            for try await chunk in stream {
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
}
