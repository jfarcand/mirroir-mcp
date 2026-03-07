// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Experiment C1: measures OCR coordinate stability across repeated describe() calls.
// ABOUTME: Validates that tap coordinates are consistent (stddev < 3pt) for reliable compiled replay.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Measures coordinate stability by calling describe() multiple times and checking
/// that tap coordinates for the same element have low standard deviation.
///
/// Tier 1 metric: tap accuracy > 95% (stddev < 3pt)
final class CoordinateStabilityTests: XCTestCase {

    private var bridge: MirroringBridge!
    private var describer: ScreenDescriber!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard IntegrationTestHelper.isFakeMirroringRunning else {
            throw XCTSkip("FakeMirroring not running")
        }
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw XCTSkip("FakeMirroring window not capturable")
        }
        let capture = ScreenCapture(bridge: bridge)
        describer = ScreenDescriber(bridge: bridge, capture: capture)
    }

    /// Call describe() 20 times and verify coordinate stddev < 3pt per element.
    func testCoordinateStabilityAcrossRepeatedDescribes() throws {
        let sampleCount = 20
        var coordinatesByLabel: [String: [(x: Double, y: Double)]] = [:]
        /// Labels that appear more than once on a single screen (e.g., ">" chevrons
        /// at 6 different Y positions). These are different elements, not jitter.
        var duplicateLabels: Set<String> = []

        for i in 0..<sampleCount {
            guard let result = describer.describe(skipOCR: false) else {
                XCTFail("describe() returned nil on iteration \(i)")
                return
            }
            // Track labels appearing multiple times in a single describe() call
            var seenThisCall: [String: Int] = [:]
            for element in result.elements {
                seenThisCall[element.text, default: 0] += 1
            }
            for (label, count) in seenThisCall where count > 1 {
                duplicateLabels.insert(label)
            }
            for element in result.elements {
                coordinatesByLabel[element.text, default: []].append(
                    (x: element.tapX, y: element.tapY))
            }
        }

        // Only check elements that appeared in most samples (stable elements)
        let stableThreshold = sampleCount / 2
        var maxStddev: Double = 0
        var unstableElements: [(label: String, stddevX: Double, stddevY: Double)] = []

        // Skip labels that appear multiple times per screen — these represent
        // distinct elements at different positions (e.g., 6 ">" chevrons), not jitter.
        for (label, coords) in coordinatesByLabel
            where coords.count >= stableThreshold && !duplicateLabels.contains(label) {
            let xs = coords.map { $0.x }
            let ys = coords.map { $0.y }
            let stddevX = standardDeviation(xs)
            let stddevY = standardDeviation(ys)
            let maxElementStddev = max(stddevX, stddevY)
            maxStddev = max(maxStddev, maxElementStddev)

            if maxElementStddev >= 3.0 {
                unstableElements.append((label: label, stddevX: stddevX, stddevY: stddevY))
            }
        }

        if !unstableElements.isEmpty {
            let detail = unstableElements.map {
                "\"\($0.label)\": stddevX=\(String(format: "%.2f", $0.stddevX)), stddevY=\(String(format: "%.2f", $0.stddevY))"
            }.joined(separator: "\n  ")
            XCTFail("Unstable coordinates (stddev >= 3pt):\n  \(detail)")
        }

        // Informational: log the max stddev
        print("Max coordinate stddev: \(String(format: "%.2f", maxStddev))pt across \(coordinatesByLabel.count) unique elements")
    }

    // MARK: - Helpers

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)
        return variance.squareRoot()
    }
}
