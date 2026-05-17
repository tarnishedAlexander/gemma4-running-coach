// LiveSession.swift
// Live coaching loop: every N seconds, fire a fresh inference with the current context
// (user-provided prompt template + any attached photo/audio), stream tokens to the speaker,
// cancel previous in-flight on each new trigger.

import AVFoundation
import Foundation

@MainActor
final class LiveSession: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var lastTriggerAt: Date? = nil
    @Published var triggerCount: Int = 0
    @Published var periodSeconds: Double = 15
    @Published var lastFinishedDecodeTokensPerSecond: Double = 0
    @Published var lastError: String? = nil

    private weak var engine: EngineModel?
    private weak var speaker: CoachSpeaker?
    private weak var metrics: RunMetricsManager?
    private var loopTask: Task<Void, Never>? = nil
    private var inflight: Task<Void, Never>? = nil
    private var chatHistory: [(role: String, content: String)] = []
    
    private let systemPrompt = """
    You are an elite running coach and a safety navigation assistant. 
    1. If the user provides running metrics (Heart Rate, Pace, Stride), give ONE concise sentence of coaching feedback.
    2. If the user provides a CRITICAL HAZARD alert from the camera gate, drop everything and immediately warn them in ONE short sentence.
    IMPORTANT: Respond ONLY with the spoken sentence. Do not use any <think> blocks, markdown formatting, or chain of thought reasoning.
    """

    func attach(engine: EngineModel, speaker: CoachSpeaker, metrics: RunMetricsManager) {
        self.engine = engine
        self.speaker = speaker
        self.metrics = metrics
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        triggerCount = 0
        lastError = nil
        chatHistory = []
        configureBackgroundAudio()

        loopTask = Task { @MainActor in
            // Fire one immediately so the user gets feedback right away.
            await fireOnce()
            while !Task.isCancelled && self.isRunning {
                try? await Task.sleep(for: .seconds(self.periodSeconds))
                if Task.isCancelled || !self.isRunning { break }
                await fireOnce()
            }
        }
    }

    func stop() {
        isRunning = false
        loopTask?.cancel(); loopTask = nil
        inflight?.cancel(); inflight = nil
        speaker?.cancel()
        deactivateBackgroundAudio()
    }

    private func fireOnce() async {
        // Cancel any previous still-streaming generation so we don't pile up output.
        inflight?.cancel()
        speaker?.cancel()

        triggerCount += 1
        lastTriggerAt = Date()
        guard let engine = engine, engine.isReady else { return }

        let metricsStr = metrics?.getCurrentStateString() ?? "No live metrics available."
        
        let userMessage: String
        if chatHistory.isEmpty {
            userMessage = "\(systemPrompt)\n\nCurrent Metrics:\n\(metricsStr)"
        } else {
            userMessage = "Current Metrics:\n\(metricsStr)"
        }
        
        chatHistory.append((role: "user", content: userMessage))
        
        let speaker = self.speaker
        let currentHistory = chatHistory

        inflight = Task { @MainActor in
            var fullResponse = ""
            await engine.streamCoach(history: currentHistory, onChunk: { chunk in
                fullResponse += chunk
                speaker?.speak(chunk: chunk)
            })
            
            // Save answer to memory
            self.chatHistory.append((role: "model", content: fullResponse))
            
            // Rolling memory window (keep system prompt at index 0, prune oldest user/model pair)
            if self.chatHistory.count > 11 {
                self.chatHistory.remove(at: 1)
                self.chatHistory.remove(at: 1)
            }
            
            speaker?.flush()
            self.lastFinishedDecodeTokensPerSecond = engine.lastDecodeTokensPerSecond
        }
    }

    /// Called instantly by the external Perception Gate (MobileCLIP + LiDAR) when a hazard is detected.
    func fireHazardInterrupt(hazardLabel: String, depthMeters: Float, hazardScore: Float) {
        guard isRunning else { return }
        
        // Cancel the normal running coach if she is currently speaking or thinking
        inflight?.cancel()
        speaker?.cancel()
        
        guard let engine = engine, engine.isReady else { return }
        
        let urgentMessage = """
        [CRITICAL ALERT FROM PERCEPTION GATE]
        Local hazard gate detected:
        - estimated distance: \(depthMeters)m
        - top label: "\(hazardLabel)"
        - MobileCLIP score: \(hazardScore)
        
        Look at the metadata and give concise safety guidance in one short sentence.
        """
        
        if chatHistory.isEmpty {
            chatHistory.append((role: "user", content: "\(systemPrompt)\n\n\(urgentMessage)"))
        } else {
            chatHistory.append((role: "user", content: urgentMessage))
        }
        
        let speaker = self.speaker
        let currentHistory = chatHistory
        
        inflight = Task { @MainActor in
            var fullResponse = ""
            await engine.streamCoach(history: currentHistory, onChunk: { chunk in
                fullResponse += chunk
                speaker?.speak(chunk: chunk)
            })
            
            // Save answer to memory
            self.chatHistory.append((role: "model", content: fullResponse))
            
            // Rolling memory window
            if self.chatHistory.count > 11 {
                self.chatHistory.remove(at: 1)
                self.chatHistory.remove(at: 1)
            }
            
            speaker?.flush()
            self.lastFinishedDecodeTokensPerSecond = engine.lastDecodeTokensPerSecond
            self.lastTriggerAt = Date()
        }
    }

    // MARK: - Background audio

    private func configureBackgroundAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            lastError = "audio session: \(error)"
        }
    }

    private func deactivateBackgroundAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
