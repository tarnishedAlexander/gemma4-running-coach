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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    promptEditor
                    imagePickerRow
                    runButtons
                    metricsCard
                    outputCard
                }
                .padding()
            }
            .navigationTitle("Gemma Coach")
            .task { await engine.loadIfNeeded() }
        }
    }

    private var statusCard: some View {
        GroupBox {
            switch engine.status {
            case .idle: Text("Idle").foregroundStyle(.secondary)
            case .downloading(let p):
                VStack(alignment: .leading) {
                    Text("Downloading model… \(Int(p * 100))%").font(.caption)
                    ProgressView(value: p)
                }
            case .loading: ProgressView("Loading engine…")
            case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .generating: ProgressView("Generating…")
            case .error(let msg): Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
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

    private var runButtons: some View {
        HStack {
            Button {
                Task { await engine.generateText(prompt) }
            } label: { Label("Text only", systemImage: "text.bubble") }
                .buttonStyle(.bordered)
                .disabled(!isReady)

            Button {
                guard let data = pickedImageData else { return }
                Task { await engine.generateVision(imageData: data, prompt: prompt) }
            } label: { Label("Text + image", systemImage: "photo.on.rectangle") }
                .buttonStyle(.borderedProminent)
                .disabled(!isReady || pickedImageData == nil)
        }
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

    private var outputCard: some View {
        GroupBox("Output") {
            Text(engine.output.isEmpty ? "—" : engine.output)
                .font(.system(.callout, design: .default))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var isReady: Bool {
        if case .ready = engine.status { return true }
        if case .generating = engine.status { return false }
        return false
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
