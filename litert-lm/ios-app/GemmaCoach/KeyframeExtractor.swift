// KeyframeExtractor.swift
// Uses Apple's Neural Engine to filter out redundant images before sending to Gemma.

import Foundation
import UIKit
import Vision

/// A native iOS utility to extract distinct keyframes from a stream of images.
actor KeyframeExtractor {
    
    /// Filters an array of images, returning only the ones where the scene meaningfully changed.
    /// - Parameters:
    ///   - images: The sequential array of images (e.g., 100 frames from a runner's video).
    ///   - distanceThreshold: How different two frames must be to be considered a new "Keyframe".
    ///                        Higher = fewer keyframes. Lower = more keyframes. 
    ///                        (10.0 to 15.0 is a great starting point for Vision).
    /// - Returns: A smaller array of visually distinct UIImages (e.g., 60 frames).
    func extractKeyframes(from images: [UIImage], distanceThreshold: Float = 15.0) async throws -> [UIImage] {
        guard !images.isEmpty else { return [] }
        if images.count == 1 { return images }
        
        var keyframes: [UIImage] = []
        var lastFeaturePrint: VNFeaturePrintObservation? = nil
        
        // This is Apple's built-in deep learning embedding model!
        let request = VNGenerateImageFeaturePrintRequest()
        
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            
            // Generate the embedding for the current image
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            
            guard let featurePrint = request.results?.first as? VNFeaturePrintObservation else {
                continue
            }
            
            // Compare it against the previous keyframe
            if let previousPrint = lastFeaturePrint {
                var distance: Float = 0
                
                // Calculates the semantic difference between the two images
                try featurePrint.computeDistance(&distance, to: previousPrint)
                
                // If the distance is greater than the threshold, the runner actually moved!
                if distance > distanceThreshold {
                    keyframes.append(image)
                    lastFeaturePrint = featurePrint
                }
            } else {
                // Always keep the very first frame
                keyframes.append(image)
                lastFeaturePrint = featurePrint
            }
        }
        
        return keyframes
    }
}
