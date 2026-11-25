/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
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
    /// The model's class label for an icon, carried as the element's `text`.
    static let iconLabel = "icon"

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

        let mapping = WindowPointMapping(
            imageWidth: image.width, imageHeight: image.height,
            windowSize: windowSize, contentBounds: contentBounds)
        return results.compactMap { observation in
            guard let topLabel = observation.labels.first,
                  topLabel.confidence >= confidenceThreshold
            else { return nil }

            return Self.convertBoundingBox(
                bbox: observation.boundingBox,
                label: topLabel.identifier,
                confidence: topLabel.confidence,
                mapping: mapping
            )
        }
    }

    /// Convert a Vision normalized bounding box to a `RawTextElement` in window-point space,
    /// through the same `WindowPointMapping` as `AppleVisionTextRecognizer`, so an icon lands
    /// where text at the same place does. A detection whose point falls outside the window
    /// is dropped: no tap there reaches the phone.
    ///
    /// Extracted as a static method for unit-testability without a real model.
    static func convertBoundingBox(
        bbox: CGRect,
        label: String,
        confidence: Float,
        mapping: WindowPointMapping
    ) -> RawTextElement? {
        let element = mapping.element(text: label, bbox: bbox, confidence: confidence)
        guard mapping.contains(element) else {
            DebugLog.log("YOLO", "Dropped '\(label)' at (\(Int(element.tapX)), \(Int(element.textTopY))) outside the \(Int(mapping.windowWidth))x\(Int(mapping.windowHeight)) window")
            return nil
        }
        return element
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
