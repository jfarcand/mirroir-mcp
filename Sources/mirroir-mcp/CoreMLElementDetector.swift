// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CoreML backend for UI element detection using YOLO object detection models.
// ABOUTME: Conforms to TextRecognizing, emitting class labels as RawTextElement text fields.

import CoreGraphics
import CoreML
import Foundation
import HelperLib
import Vision

/// Detects UI elements (buttons, icons, text fields, toggles, etc.) in screenshots
/// using a YOLO CoreML model via `VNCoreMLRequest`. Class labels become the `text`
/// field of `RawTextElement`, enabling element-type detection alongside Vision OCR.
struct CoreMLElementDetector: Sendable {
    private let modelURL: URL
    private let confidenceThreshold: Float

    /// Thread-safe lazy cache for the compiled MLModel.
    /// Loading and compiling a model is expensive; we do it once per process lifetime.
    private static let modelLock = NSLock()
    nonisolated(unsafe) private static var cachedModel: VNCoreMLModel?
    nonisolated(unsafe) private static var cachedModelURL: URL?

    init(modelURL: URL, confidenceThreshold: Double) {
        self.modelURL = modelURL
        self.confidenceThreshold = Float(confidenceThreshold)
    }

    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) -> [RawTextElement] {
        guard let model = loadModel() else { return [] }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            DebugLog.log("YOLO", "Inference failed: \(error.localizedDescription)")
            return []
        }

        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            return []
        }

        return results.compactMap { observation in
            guard let topLabel = observation.labels.first,
                  topLabel.confidence >= confidenceThreshold
            else { return nil }

            return Self.convertBoundingBox(
                bbox: observation.boundingBox,
                label: topLabel.identifier,
                confidence: topLabel.confidence,
                windowSize: windowSize,
                contentBounds: contentBounds,
                imageWidth: image.width
            )
        }
    }

    /// Convert a Vision normalized bounding box to a `RawTextElement` in window-point space.
    ///
    /// Uses the same coordinate transform as `AppleVisionTextRecognizer`:
    /// Vision bounding boxes are normalized with origin at bottom-left;
    /// we convert to window-point coordinates with origin at top-left,
    /// applying content-bounds scaling for "Larger" display modes.
    ///
    /// Extracted as a static method for unit-testability without a real model.
    static func convertBoundingBox(
        bbox: CGRect,
        label: String,
        confidence: Float,
        windowSize: CGSize,
        contentBounds: CGRect,
        imageWidth: Int
    ) -> RawTextElement {
        let windowWidth = Double(windowSize.width)
        let windowHeight = Double(windowSize.height)

        let displayScale = Double(imageWidth) / windowWidth
        let contentOriginX = Double(contentBounds.minX) / displayScale
        let contentOriginY = Double(contentBounds.minY) / displayScale
        let contentWidth = Double(contentBounds.width) / displayScale
        let contentHeight = Double(contentBounds.height) / displayScale
        let xScale = windowWidth / max(contentWidth, 1.0)
        let yScale = windowHeight / max(contentHeight, 1.0)

        return RawTextElement(
            text: label,
            tapX: (bbox.midX * windowWidth - contentOriginX) * xScale,
            textTopY: ((1.0 - bbox.maxY) * windowHeight - contentOriginY) * yScale,
            textBottomY: ((1.0 - bbox.minY) * windowHeight - contentOriginY) * yScale,
            bboxWidth: bbox.width * windowWidth * xScale,
            confidence: confidence
        )
    }

    // MARK: - Private

    /// Load the VNCoreMLModel, caching it for subsequent calls.
    private func loadModel() -> VNCoreMLModel? {
        Self.modelLock.lock()
        defer { Self.modelLock.unlock() }

        if let cached = Self.cachedModel, Self.cachedModelURL == modelURL {
            return cached
        }

        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            let vnModel = try VNCoreMLModel(for: mlModel)
            Self.cachedModel = vnModel
            Self.cachedModelURL = modelURL
            DebugLog.log("YOLO", "Model loaded: \(modelURL.lastPathComponent)")
            return vnModel
        } catch {
            DebugLog.persist("YOLO", "Failed to load model at \(modelURL.path): \(error.localizedDescription)")
            return nil
        }
    }
}
