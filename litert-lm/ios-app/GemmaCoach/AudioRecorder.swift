// AudioRecorder.swift
// Mic capture wrapper for LiteRTLMEngine.audio() — writes 16-bit PCM WAV.

import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var meterLevel: Float = 0  // 0...1, smoothed power level for UI bar
    @Published var permissionDenied: Bool = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private(set) var lastRecordingURL: URL?

    func requestPermissionIfNeeded() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        let granted = await AVAudioApplication.requestRecordPermission()
        await MainActor.run { self.permissionDenied = !granted }
        return granted
    }

    func startRecording() async throws {
        guard await requestPermissionIfNeeded() else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        r.record()
        recorder = r
        lastRecordingURL = url
        isRecording = true

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
    }

    func stopRecording() -> Data? {
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        meterTimer?.invalidate(); meterTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        meterLevel = 0
        guard let url = lastRecordingURL else { return nil }
        return try? Data(contentsOf: url)
    }

    private func updateMeter() {
        guard let r = recorder else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)        // -160 ... 0
        let normalized = max(0, min(1, (db + 50) / 50)) // map -50dB...0dB → 0...1
        meterLevel = meterLevel * 0.6 + normalized * 0.4 // simple smoothing
    }
}
