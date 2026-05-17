// VisionManager.swift
// Phase 1, 2, 3 & 4: Camera Pipeline, Danger Scorer, Visual Prompting & Advanced Refinements (Thermal, IoU Tracking & Stride Throttling)

import Foundation
import AVFoundation
import Vision
import UIKit

/// CoreGraphics utility to overlay bounding boxes directly onto the captured camera frames
struct ImageAnnotator {
    static func drawBoundingBox(on pixelBuffer: CVPixelBuffer, rect: CGRect, label: String) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Setup CoreGraphics context to draw over the original image
        guard let colorSpace = cgImage.colorSpace,
              let cgContext = CGContext(data: nil,
                                        width: width,
                                        height: height,
                                        bitsPerComponent: cgImage.bitsPerComponent,
                                        bytesPerRow: cgImage.bytesPerRow,
                                        space: colorSpace,
                                        bitmapInfo: cgImage.bitmapInfo.rawValue) else {
            return nil
        }
        
        // 1. Draw original camera frame
        cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // 2. Convert Vision normalized rect (0..1, origin bottom-left) to CoreGraphics pixels (origin bottom-left)
        let absoluteRect = CGRect(
            x: rect.origin.x * CGFloat(width),
            y: rect.origin.y * CGFloat(height),
            width: rect.size.width * CGFloat(width),
            height: rect.size.height * CGFloat(height)
        )
        
        // 3. Draw heavy red outline around threat
        cgContext.setStrokeColor(UIColor.red.cgColor)
        cgContext.setLineWidth(CGFloat(max(6, width / 80))) // Bold visible line
        cgContext.stroke(absoluteRect)
        
        return cgContext.makeImage()
    }
}

/// Phase 4 Helper: Lightweight Intersection-over-Union (IoU) object tracker
struct BoundingBoxTracker {
    static func intersectionOverUnion(_ rectA: CGRect, _ rectB: CGRect) -> CGFloat {
        let intersection = rectA.intersection(rectB)
        if intersection.isNull { return 0.0 }
        
        let intersectionArea = intersection.width * intersection.height
        let areaA = rectA.width * rectA.height
        let areaB = rectB.width * rectB.height
        let unionArea = areaA + areaB - intersectionArea
        
        return unionArea > 0 ? intersectionArea / unionArea : 0.0
    }
}

@MainActor
final class VisionManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    @Published var isRunning: Bool = false
    @Published var latestDetections: [String] = []
    
    private var captureSession: AVCaptureSession?
    private let videoDataOutputQueue = DispatchQueue(label: "VisionManager.VideoDataOutputQueue")
    
    // Core references & speech
    private weak var liveSession: LiveSession?
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    // Cooldown management
    private var lastFastPathWarningTime: Date?
    private var lastGemmaWarningTime: Date?
    
    // Phase 4: Thermal & Stride Throttling states
    private var gemmaPerceptionEnabled: Bool = true
    private var frameCounter: Int = 0
    private var previousUpcomingRects: [CGRect] = []
    
    override init() {
        super.init()
        setupThermalObserver()
    }
    
    func attach(liveSession: LiveSession) {
        self.liveSession = liveSession
    }
    
    // MARK: - Phase 4: Thermal Monitoring
    
    private func setupThermalObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        // Set initial FPS matching current thermals
        adjustFrameRateForThermalState()
    }
    
    @objc private func thermalStateChanged() {
        Task { @MainActor in
            self.adjustFrameRateForThermalState()
        }
    }
    
    private func adjustFrameRateForThermalState() {
        guard let captureSession = captureSession, captureSession.isRunning else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        
        let state = ProcessInfo.processInfo.thermalState
        let targetFPS: Int
        
        switch state {
        case .nominal:
            targetFPS = 10
            gemmaPerceptionEnabled = true
            print("🌡️ Thermal state: nominal. Vision running at 10 FPS (Full).")
        case .fair:
            targetFPS = 5
            gemmaPerceptionEnabled = true
            print("🌡️ Thermal state: fair. Downscaled Vision to 5 FPS.")
        case .serious:
            targetFPS = 2
            gemmaPerceptionEnabled = false // Disable slow path (Gemma) to save GPU energy
            print("🌡️ Thermal state: serious! Downscaled Vision to 2 FPS. Slow-path Gemma disabled.")
        case .critical:
            targetFPS = 1
            gemmaPerceptionEnabled = false // Rely purely on local Fast Path
            print("🌡️ Thermal state: critical! Downscaled Vision to 1 FPS. Slow-path Gemma disabled.")
        @unknown default:
            targetFPS = 10
            gemmaPerceptionEnabled = true
        }
        
        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(targetFPS))
            camera.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(targetFPS))
            camera.unlockForConfiguration()
        } catch {
            print("Failed to dynamically configure camera frame rate under thermal state change: \(error)")
        }
    }
    
    // MARK: - Perception Processing (Diamond Split & IoU Tracking)
    
    private func processObservations(_ observations: [VNHumanObservation], in pixelBuffer: CVPixelBuffer) {
        var detections: [String] = []
        var hasNearHazard = false
        var hasUpcomingHazard = false
        var upcomingHazardRect: CGRect? = nil
        
        var currentUpcomingRects: [CGRect] = []
        var isNewUpcomingHazard = false
        
        for obs in observations {
            let normalizedY = obs.boundingBox.origin.y // 0 at bottom of frame, 1 at top
            let area = obs.boundingBox.width * obs.boundingBox.height
            
            // Proximity score: closer to 1.0 is extremely close, 0.0 is far away.
            let proximityScore = (1.0 - normalizedY) * 0.6 + area * 0.4
            
            let zone: String
            if proximityScore >= 0.7 {
                zone = "🚨 NEAR"
                hasNearHazard = true
            } else if proximityScore >= 0.35 {
                zone = "⚠️ UPCOMING"
                hasUpcomingHazard = true
                currentUpcomingRects.append(obs.boundingBox)
                
                // Phase 4: IoU Object Tracking to suppress duplicate alerts for the same approaching obstacle
                let isAlreadyTracked = previousUpcomingRects.contains { prevRect in
                    BoundingBoxTracker.intersectionOverUnion(obs.boundingBox, prevRect) > 0.40
                }
                
                if !isAlreadyTracked {
                    isNewUpcomingHazard = true
                    if upcomingHazardRect == nil {
                        upcomingHazardRect = obs.boundingBox
                    }
                }
            } else {
                zone = "✅ SAFE"
            }
            
            detections.append("Person (\(zone) - prox: \(String(format: "%.2f", proximityScore)))")
        }
        
        self.latestDetections = detections
        // Save current tracks for comparison in the next frame
        self.previousUpcomingRects = currentUpcomingRects
        
        // Diamond Split Routing
        if hasNearHazard {
            self.triggerFastPathWarning()
        } else if hasUpcomingHazard, isNewUpcomingHazard, gemmaPerceptionEnabled, let rect = upcomingHazardRect {
            // Phase 3 Slow Path: Draw bounding box on the exact frame containing the threat
            if let annotatedImage = ImageAnnotator.drawBoundingBox(on: pixelBuffer, rect: rect, label: "person") {
                self.triggerGemmaWarning(annotatedImage: annotatedImage)
            } else {
                self.triggerGemmaWarning(annotatedImage: nil)
            }
        }
    }
    
    private func triggerFastPathWarning() {
        let now = Date()
        if let lastWarning = lastFastPathWarningTime, now.timeIntervalSince(lastWarning) < 4.0 {
            return // Cooldown active
        }
        
        lastFastPathWarningTime = now
        print("🚨 FAST PATH: Triggering immediate haptic & audio warning")
        
        // 1. Trigger heavy haptic pulse
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
        
        // 2. Play instant, hardcoded TTS bypassing the LLM
        let utterance = AVSpeechUtterance(string: "Caution! Person ahead!")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.15 // Rapid/urgent speaking rate
        speechSynthesizer.speak(utterance)
    }
    
    private func triggerGemmaWarning(annotatedImage: CGImage?) {
        let now = Date()
        if let lastWarning = lastGemmaWarningTime, now.timeIntervalSince(lastWarning) < 8.0 {
            return // Cooldown active
        }
        
        lastGemmaWarningTime = now
        print("⚠️ SLOW PATH: Alerting Gemma with annotated image...")
        
        // Trigger LiveSession multimodal slow path reasoning
        liveSession?.fireHazardInterrupt(
            hazardLabel: "person",
            depthMeters: 3.0,
            hazardScore: 0.85,
            annotatedImage: annotatedImage
        )
    }
    
    // MARK: - Camera Controls
    
    func startCamera() {
        guard !isRunning else { return }
        
        Task {
            let authorized = await requestCameraPermission()
            guard authorized else {
                print("Camera permission denied.")
                return
            }
            
            setupCameraSession()
            captureSession?.startRunning()
            isRunning = true
            adjustFrameRateForThermalState() // Align FPS with thermals immediately on start
            print("🎥 VisionManager Camera Session Started")
        }
    }
    
    func stopCamera() {
        guard isRunning else { return }
        captureSession?.stopRunning()
        isRunning = false
        print("🛑 VisionManager Camera Session Stopped")
    }
    
    private func requestCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return false
    }
    
    private func setupCameraSession() {
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480 // Low resolution is fine and much faster for Neural Engine
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            print("Failed to get camera input")
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
        }
        
        self.captureSession = session
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // This is called ~10 times per second
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Phase 4: Stride Cadence Motion Mitigation
            // If the runner has a high cadence (e.g. actively running), drop alternate frames to prevent motion blur parsing.
            if let metrics = self.liveSession?.metrics {
                let cadence = metrics.currentCadenceSPM
                if cadence > 130 {
                    self.frameCounter += 1
                    if self.frameCounter % 2 != 0 {
                        return // Skip processing this frame
                    }
                }
            }
            
            let request = VNDetectHumanRectanglesRequest { [weak self] request, error in
                guard let self = self,
                      let observations = request.results as? [VNHumanObservation],
                      error == nil else {
                    return
                }
                self.processObservations(observations, in: pixelBuffer)
            }
            
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try requestHandler.perform([request])
            } catch {
                print("Failed to perform vision request: \(error)")
            }
        }
    }
}
