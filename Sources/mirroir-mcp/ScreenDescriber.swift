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
        /// Why text recognition failed, when it did. Nil means the engine ran:
        /// an empty `elements` list then genuinely means no text on screen.
        let ocrFailure: String?
        /// Token counts the vision model reported for this frame. Nil for the
        /// OCR describer, and for vision providers that do not report usage.
        let visionUsage: ChatCompletionUsage?
        /// The described frame was a uniform fill (rotation, launch, scene swap):
        /// `elements` is empty because the screen is transitioning, not because
        /// it holds no text. The vision describer makes no model call for it.
        let screenBlank: Bool

        init(elements: [TapPoint], icons: [IconDetector.DetectedIcon] = [],
             hints: [String] = [], screenshotBase64: String, ocrTimeMs: Int = 0,
             ocrFailure: String? = nil, visionUsage: ChatCompletionUsage? = nil,
             screenBlank: Bool = false) {
            self.elements = elements
            self.icons = icons
            self.hints = hints
            self.screenshotBase64 = screenshotBase64
            self.ocrTimeMs = ocrTimeMs
            self.ocrFailure = ocrFailure
            self.visionUsage = visionUsage
            self.screenBlank = screenBlank
        }
    }

    /// Capture the mirroring window, run OCR, and return detected text elements
    /// with their tap coordinates plus the screenshot as base64 PNG.
    ///
    /// Nil `settleTimeoutUs` describes the first frame: local OCR is cheap and
    /// its callers poll with their own retry delays, so waiting for a settled
    /// frame would only add latency (the full settle window on an animated screen).
    func describe(settleTimeoutUs: UInt32?) -> DescribeResult? {
        guard let frame = capture.captureSettledWithInfo(timeoutUs: settleTimeoutUs ?? 0) else {
            return nil
        }
        return describe(frame: frame)
    }

    /// Run OCR and icon detection on an already captured `frame`.
    func describe(frame: CaptureResult) -> DescribeResult? {
        let info = frame.info
        let data = frame.data

        // Create CGImage for text recognition (OCR runs on the clean image, before grid overlay)
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return nil }

        // Upscale small screenshots so Apple Vision can resolve text on
        // narrow zoom modes (e.g. "Smaller" at ~424px). The coordinate math
        // in recognizers self-corrects because backingScale is derived from
        // the image/window ratio.
        let ocrImage = ImageUpscaler.upscaleIfNeeded(
            image: cgImage, minWidth: EnvConfig.ocrMinImageWidth
        )

        let windowWidth = Double(info.size.width)
        let windowHeight = Double(info.size.height)

        // Detect the iOS content area and delegate text recognition to the
        // pluggable backend. The recognizer returns elements in window-point space.
        let contentBounds = ContentBoundsDetector.detect(image: ocrImage)
        let ocrStart = CFAbsoluteTimeGetCurrent()
        // A recognition failure is reported, not folded into an empty result:
        // the rest of the description (screenshot, icons, hints) is still worth
        // returning, but the caller has to be told the text layer is missing
        // rather than empty.
        var rawElements: [RawTextElement] = []
        var ocrFailure: String?
        do {
            rawElements = try textRecognizer.recognizeText(
                in: ocrImage, windowSize: info.size, contentBounds: contentBounds
            )
        } catch {
            ocrFailure = String(describing: error)
            DebugLog.persist("OCR", "text recognition failed: \(ocrFailure ?? "")")
        }
        let ocrMs = Int((CFAbsoluteTimeGetCurrent() - ocrStart) * 1000)
        DebugLog.log("OCR", "level=\(EnvConfig.ocrRecognitionLevel) elements=\(rawElements.count) time=\(ocrMs)ms")

        // Apply smart tap-point offsets: short labels are shifted upward
        // toward the icon/button above them.
        let elements = TapPointCalculator.computeTapPoints(
            elements: rawElements, windowWidth: windowWidth, windowHeight: windowHeight
        )

        // Detect unlabeled icons in OCR-empty zones (tab bars, toolbars)
        let icons = IconDetector.detect(
            image: ocrImage, ocrElements: elements, windowSize: info.size
        )

        // Detect navigation patterns and generate target-appropriate hints.
        // Detected icon positions feed tab-bar detection so icon-only tab
        // bars (no OCR text) still produce a tab-bar hint.
        let iconPoints = icons.map {
            TapPoint(text: "", tapX: $0.tapX, tapY: $0.tapY, confidence: 1.0)
        }
        let hints = NavigationHintDetector.detect(
            elements: elements, iconPoints: iconPoints,
            windowHeight: windowHeight, isMobile: isMobile
        )

        // Local OCR is cheap, so it always runs; the blank flag only explains
        // an empty result, matching what the vision describer reports.
        let screenBlank = elements.isEmpty && icons.isEmpty && ocrFailure == nil
            && BlankFrameDetector.isBlank(cgImage)

        let griddedData = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
        let base64 = griddedData.base64EncodedString()

        return DescribeResult(elements: elements, icons: icons, hints: hints,
                              screenshotBase64: base64, ocrTimeMs: ocrMs,
                              ocrFailure: ocrFailure, screenBlank: screenBlank)
    }

}
