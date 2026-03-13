// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Orchestrates screenshot capture, text recognition, and tap-point computation.
// ABOUTME: Delegates raw OCR to a pluggable TextRecognizing backend for the describe_screen tool.

import CoreGraphics
import Foundation
import HelperLib
import ImageIO

/// Runs OCR on the iPhone Mirroring window screenshot and returns detected
/// text elements with their tap coordinates in the mirroring window's point space.
final class ScreenDescriber: Sendable {
    private let bridge: any WindowBridging
    private let capture: any ScreenCapturing
    private let textRecognizer: any TextRecognizing
    private let isMobile: Bool

    init(
        bridge: any WindowBridging,
        capture: any ScreenCapturing,
        textRecognizer: any TextRecognizing = AppleVisionTextRecognizer(),
        isMobile: Bool = true
    ) {
        self.bridge = bridge
        self.capture = capture
        self.textRecognizer = textRecognizer
        self.isMobile = isMobile
    }

    /// Result of a describe operation: detected elements, unlabeled icons, navigation hints,
    /// plus the screenshot and OCR timing.
    struct DescribeResult: Sendable {
        let elements: [TapPoint]
        let icons: [IconDetector.DetectedIcon]
        let hints: [String]
        let screenshotBase64: String
        /// Time spent in OCR text recognition, in milliseconds.
        let ocrTimeMs: Int

        init(elements: [TapPoint], icons: [IconDetector.DetectedIcon] = [],
             hints: [String] = [], screenshotBase64: String, ocrTimeMs: Int = 0) {
            self.elements = elements
            self.icons = icons
            self.hints = hints
            self.screenshotBase64 = screenshotBase64
            self.ocrTimeMs = ocrTimeMs
        }
    }

    /// Capture the mirroring window, run OCR, and return detected text elements
    /// with their tap coordinates plus the screenshot as base64 PNG.
    func describe() -> DescribeResult? {
        guard let info = bridge.getWindowInfo(), info.windowID != 0 else { return nil }

        // Reuse the shared capture logic (window-ID with region fallback)
        guard let data = capture.captureData() else { return nil }

        // Create CGImage for text recognition (OCR runs on the clean image, before grid overlay)
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        let windowWidth = Double(info.size.width)
        let windowHeight = Double(info.size.height)

        // Detect the iOS content area and delegate text recognition to the
        // pluggable backend. The recognizer returns elements in window-point space.
        let contentBounds = ContentBoundsDetector.detect(image: cgImage)
        let ocrStart = CFAbsoluteTimeGetCurrent()
        let rawElements = textRecognizer.recognizeText(
            in: cgImage, windowSize: info.size, contentBounds: contentBounds
        )
        let ocrMs = Int((CFAbsoluteTimeGetCurrent() - ocrStart) * 1000)
        DebugLog.log("OCR", "level=\(EnvConfig.ocrRecognitionLevel) elements=\(rawElements.count) time=\(ocrMs)ms")

        // Apply smart tap-point offsets: short labels are shifted upward
        // toward the icon/button above them.
        let elements = TapPointCalculator.computeTapPoints(
            elements: rawElements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        // Detect unlabeled icons in OCR-empty zones (tab bars, toolbars)
        let icons = IconDetector.detect(
            image: cgImage, ocrElements: elements, windowSize: info.size
        )

        // Detect navigation patterns and generate target-appropriate hints
        let hints = NavigationHintDetector.detect(
            elements: elements, windowHeight: windowHeight, isMobile: isMobile
        )

        let griddedData = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
        let base64 = griddedData.base64EncodedString()

        return DescribeResult(elements: elements, icons: icons, hints: hints,
                              screenshotBase64: base64, ocrTimeMs: ocrMs)
    }

}
