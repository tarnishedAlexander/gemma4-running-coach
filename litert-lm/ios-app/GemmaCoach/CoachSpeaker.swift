// CoachSpeaker.swift
// On-device TTS for coaching responses via AVSpeechSynthesizer.
// Streams chunks as they arrive from the LLM rather than waiting for the whole reply.

import AVFoundation
import Foundation

@MainActor
final class CoachSpeaker: NSObject, ObservableObject {
    @Published var isSpeaking: Bool = false

    private let synth = AVSpeechSynthesizer()
    private var pending: String = ""    // accumulator for chunks not yet flushed
    private var flushTimer: Timer?

    /// Pick a coaching-voice tuned voice (Samantha / Karen / Daniel etc.).
    private let voice: AVSpeechSynthesisVoice = {
        if let v = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.Samantha-compact") { return v }
        if let v = AVSpeechSynthesisVoice(language: "en-US") { return v }
        return AVSpeechSynthesisVoice()
    }()

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Called for each new token chunk from the LLM stream.
    /// Buffers until we hit a sentence boundary or word break, then enqueues for speech.
    func speak(chunk: String) {
        pending += chunk
        // Flush at sentence boundaries for natural-sounding pacing
        if let r = pending.rangeOfCharacter(from: .init(charactersIn: ".!?\n")) {
            let sentence = String(pending[..<r.upperBound])
            pending = String(pending[r.upperBound...])
            enqueue(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            // Soft flush after 800ms of inactivity to avoid awkward pauses
            flushTimer?.invalidate()
            flushTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.flush() }
            }
        }
    }

    /// Flush any buffered text immediately (e.g. on stream end).
    func flush() {
        let leftover = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        if !leftover.isEmpty { enqueue(leftover) }
    }

    func cancel() {
        synth.stopSpeaking(at: .immediate)
        pending = ""
        flushTimer?.invalidate()
        isSpeaking = false
    }

    private func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        let utt = AVSpeechUtterance(string: text)
        utt.voice = voice
        utt.rate = 0.52         // slightly slower than default for clarity at running pace
        utt.pitchMultiplier = 1.0
        utt.preUtteranceDelay = 0.0
        utt.postUtteranceDelay = 0.05
        synth.speak(utt)
        isSpeaking = true
    }
}

extension CoachSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // If queue is empty, mark not speaking
            if !synth.isSpeaking { isSpeaking = false }
        }
    }
}
