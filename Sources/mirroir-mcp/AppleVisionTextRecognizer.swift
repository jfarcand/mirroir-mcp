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
// ABOUTME: Apple Vision framework backend for text recognition.
// ABOUTME: Converts VNRecognizeTextRequest observations into RawTextElements in window-point space; a stuck process reads in a fresh one.

import CoreGraphics
import Foundation
import HelperLib
import Vision

/// Recognizes text in screenshots using Apple's Vision framework (`VNRecognizeTextRequest`).
/// Coordinates are transformed from Vision's normalized bottom-left origin to
/// window-point top-left origin, with content-bounds scaling applied.
struct AppleVisionTextRecognizer: Sendable {

    /// Reads `image` in a separate process when every in-process attempt has
    /// failed. See `perform(on:)`.
    var freshProcessReader: @Sendable (CGImage) throws -> [RecognizedTextLine] = FreshProcessTextReader.read

    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) throws -> [RawTextElement] {
        let lines = try perform(on: image)

        let windowWidth = Double(windowSize.width)
        let windowHeight = Double(windowSize.height)

        // The display backing scale is uniform (same for X and Y on macOS).
        // Derive it from the X dimension, which is reliable — screencapture
        // does not add extra horizontal content beyond the window bounds.
        let backingScale = Double(image.width) / windowWidth

        // Image dimensions in point space. imagePointHeight may exceed
        // windowHeight when screencapture includes window chrome (rounded
        // corners, home indicator area) beyond the AX-reported window size.
        let imagePointHeight = Double(image.height) / backingScale

        // Content-to-window scaling: only applied when ContentBoundsDetector
        // found SIGNIFICANT dark borders (Larger display mode). Small
        // differences (< 5% per axis) are ignored — they come from the
        // phone's rounded corners and home indicator, not from display mode
        // borders. In Larger mode the content is typically 10-20% smaller.
        let widthMargin = Double(image.width) * 0.05
        let heightMargin = Double(image.height) * 0.05
        let bordersDetected = Double(contentBounds.width) < Double(image.width) - widthMargin
            && Double(contentBounds.height) < Double(image.height) - heightMargin

        let xScale: Double
        let yScale: Double
        if bordersDetected {
            let contentWidth = Double(contentBounds.width) / backingScale
            let contentHeight = Double(contentBounds.height) / backingScale
            xScale = windowWidth / max(contentWidth, 1.0)
            yScale = windowHeight / max(contentHeight, 1.0)
        } else {
            xScale = 1.0
            yScale = 1.0
        }

        if bordersDetected {
            DebugLog.log("OCR", "Larger-mode scaling: contentBounds=\(Int(contentBounds.width))x\(Int(contentBounds.height)) yScale=\(String(format: "%.3f", yScale))")
        }

        // Convert Vision normalized coordinates (origin: bottom-left) to
        // tap-point coordinates (origin: top-left of mirroring window).
        // Vision normalizes to the full image, so we convert through the
        // actual image dimensions (imagePointHeight), not windowHeight.
        return lines.map { line in
            let bbox = line.boundingBox
            return RawTextElement(
                text: line.text,
                tapX: (bbox.midX * windowWidth) * xScale,
                textTopY: ((1.0 - bbox.maxY) * imagePointHeight) * yScale,
                textBottomY: ((1.0 - bbox.minY) * imagePointHeight) * yScale,
                bboxWidth: bbox.width * windowWidth * xScale,
                confidence: line.confidence
            )
        }
    }

    /// Read `image`: in this process first, then in a fresh process.
    ///
    /// The first attempt can fail while the Neural Engine compiles its
    /// precompiled model — an `e5rtError` from that path takes the whole request
    /// down even though the same image succeeds moments later. A plain retry
    /// covers the transient case; pinning the compute device to the CPU covers a
    /// machine where that path stays broken, at the cost of speed.
    ///
    /// None of that helps once the compiled model this process loaded has been
    /// removed from its cache (`~/Library/Caches/<executable>/com.apple.e5rt.e5bundlecache`):
    /// every request in the process then fails with the same `e5rtError` within
    /// milliseconds, whatever the device or handler, while a new process reads
    /// the same image normally (carnet#90, measured on macOS 27.2.1). A
    /// long-running server would stay blind, so the last step reads the image
    /// in a fresh process.
    private func perform(on image: CGImage) throws -> [RecognizedTextLine] {
        try Self.read(image, inProcess: inProcessLines(in:), freshProcess: freshProcessReader)
    }

    /// `inProcess(image)`, or `freshProcess(image)` when it throws. When both
    /// throw, the in-process error is the one reported.
    static func read(_ image: CGImage,
                     inProcess: (CGImage) throws -> [RecognizedTextLine],
                     freshProcess: (CGImage) throws -> [RecognizedTextLine]) throws -> [RecognizedTextLine] {
        do {
            return try inProcess(image)
        } catch {
            DebugLog.persist("OCR", "reading in a fresh process")
            do {
                return try freshProcess(image)
            } catch let freshError {
                DebugLog.persist("OCR", "fresh-process read failed (\(freshError))")
                throw error
            }
        }
    }

    /// Read `image` in this process: an attempt, a retry, then on the CPU.
    ///
    /// - Throws: `TextRecognitionError.visionRequestFailed` when all three fail.
    func inProcessLines(in image: CGImage) throws -> [RecognizedTextLine] {
        do {
            return try attempt(on: image, cpuOnly: false)
        } catch {
            DebugLog.persist("OCR", "Vision attempt failed (\(error)) — retrying")
        }

        do {
            return try attempt(on: image, cpuOnly: false)
        } catch {
            DebugLog.persist("OCR", "Vision retry failed (\(error)) — falling back to CPU")
        }

        do {
            return try attempt(on: image, cpuOnly: true)
        } catch {
            DebugLog.persist("OCR", "Vision CPU fallback failed (\(error))")
            throw TextRecognitionError.visionRequestFailed(underlying: error)
        }
    }

    /// One Vision pass over `image`, optionally forced onto the CPU.
    private func attempt(on image: CGImage, cpuOnly: Bool) throws -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = EnvConfig.ocrRecognitionLevel == "fast" ? .fast : .accurate
        request.usesLanguageCorrection = EnvConfig.ocrLanguageCorrection
        request.recognitionLanguages = try recognitionLanguages(for: request)
        if cpuOnly {
            pinToCPU(request)
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(text: candidate.string, boundingBox: observation.boundingBox,
                                      confidence: candidate.confidence)
        }
    }

    /// The configured `ocrLanguages`, or the Mac's preferred languages then
    /// English, each matched to a code `request` supports at its level.
    private func recognitionLanguages(for request: VNRecognizeTextRequest) throws -> [String] {
        let requested = EnvConfig.ocrLanguages
            ?? OCRLanguageResolver.defaultRequest(preferred: Locale.preferredLanguages)
        let supported = try request.supportedRecognitionLanguages()
        let unmatched = OCRLanguageResolver.unmatched(requested: requested, supported: supported)
        if !unmatched.isEmpty {
            DebugLog.log("OCR", "Vision does not read \(unmatched); requesting the rest")
        }
        return OCRLanguageResolver.resolve(requested: requested, supported: supported)
    }

    /// Route every stage of `request` to the CPU, where the device offers one.
    ///
    /// Best-effort: a stage with no CPU device listed keeps its default, and a
    /// machine that cannot report its devices at all simply runs unpinned —
    /// either way the attempt still happens and any failure surfaces normally.
    private func pinToCPU(_ request: VNRequest) {
        guard let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            for device in devices {
                if case .cpu = device {
                    request.setComputeDevice(device, for: stage)
                    break
                }
            }
        }
    }
}

/// One line of text Vision read: its string, its normalized bounding box
/// (origin bottom-left, as Vision reports it) and its confidence. Codable so a
/// fresh process can hand its lines back (`recognize-text`).
struct RecognizedTextLine: Codable, Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}
