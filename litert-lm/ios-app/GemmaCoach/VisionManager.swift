// VisionManager.swift
// Phase 1: Camera Pipeline and Vision Integration

import Foundation
import AVFoundation
import Vision

@MainActor
final class VisionManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    @Published var isRunning: Bool = false
    @Published var latestDetections: [String] = []
    
    private var captureSession: AVCaptureSession?
    private let videoDataOutputQueue = DispatchQueue(label: "VisionManager.VideoDataOutputQueue")
    
    // For Phase 1 testing, we will use Apple's built-in human detector instead of a custom YOLO model.
    // This runs natively on the Apple Neural Engine out of the box!
    private var humanDetectionRequest: VNDetectHumanRectanglesRequest!
    
    override init() {
        super.init()
        setupVision()
    }
    
    private func setupVision() {
        humanDetectionRequest = VNDetectHumanRectanglesRequest { [weak self] request, error in
            guard let observations = request.results as? [VNHumanObservation], error == nil else {
                return
            }
            
            // Map observations to a string array for debugging
            let detections = observations.map { obs -> String in
                return "Person (confidence: \(String(format: "%.2f", obs.confidence)), bounds: \(obs.boundingBox))"
            }
            
            Task { @MainActor in
                self?.latestDetections = detections
                if !detections.isEmpty {
                    print("👀 Vision Detections: \(detections)")
                }
            }
        }
    }
    
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
        // We only need the latest frame. If the ANE is busy, drop older frames to prevent lag.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        // Optional: reduce frame rate to 10-15fps to save battery and reduce thermal load
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
        }
        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 10) // 10 FPS
            camera.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 10)
            camera.unlockForConfiguration()
        } catch {
            print("Could not configure camera frame rate")
        }
        
        self.captureSession = session
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // This is called ~10 times per second
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        do {
            try requestHandler.perform([Task { @MainActor in self.humanDetectionRequest }.value])
        } catch {
            print("Failed to perform vision request: \(error)")
        }
    }
}
