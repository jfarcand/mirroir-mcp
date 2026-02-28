// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Apple Vision framework backend for text recognition.
// ABOUTME: Converts VNRecognizeTextRequest observations into RawTextElements in window-point space.

import CoreGraphics
import Foundation
import HelperLib
import Vision

/// Recognizes text in screenshots using Apple's Vision framework (`VNRecognizeTextRequest`).
/// Coordinates are transformed from Vision's normalized bottom-left origin to
/// window-point top-left origin, with content-bounds scaling applied.
struct AppleVisionTextRecognizer: Sendable {

    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) -> [RawTextElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = EnvConfig.ocrRecognitionLevel == "fast" ? .fast : .accurate
        request.usesLanguageCorrection = EnvConfig.ocrLanguageCorrection

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        let windowWidth = Double(windowSize.width)
        let windowHeight = Double(windowSize.height)

        // Scale from content pixel rect to window points.
        // In "Larger" display mode, iOS content renders at 1:1 from top-left
        // with dark borders on right/bottom. OCR pixel positions must be
        // scaled to cover the full window for correct tap coordinates.
        let displayScale = Double(image.width) / windowWidth
        let contentOriginX = Double(contentBounds.minX) / displayScale
        let contentOriginY = Double(contentBounds.minY) / displayScale
        let contentWidth = Double(contentBounds.width) / displayScale
        let contentHeight = Double(contentBounds.height) / displayScale
        let xScale = windowWidth / max(contentWidth, 1.0)
        let yScale = windowHeight / max(contentHeight, 1.0)

        // Convert Vision normalized coordinates (origin: bottom-left) to
        // tap-point coordinates (origin: top-left of mirroring window).
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let bbox = observation.boundingBox
            return RawTextElement(
                text: candidate.string,
                tapX: (bbox.midX * windowWidth - contentOriginX) * xScale,
                textTopY: ((1.0 - bbox.maxY) * windowHeight - contentOriginY) * yScale,
                textBottomY: ((1.0 - bbox.minY) * windowHeight - contentOriginY) * yScale,
                bboxWidth: bbox.width * windowWidth * xScale,
                confidence: candidate.confidence
            )
        }
    }
}
