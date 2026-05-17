// ContentView.swift
// Minimal SwiftUI UI: text + image picker + run + show metrics.

import SwiftUI
import PhotosUI

struct ContentView: View {
    @EnvironmentObject var engine: EngineModel
    @State private var prompt: String = "What's in this photo? Coach me on my running form."
    @State private var pickedItem: PhotosPickerItem? = nil
    @State private var pickedImageData: Data? = nil
    @State private var pickedThumb: UIImage? = nil
    @StateObject private var audioRecorder = AudioRecorder()
    @State private var pendingAudioData: Data? = nil
    @StateObject private var speaker = CoachSpeaker()
    @StateObject private var liveSession = LiveSession()
    @StateObject private var metricsManager = RunMetricsManager()
    @StateObject private var visionManager = VisionManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    promptEditor
                    imagePickerRow
                    audioRow
                    runButtons
                    metricsCard
                    outputCard
                    liveCard
                    perceptionCard
                }
                .padding()
            }
            .navigationTitle("Gemma Coach")
            .task {
                liveSession.attach(engine: engine, speaker: speaker, metrics: metricsManager)
            }
        }
    }

    private var statusCard: some View {
        GroupBox {
            switch engine.status {
            case .idle:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Gemma 4 E2B (~5.4 GB) is not loaded.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await engine.loadIfNeeded() }
                    } label: {
                        Label("Download & Load Model", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .downloading(let p):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading Gemma 4 E2B")
                        Spacer()
                        Text("\(Int(p * 100))%")
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    ProgressView(value: max(p, 0.005), total: 1.0)
                    if !engine.loadingMessage.isEmpty {
                        Text(engine.loadingMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            case .loading:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView()
                    if !engine.loadingMessage.isEmpty {
                        Text(engine.loadingMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("Loading model — this may take a few minutes…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .generating: ProgressView("Generating…")
            case .error(let msg):
                VStack(alignment: .leading, spacing: 8) {
                    Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                    Button("Retry") { Task { await engine.loadIfNeeded() } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading) {
            Text("Prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .frame(minHeight: 80)
                .border(.gray.opacity(0.3))
        }
    }

    private var imagePickerRow: some View {
        HStack {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Label(pickedThumb == nil ? "Pick photo" : "Replace photo", systemImage: "photo")
            }
            .onChange(of: pickedItem) { _, _ in handlePicked() }

            if let thumb = pickedThumb {
                Image(uiImage: thumb)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 60).cornerRadius(6)
                Button(role: .destructive) {
                    pickedItem = nil; pickedImageData = nil; pickedThumb = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
            Spacer()
        }
    }

    private var audioRow: some View {
        HStack(spacing: 12) {
            Button {
                if audioRecorder.isRecording {
                    pendingAudioData = audioRecorder.stopRecording()
                } else {
                    pendingAudioData = nil
                    Task { try? await audioRecorder.startRecording() }
                }
            } label: {
                Label(audioRecorder.isRecording ? "Stop" : "Record",
                      systemImage: audioRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .foregroundColor(audioRecorder.isRecording ? .red : .accentColor)
            }
            if audioRecorder.isRecording {
                ProgressView(value: audioRecorder.meterLevel).frame(maxWidth: 120)
            }
            if pendingAudioData != nil && !audioRecorder.isRecording {
                Image(systemName: "waveform.circle.fill").foregroundStyle(.green)
                Text("audio ready").font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { pendingAudioData = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
            Spacer()
        }
    }

    private var runButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await engine.generateText(prompt) }
                } label: { Label("Text", systemImage: "text.bubble") }
                    .buttonStyle(.bordered).disabled(!isReady)

                Button {
                    guard let data = pickedImageData else { return }
                    Task { await engine.generateVision(imageData: data, prompt: prompt); clearAttachments() }
                } label: { Label("+ image", systemImage: "photo.on.rectangle") }
                    .buttonStyle(.bordered).disabled(!isReady || pickedImageData == nil)

                Button {
                    guard let data = pendingAudioData else { return }
                    Task { await engine.generateAudio(audioData: data, prompt: prompt); clearAttachments() }
                } label: { Label("+ audio", systemImage: "waveform") }
                    .buttonStyle(.bordered).disabled(!isReady || pendingAudioData == nil)

                Button {
                    var imgs: [Data] = []
                    if let i = pickedImageData { imgs.append(i) }
                    var auds: [Data] = []
                    if let a = pendingAudioData { auds.append(a) }
                    Task { await engine.generateMultimodal(audioData: auds, imagesData: imgs, prompt: prompt); clearAttachments() }
                } label: { Label("All", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isReady || (pickedImageData == nil && pendingAudioData == nil))
            }
        }
    }

    private func clearAttachments() {
        pickedImageData = nil; pickedThumb = nil; pickedItem = nil
        pendingAudioData = nil
    }

    private var metricsCard: some View {
        GroupBox("Last run") {
            HStack(spacing: 16) {
                metric("TTFT", String(format: "%.2f s", engine.lastTimeToFirstToken))
                metric("Decode", String(format: "%.1f tok/s", engine.lastDecodeTokensPerSecond))
                metric("Total", String(format: "%.2f s", engine.lastTotalTime))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }

    private var liveCard: some View {
        GroupBox("Live coaching mode") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { liveSession.isRunning },
                        set: { newVal in 
                            if newVal {
                                metricsManager.start()
                                liveSession.start()
                            } else {
                                liveSession.stop()
                                metricsManager.stop()
                            }
                        }
                    )) {
                        Label(liveSession.isRunning ? "Live" : "Off",
                              systemImage: liveSession.isRunning ? "dot.radiowaves.left.and.right" : "circle")
                    }
                    .toggleStyle(.switch)
                    .tint(.red)
                    Spacer()
                    if liveSession.isRunning {
                        Image(systemName: speaker.isSpeaking ? "speaker.wave.3.fill" : "speaker")
                            .foregroundStyle(speaker.isSpeaking ? Color.accentColor : .secondary)
                    }
                }

                if metricsManager.isActive {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            metric("Heart Rate", metricsManager.currentHeartRateBPM > 0 ? "\(metricsManager.currentHeartRateBPM) BPM" : "—")
                            metric("Pace", metricsManager.formattedPace)
                            metric("Cadence", "\(Int(metricsManager.currentCadenceSPM)) spm")
                        }
                        HStack(spacing: 12) {
                            metric("Elev", String(format: "%.1fm", metricsManager.currentElevationMeters))
                            metric("Power", "\(Int(metricsManager.currentRunningPowerWatts)) W")
                            metric("Stride", String(format: "%.2fm", metricsManager.currentStrideLengthMeters))
                        }
                    }
                    .padding(.vertical, 4)
                }

                VStack(alignment: .leading) {
                    Text("Trigger every \(Int(liveSession.periodSeconds))s")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $liveSession.periodSeconds, in: 5...60, step: 1)
                        .disabled(liveSession.isRunning)
                }

                if liveSession.isRunning || liveSession.triggerCount > 0 {
                    HStack(spacing: 12) {
                        metric("Triggers", "\(liveSession.triggerCount)")
                        metric("Last decode", String(format: "%.1f tok/s", liveSession.lastFinishedDecodeTokensPerSecond))
                        if let t = liveSession.lastTriggerAt {
                            metric("Since last", String(format: "%.1f s", Date().timeIntervalSince(t)))
                        }
                    }
                }

                if let err = liveSession.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    private var outputCard: some View {
        GroupBox("Output") {
            Text(engine.output.isEmpty ? "—" : engine.output)
                .font(.system(.callout, design: .default))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var isReady: Bool { engine.isReady && !liveSession.isRunning }

    private var perceptionCard: some View {
        GroupBox("Perception Gate (Testing Phase 1)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { visionManager.isRunning },
                    set: { newVal in
                        if newVal { visionManager.startCamera() }
                        else { visionManager.stopCamera() }
                    }
                )) {
                    Label(visionManager.isRunning ? "Camera Active" : "Camera Off",
                          systemImage: visionManager.isRunning ? "camera.viewfinder" : "camera")
                }
                .toggleStyle(.switch)
                .tint(.blue)
                
                if visionManager.isRunning {
                    Text("Latest Detections:")
                        .font(.caption).foregroundStyle(.secondary)
                    if visionManager.latestDetections.isEmpty {
                        Text("No people detected...")
                            .font(.caption2)
                    } else {
                        ForEach(visionManager.latestDetections, id: \.self) { detection in
                            Text(detection)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }

    private func handlePicked() {
        guard let item = pickedItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                await MainActor.run {
                    pickedImageData = data
                    pickedThumb = img
                }
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(EngineModel())
}
