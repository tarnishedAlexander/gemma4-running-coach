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
    private var loopTask: Task<Void, Never>? = nil
    private var inflight: Task<Void, Never>? = nil

    /// Coaching prompt template — the {{state}} placeholder is filled per trigger.
    var promptTemplate: String =
        "You are a friendly running coach. In ONE concise sentence, give the runner immediate feedback or encouragement. Keep it short — they're mid-stride."

    func attach(engine: EngineModel, speaker: CoachSpeaker) {
        self.engine = engine
        self.speaker = speaker
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        triggerCount = 0
        lastError = nil
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

        let prompt = promptTemplate
        let speaker = self.speaker

        inflight = Task { @MainActor in
            await engine.streamCoach(prompt: prompt, onChunk: { chunk in
                speaker?.speak(chunk: chunk)
            })
            speaker?.flush()
            self.lastFinishedDecodeTokensPerSecond = engine.lastDecodeTokensPerSecond
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
