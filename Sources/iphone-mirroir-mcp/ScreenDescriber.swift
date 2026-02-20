// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Uses Apple's Vision framework to detect text elements in screenshots.
// ABOUTME: Returns text content with tap-point coordinates for the describe_screen tool.

import CoreGraphics
import Foundation
import HelperLib
import Vision

/// Runs OCR on the iPhone Mirroring window screenshot and returns detected
/// text elements with their tap coordinates in the mirroring window's point space.
final class ScreenDescriber: Sendable {
    private let bridge: any WindowBridging
    private let capture: any ScreenCapturing

    init(bridge: any WindowBridging, capture: any ScreenCapturing) {
        self.bridge = bridge
        self.capture = capture
    }

    /// Result of a describe operation: detected elements, navigation hints, plus the screenshot.
    struct DescribeResult: Sendable {
        let elements: [TapPoint]
        let hints: [String]
        let screenshotBase64: String

        init(elements: [TapPoint], hints: [String] = [], screenshotBase64: String) {
            self.elements = elements
            self.hints = hints
            self.screenshotBase64 = screenshotBase64
        }
    }

    /// Capture the mirroring window, run OCR, and return detected text elements
    /// with their tap coordinates plus the screenshot as base64 PNG.
    /// When `skipOCR` is true, returns only the grid-overlaid screenshot with
    /// an empty elements array, letting the MCP client use its own vision model.
    func describe(skipOCR: Bool = false) -> DescribeResult? {
        guard let info = bridge.getWindowInfo(), info.windowID != 0 else { return nil }

        // Reuse the shared capture logic (window-ID with region fallback)
        guard let data = capture.captureData() else { return nil }

        // Return grid-overlaid screenshot without running OCR
        if skipOCR {
            let griddedData = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
            return DescribeResult(elements: [], hints: [], screenshotBase64: griddedData.base64EncodedString())
        }

        // Create CGImage for Vision (OCR runs on the clean image, before grid overlay)
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        // Run OCR with accurate recognition
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            let fallback = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
            return DescribeResult(elements: [], hints: [], screenshotBase64: fallback.base64EncodedString())
        }

        guard let observations = request.results else {
            let fallback = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
            return DescribeResult(elements: [], hints: [], screenshotBase64: fallback.base64EncodedString())
        }

        let windowWidth = Double(info.size.width)
        let windowHeight = Double(info.size.height)

        // Detect the iOS content area within the window. In "Larger" display mode,
        // iOS content renders at 1:1 from the top-left with dark borders on the
        // right and bottom. OCR reports pixel positions within the window, but macOS
        // normalizes taps across the full window — so we must scale OCR coordinates
        // to compensate.
        let contentPixelRect = ContentBoundsDetector.detect(image: cgImage)
        let displayScale = Double(cgImage.width) / windowWidth
        let contentOriginX = Double(contentPixelRect.minX) / displayScale
        let contentOriginY = Double(contentPixelRect.minY) / displayScale
        let contentWidth = Double(contentPixelRect.width) / displayScale
        let contentHeight = Double(contentPixelRect.height) / displayScale
        let xScale = windowWidth / max(contentWidth, 1.0)
        let yScale = windowHeight / max(contentHeight, 1.0)

        // Convert Vision normalized coordinates (origin: bottom-left) to
        // tap-point coordinates (origin: top-left of mirroring window).
        // Vision bbox.maxY is the top in normalized space → smallest Y in window space.
        // The content-bounds correction maps OCR positions (which are within the
        // content area) to full-window coordinates that macOS will normalize correctly.
        let rawElements: [RawTextElement] = observations.compactMap { observation in
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

        // Apply smart tap-point offsets: short labels are shifted upward
        // toward the icon/button above them.
        let elements = TapPointCalculator.computeTapPoints(
            elements: rawElements, windowWidth: windowWidth
        )

        // Detect navigation patterns and generate keyboard shortcut hints
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight
        )

        let griddedData = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
        let base64 = griddedData.base64EncodedString()

        return DescribeResult(elements: elements, hints: hints, screenshotBase64: base64)
    }

}
