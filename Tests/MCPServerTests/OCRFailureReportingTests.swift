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
// ABOUTME: Tests that a broken OCR engine is reported as failure, never as an empty screen.
// ABOUTME: Covers the recognizer contract, the composite, the describe result, and the self-test.

import CoreGraphics
import Foundation
import HelperLib
import ImageIO
import Testing
@testable import mirroir_mcp

@Suite("OCR failure is reported, not swallowed")
struct OCRFailureReportingTests {

    /// An engine failure stands in for the `e5rtError` from issue #36.
    private struct EngineDown: Error, CustomStringConvertible {
        var description: String { "e5rtError(precompiled_compute_operation failed, 13)" }
    }

    private func makePNGData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!
        let mutableData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    private func describer(recognizer: StubTextRecognizer) -> ScreenDescriber {
        let capture = StubCapture()
        capture.captureResult = makePNGData(width: 820, height: 1796).base64EncodedString()
        return ScreenDescriber(bridge: StubBridge(), capture: capture, textRecognizer: recognizer)
    }

    // MARK: - The distinction

    @Test("A failing engine sets ocrFailure rather than returning an empty screen")
    func failureIsCarriedOnTheResult() {
        let recognizer = StubTextRecognizer()
        recognizer.failure = EngineDown()

        guard let result = describer(recognizer: recognizer).describe() else {
            Issue.record("describe() should still return a result when only OCR failed")
            return
        }
        #expect(result.elements.isEmpty)
        #expect(result.ocrFailure != nil, "the caller must be told the engine failed")
        #expect(result.ocrFailure?.contains("e5rt") == true, "the underlying error is preserved")
    }

    @Test("A genuinely blank screen reports no failure")
    func emptyScreenIsNotAFailure() {
        let recognizer = StubTextRecognizer()   // succeeds, finds nothing

        guard let result = describer(recognizer: recognizer).describe() else {
            Issue.record("describe() should return a result")
            return
        }
        #expect(result.elements.isEmpty)
        #expect(result.ocrFailure == nil, "zero elements from a working engine is not a failure")
    }

    /// The two cases were indistinguishable before: same empty list, same output.
    @Test("Failure and blank screen are distinguishable")
    func failureAndBlankAreDistinguishable() {
        let broken = StubTextRecognizer()
        broken.failure = EngineDown()
        let working = StubTextRecognizer()

        let brokenResult = describer(recognizer: broken).describe()
        let workingResult = describer(recognizer: working).describe()

        #expect(brokenResult?.elements.count == workingResult?.elements.count)
        #expect(brokenResult?.ocrFailure != workingResult?.ocrFailure,
            "identical element lists must still be tellable apart")
    }

    // MARK: - Composite

    @Test("A failing backend fails the composite instead of contributing nothing")
    func compositeSurfacesBackendFailure() {
        let good = StubTextRecognizer()
        good.elements = [RawTextElement(
            text: "visible", tapX: 10, textTopY: 10, textBottomY: 20,
            bboxWidth: 50, confidence: 0.9)]
        let bad = StubTextRecognizer()
        bad.failure = EngineDown()

        let composite = CompositeTextRecognizer(backends: [good, bad])
        #expect(throws: TextRecognitionError.self) {
            _ = try composite.recognizeText(
                in: makeImage(), windowSize: CGSize(width: 400, height: 800),
                contentBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        }
    }

    @Test("A working composite still merges its backends")
    func compositeMergesWhenAllSucceed() throws {
        let first = StubTextRecognizer()
        first.elements = [RawTextElement(
            text: "a", tapX: 1, textTopY: 1, textBottomY: 2, bboxWidth: 5, confidence: 0.9)]
        let second = StubTextRecognizer()
        second.elements = [RawTextElement(
            text: "b", tapX: 2, textTopY: 3, textBottomY: 4, bboxWidth: 5, confidence: 0.9)]

        let merged = try CompositeTextRecognizer(backends: [first, second]).recognizeText(
            in: makeImage(), windowSize: CGSize(width: 400, height: 800),
            contentBounds: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(merged.map(\.text) == ["a", "b"])
    }

    // MARK: - Self-test

    @Test("The self-test fails when the engine throws")
    func selfTestDetectsBrokenEngine() {
        let recognizer = StubTextRecognizer()
        recognizer.failure = EngineDown()

        guard case .failed(let reason) = TextRecognitionSelfTest.run(using: recognizer) else {
            Issue.record("a throwing engine must fail the self-test")
            return
        }
        #expect(reason.contains("e5rt"))
    }

    /// The case issue #36 describes: the engine runs and returns nothing at all.
    @Test("The self-test fails when the engine reads nothing from known text")
    func selfTestDetectsSilentlyEmptyEngine() {
        guard case .failed(let reason) = TextRecognitionSelfTest.run(
            using: StubTextRecognizer()
        ) else {
            Issue.record("an engine reading nothing from a known-text image must fail")
            return
        }
        #expect(reason.contains("read nothing"))
    }

    @Test("The self-test passes when the engine reads the probe back")
    func selfTestPassesOnCorrectRead() {
        let recognizer = StubTextRecognizer()
        recognizer.elements = [RawTextElement(
            text: TextRecognitionSelfTest.probeText, tapX: 10, textTopY: 10,
            textBottomY: 30, bboxWidth: 100, confidence: 0.99)]

        guard case .passed = TextRecognitionSelfTest.run(using: recognizer) else {
            Issue.record("reading the probe back must pass")
            return
        }
    }

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        // A 10x10 context always produces an image; the recognizers are stubs.
        return context!.makeImage()!
    }
}
