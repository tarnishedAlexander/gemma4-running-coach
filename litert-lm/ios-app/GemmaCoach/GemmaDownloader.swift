// GemmaDownloader.swift
// Dedicated Gemma 4 E2B downloader for the running coach app.
//
// Reverse-engineered from CoreML-LLM's ModelDownloader, stripped to exactly
// what this app needs: text + vision (form analysis) + audio (voice coaching).
//
// Uses a foreground URLSession with a real URLSessionDownloadDelegate so bytes
// reported are actual bytes — no background-session adoption race, no stuck progress.

import Foundation

// MARK: - File descriptor

struct GemmaFile {
    let remotePath: String    // relative to baseURL
    let localPath: String     // relative to modelDirectory
    let estimatedBytes: Int64
}

// MARK: - Downloader

@MainActor
final class GemmaDownloader {

    // HuggingFace repo: mlboydaisuke/gemma-4-E2B-coreml, branch n1024
    static let baseURL  = "https://huggingface.co/mlboydaisuke/gemma-4-E2B-coreml/resolve/n1024"
    static let folder   = "gemma4-e2b"

    static var modelDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models/\(folder)")
    }

    /// True once chunk1 weights exist on disk (minimum signal that download succeeded).
    static var isReady: Bool {
        FileManager.default.fileExists(
            atPath: modelDirectory.appendingPathComponent("chunk1.mlmodelc/weights/weight.bin").path
        )
    }

    // MARK: - Progress callbacks (set by EngineModel before calling download())

    var onProgress: ((Double, String) -> Void)?

    // MARK: - Main entry point

    /// Download all missing model files, then return the model directory URL
    /// suitable for `CoreMLLLM.load(from:)`.
    func download() async throws -> URL {
        let fm   = FileManager.default
        let dest = Self.modelDirectory
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let files = Self.allFiles

        // Count bytes already on disk so progress starts correctly on resume.
        var completedBytes: Int64 = files.reduce(0) { acc, f in
            let p = dest.appendingPathComponent(f.localPath)
            guard fm.fileExists(atPath: p.path),
                  let sz = try? fm.attributesOfItem(atPath: p.path)[.size] as? Int64, sz > 0
            else { return acc }
            return acc + sz
        }
        let grandTotal = files.reduce(0) { $0 + $1.estimatedBytes }
        report(completedBytes, grandTotal)

        // Files to download: missing or zero-byte, sorted largest-first so
        // heavy weight.bin files dominate early and progress moves steadily.
        let remaining = files
            .filter { f in
                let p = dest.appendingPathComponent(f.localPath)
                guard fm.fileExists(atPath: p.path) else { return true }
                return ((try? fm.attributesOfItem(atPath: p.path)[.size] as? Int64) ?? 0) == 0
            }
            .sorted { $0.estimatedBytes > $1.estimatedBytes }

        for file in remaining {
            let destFile = dest.appendingPathComponent(file.localPath)
            try fm.createDirectory(at: destFile.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            guard let remoteURL = URL(string: "\(Self.baseURL)/\(file.remotePath)") else { continue }

            let bytes = try await downloadOne(
                from: remoteURL, to: destFile,
                completedSoFar: completedBytes, grandTotal: grandTotal
            )
            completedBytes += bytes
            report(completedBytes, grandTotal)
        }

        // Mirror CoreML-LLM's finishDownload(): hardlink decode weights into
        // prefill chunk directories so CoreML can open the prefill models.
        linkPrefillWeights(in: dest, fm: fm)

        onProgress?(1.0, "Download complete")
        return dest
    }

    // MARK: - Single file download

    /// Downloads `url` to `dest` using a foreground URLSessionDownloadTask,
    /// calling onProgress with cumulative byte count during transfer.
    private func downloadOne(
        from url: URL, to dest: URL,
        completedSoFar base: Int64, grandTotal: Int64
    ) async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = FileDelegate(
                destURL: dest,
                onBytes: { [weak self] written in
                    // Called on background delegate queue; hop to MainActor for UI.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let total = base + written
                        let prog  = min(Double(total) / Double(max(grandTotal, 1)), 0.99)
                        self.onProgress?(prog, Self.formatMB(total, grandTotal))
                    }
                },
                onDone: { result in continuation.resume(with: result) }
            )
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForResource = 7_200          // 2 h for large files
            cfg.httpShouldUsePipelining    = false           // HF CDN prefers one stream
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            delegate.retainSession(session)                  // keep session alive until done
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: - Post-download: hardlink prefill weights from decode chunks

    /// Decode and prefill chunk weights are bit-identical (verified by CoreML-LLM).
    /// We hardlink instead of copy to save ~682 MB of duplicate disk space.
    private func linkPrefillWeights(in dest: URL, fm: FileManager) {
        func link(src: String, dst: String, requiresMeta meta: String) {
            let s = dest.appendingPathComponent(src)
            let d = dest.appendingPathComponent(dst)
            let m = dest.appendingPathComponent(meta)
            guard fm.fileExists(atPath: s.path),
                  fm.fileExists(atPath: m.path),
                  !fm.fileExists(atPath: d.path) else { return }
            try? fm.createDirectory(at: d.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if (try? fm.linkItem(at: s, to: d)) == nil {
                try? fm.copyItem(at: s, to: d)              // APFS hardlink fallback
            }
        }
        for i in 1...4 {
            link(
                src: "chunk\(i).mlmodelc/weights/weight.bin",
                dst: "prefill_chunk\(i).mlmodelc/weights/weight.bin",
                requiresMeta: "prefill_chunk\(i).mlmodelc/coremldata.bin"
            )
        }
    }

    // MARK: - Helpers

    private func report(_ done: Int64, _ total: Int64) {
        let p   = min(Double(done) / Double(max(total, 1)), 1.0)
        let msg = Self.formatMB(done, total)
        onProgress?(p, msg)
    }

    static func formatMB(_ done: Int64, _ total: Int64) -> String {
        String(format: "%.0f / %.0f MB", Double(done) / 1e6, Double(total) / 1e6)
    }

    // MARK: - File list (mirrored from CoreML-LLM ModelDownloader.buildHuggingFaceFileList)

    static let allFiles: [GemmaFile] = {
        // Build the 5 standard CoreML model files for one .mlmodelc bundle.
        // `remote` is the HF subfolder prefix (e.g. "swa"); "" means repo root.
        // `name` is the model name without extension; `local` is the on-disk name.
        func mlc(_ remote: String, _ name: String, local: String? = nil, weight: Int64) -> [GemmaFile] {
            let localName = local ?? name
            let rPrefix   = remote.isEmpty ? "" : "\(remote)/"
            return [
                .init(remotePath: "\(rPrefix)\(name).mlmodelc/weights/weight.bin",
                      localPath:  "\(localName).mlmodelc/weights/weight.bin",
                      estimatedBytes: weight),
                .init(remotePath: "\(rPrefix)\(name).mlmodelc/coremldata.bin",
                      localPath:  "\(localName).mlmodelc/coremldata.bin",
                      estimatedBytes: 1_000),
                .init(remotePath: "\(rPrefix)\(name).mlmodelc/model.mil",
                      localPath:  "\(localName).mlmodelc/model.mil",
                      estimatedBytes: 450_000),
                .init(remotePath: "\(rPrefix)\(name).mlmodelc/metadata.json",
                      localPath:  "\(localName).mlmodelc/metadata.json",
                      estimatedBytes: 8_000),
                .init(remotePath: "\(rPrefix)\(name).mlmodelc/analytics/coremldata.bin",
                      localPath:  "\(localName).mlmodelc/analytics/coremldata.bin",
                      estimatedBytes: 250),
            ]
        }

        // Prefill chunks: only metadata downloaded; weights are hardlinked from decode.
        func prefillMeta(_ n: Int) -> [GemmaFile] {
            let r = "prefill/chunk\(n)"
            let l = "prefill_chunk\(n)"
            return [
                .init(remotePath: "\(r).mlmodelc/coremldata.bin",           localPath: "\(l).mlmodelc/coremldata.bin",           estimatedBytes: 1_000),
                .init(remotePath: "\(r).mlmodelc/model.mil",                localPath: "\(l).mlmodelc/model.mil",                estimatedBytes: 450_000),
                .init(remotePath: "\(r).mlmodelc/metadata.json",            localPath: "\(l).mlmodelc/metadata.json",            estimatedBytes: 8_000),
                .init(remotePath: "\(r).mlmodelc/analytics/coremldata.bin", localPath: "\(l).mlmodelc/analytics/coremldata.bin", estimatedBytes: 250),
            ]
        }

        var f: [GemmaFile] = []

        // ── Decode chunks (sliding-window attention, 4-chunk legacy layout) ──
        f += mlc("swa", "chunk1",  weight: 155_436_864)
        f += mlc("swa", "chunk2",  weight: 133_963_968)
        f += mlc("swa", "chunk3",  weight: 325_282_880)
        f += mlc("swa", "chunk4",  weight: 526_874_880)

        // ── Prefill chunk metadata (weights linked post-download) ──
        f += (1...4).flatMap { prefillMeta($0) }

        // ── Text-decoder sidecars ──
        f += [
            .init(remotePath: "model_config.json",
                  localPath:  "model_config.json",                  estimatedBytes: 500),
            .init(remotePath: "hf_model/tokenizer.json",
                  localPath:  "hf_model/tokenizer.json",            estimatedBytes: 30_000_000),
            .init(remotePath: "hf_model/tokenizer_config.json",
                  localPath:  "hf_model/tokenizer_config.json",     estimatedBytes: 5_000),
            .init(remotePath: "hf_model/config.json",
                  localPath:  "hf_model/config.json",               estimatedBytes: 5_000),
            // Embedding tables: the 2.35 GB file is the largest single download
            .init(remotePath: "embed_tokens_q8.bin",
                  localPath:  "embed_tokens_q8.bin",                estimatedBytes: 402_653_184),
            .init(remotePath: "embed_tokens_scales.bin",
                  localPath:  "embed_tokens_scales.bin",            estimatedBytes: 524_288),
            .init(remotePath: "embed_tokens_per_layer_q8.bin",
                  localPath:  "embed_tokens_per_layer_q8.bin",      estimatedBytes: 2_348_810_240),
            .init(remotePath: "embed_tokens_per_layer_scales.bin",
                  localPath:  "embed_tokens_per_layer_scales.bin",  estimatedBytes: 524_288),
            .init(remotePath: "per_layer_projection.bin",
                  localPath:  "per_layer_projection.bin",           estimatedBytes: 27_525_120),
            .init(remotePath: "per_layer_norm_weight.bin",
                  localPath:  "per_layer_norm_weight.bin",          estimatedBytes: 1_024),
            // RoPE tables (stored under swa/ on HF, flat in local dir)
            .init(remotePath: "swa/cos_sliding.npy", localPath: "cos_sliding.npy", estimatedBytes: 4_194_432),
            .init(remotePath: "swa/sin_sliding.npy", localPath: "sin_sliding.npy", estimatedBytes: 4_194_432),
            .init(remotePath: "swa/cos_full.npy",    localPath: "cos_full.npy",    estimatedBytes: 8_388_736),
            .init(remotePath: "swa/sin_full.npy",    localPath: "sin_full.npy",    estimatedBytes: 8_388_736),
        ]

        // ── Vision encoder — for running-form photo / camera analysis ──
        f += mlc("", "vision",       weight: 320_000_000)
        f += mlc("", "vision_video", weight: 338_081_024)

        // ── Audio encoder — for voice coaching input ──
        f += mlc("", "audio", weight: 295_373_248)
        f += [
            .init(remotePath: "mel_filterbank.bin",     localPath: "mel_filterbank.bin",     estimatedBytes: 131_584),
            .init(remotePath: "audio_config.json",      localPath: "audio_config.json",      estimatedBytes: 500),
            .init(remotePath: "output_proj_weight.npy", localPath: "output_proj_weight.npy", estimatedBytes: 3_145_856),
            .init(remotePath: "output_proj_bias.npy",   localPath: "output_proj_bias.npy",   estimatedBytes: 3_200),
            .init(remotePath: "embed_proj_weight.npy",  localPath: "embed_proj_weight.npy",  estimatedBytes: 4_718_720),
        ]

        return f
    }()
}

// MARK: - URLSession download delegate (one instance per file)

/// Streams a single file to disk, reporting byte progress without buffering
/// the entire body in memory. Retains the URLSession to prevent early dealloc.
private final class FileDelegate: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private let destURL: URL
    private let onBytes: (Int64) -> Void
    private let onDone:  (Result<Int64, Error>) -> Void
    private var settled = false

    init(destURL: URL,
         onBytes: @escaping (Int64) -> Void,
         onDone:  @escaping (Result<Int64, Error>) -> Void) {
        self.destURL = destURL
        self.onBytes = onBytes
        self.onDone  = onDone
    }

    func retainSession(_ s: URLSession) { session = s }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite _: Int64) {
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !settled else { return }
        settled = true
        self.session = nil
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
            try fm.moveItem(at: location, to: destURL)
            let bytes = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
            onDone(.success(bytes))
        } catch {
            onDone(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard !settled, let error else { return }
        settled = true
        self.session = nil
        onDone(.failure(error))
    }
}
