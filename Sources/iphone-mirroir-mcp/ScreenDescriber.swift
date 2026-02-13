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
final class ScreenDescriber: @unchecked Sendable {
    private let bridge: MirroringBridge

    init(bridge: MirroringBridge) {
        self.bridge = bridge
    }

    /// A text element detected via OCR with its tap-point coordinates.
    struct DetectedElement: Sendable {
        /// The recognized text string.
        let text: String
        /// X coordinate in points, relative to the mirroring window top-left.
        let tapX: Double
        /// Y coordinate in points, relative to the mirroring window top-left.
        let tapY: Double
        /// Vision confidence score (0.0–1.0).
        let confidence: Float
    }

    /// Result of a describe operation: detected elements plus the screenshot for visual context.
    struct DescribeResult: Sendable {
        let elements: [DetectedElement]
        let screenshotBase64: String
    }

    /// Capture the mirroring window, run OCR, and return detected text elements
    /// with their tap coordinates plus the screenshot as base64 PNG.
    func describe() -> DescribeResult? {
        guard let info = bridge.getWindowInfo(), info.windowID != 0 else { return nil }

        // Capture screenshot to temp file (same approach as ScreenCapture)
        let tempPath = NSTemporaryDirectory()
            + "iphone-mirroir-describe-\(ProcessInfo.processInfo.processIdentifier).png"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", String(info.windowID), "-x", "-o", tempPath]
        do {
            try process.run()
        } catch {
            return nil
        }

        // Wait with timeout to prevent indefinite hangs
        let completed = waitForProcess(process, timeoutSeconds: 10)
        if !completed {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let fileURL = URL(fileURLWithPath: tempPath)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        guard let data = try? Data(contentsOf: fileURL) else { return nil }

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
            return DescribeResult(elements: [], screenshotBase64: fallback.base64EncodedString())
        }

        guard let observations = request.results else {
            let fallback = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
            return DescribeResult(elements: [], screenshotBase64: fallback.base64EncodedString())
        }

        let windowWidth = Double(info.size.width)
        let windowHeight = Double(info.size.height)

        // Convert Vision normalized coordinates (origin: bottom-left) to
        // tap-point coordinates (origin: top-left of mirroring window).
        let elements: [DetectedElement] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let bbox = observation.boundingBox
            let tapX = bbox.midX * windowWidth
            let tapY = (1.0 - bbox.midY) * windowHeight
            return DetectedElement(
                text: candidate.string,
                tapX: tapX,
                tapY: tapY,
                confidence: candidate.confidence
            )
        }

        let griddedData = GridOverlay.addOverlay(to: data, windowSize: info.size) ?? data
        let base64 = griddedData.base64EncodedString()

        return DescribeResult(elements: elements, screenshotBase64: base64)
    }

    /// Wait for a process to exit within the given timeout.
    /// Returns true if the process exited, false if the timeout was reached.
    private func waitForProcess(_ process: Process, timeoutSeconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            usleep(50_000) // 50ms polling interval
        }
        return !process.isRunning
    }
}
