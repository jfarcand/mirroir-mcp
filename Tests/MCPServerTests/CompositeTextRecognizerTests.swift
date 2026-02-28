// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for CompositeTextRecognizer, verifying multi-backend result merging.
// ABOUTME: Uses StubTextRecognizer from TestDoubles for deterministic backend simulation.

import CoreGraphics
import Foundation
import HelperLib
import Testing
@testable import mirroir_mcp

@Suite("CompositeTextRecognizer")
struct CompositeTextRecognizerTests {

    /// Create a minimal 1x1 CGImage for testing.
    private func makeMinimalImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private let windowSize = CGSize(width: 410, height: 898)
    private let contentBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    @Test("Merges results from multiple backends")
    func testMergesResults() {
        let stub1 = StubTextRecognizer()
        stub1.elements = [
            RawTextElement(text: "Settings", tapX: 100, textTopY: 50,
                          textBottomY: 70, bboxWidth: 80, confidence: 0.99),
        ]

        let stub2 = StubTextRecognizer()
        stub2.elements = [
            RawTextElement(text: "Button", tapX: 200, textTopY: 150,
                          textBottomY: 180, bboxWidth: 60, confidence: 0.85),
            RawTextElement(text: "Toggle", tapX: 300, textTopY: 250,
                          textBottomY: 280, bboxWidth: 40, confidence: 0.72),
        ]

        let composite = CompositeTextRecognizer(backends: [stub1, stub2])
        let image = makeMinimalImage()

        let results = composite.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        #expect(results.count == 3)
        #expect(results[0].text == "Settings")
        #expect(results[1].text == "Button")
        #expect(results[2].text == "Toggle")
    }

    @Test("Single backend passes through directly")
    func testSingleBackendPassesThrough() {
        let stub = StubTextRecognizer()
        stub.elements = [
            RawTextElement(text: "Label", tapX: 50, textTopY: 10,
                          textBottomY: 30, bboxWidth: 40, confidence: 0.9),
        ]

        let composite = CompositeTextRecognizer(backends: [stub])
        let image = makeMinimalImage()

        let results = composite.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        #expect(results.count == 1)
        #expect(results[0].text == "Label")
    }

    @Test("Empty backends returns empty results")
    func testEmptyBackendsReturnsEmpty() {
        let composite = CompositeTextRecognizer(backends: [])
        let image = makeMinimalImage()

        let results = composite.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        #expect(results.isEmpty)
    }

    @Test("Backends returning empty arrays contribute nothing")
    func testEmptyBackendResultsIgnored() {
        let emptyStub = StubTextRecognizer()
        emptyStub.elements = []

        let populatedStub = StubTextRecognizer()
        populatedStub.elements = [
            RawTextElement(text: "Active", tapX: 100, textTopY: 50,
                          textBottomY: 70, bboxWidth: 80, confidence: 0.95),
        ]

        let composite = CompositeTextRecognizer(backends: [emptyStub, populatedStub])
        let image = makeMinimalImage()

        let results = composite.recognizeText(
            in: image, windowSize: windowSize, contentBounds: contentBounds
        )

        #expect(results.count == 1)
        #expect(results[0].text == "Active")
    }
}
