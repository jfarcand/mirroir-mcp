// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ScreenFingerprint: screen comparison via OCR element fingerprints.
// ABOUTME: Verifies status bar filtering, time/number exclusion, sorting, and equality checks.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ScreenFingerprintTests: XCTestCase {

    // MARK: - Extract Filtering

    func testExtractFiltersStatusBar() {
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "Carrier", tapX: 50, tapY: 30, confidence: 0.90),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]

        let fingerprint = ScreenFingerprint.extract(from: elements)

        XCTAssertTrue(fingerprint.contains("Settings"))
        XCTAssertTrue(fingerprint.contains("General"))
        XCTAssertFalse(fingerprint.contains("Carrier"),
            "Status bar elements (tapY < 80) should be excluded")
    }

    func testExtractFiltersTimePatterns() {
        let elements = [
            TapPoint(text: "12:25", tapX: 100, tapY: 120, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 200, confidence: 0.98),
        ]

        let fingerprint = ScreenFingerprint.extract(from: elements)

        XCTAssertFalse(fingerprint.contains("12:25"),
            "Time patterns should be excluded")
        XCTAssertTrue(fingerprint.contains("Settings"))
    }

    func testExtractFiltersBareNumbers() {
        let elements = [
            TapPoint(text: "100", tapX: 100, tapY: 120, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 200, confidence: 0.98),
        ]

        let fingerprint = ScreenFingerprint.extract(from: elements)

        XCTAssertFalse(fingerprint.contains("100"),
            "Bare numbers should be excluded")
        XCTAssertTrue(fingerprint.contains("Settings"))
    }

    func testExtractSortsAlphabetically() {
        let elements = [
            TapPoint(text: "Privacy", tapX: 205, tapY: 400, confidence: 0.93),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 300, confidence: 0.92),
        ]

        let fingerprint = ScreenFingerprint.extract(from: elements)

        XCTAssertEqual(fingerprint, ["About", "General", "Privacy"],
            "Fingerprint should be sorted alphabetically")
    }

    // MARK: - Equality Checks

    func testAreEqualIdenticalScreens() {
        let lhs = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        // Same text, different order and coordinates
        let rhs = [
            TapPoint(text: "General", tapX: 200, tapY: 345, confidence: 0.90),
            TapPoint(text: "Settings", tapX: 210, tapY: 125, confidence: 0.92),
        ]

        XCTAssertTrue(ScreenFingerprint.areEqual(lhs, rhs),
            "Screens with same text in different order should be equal")
    }

    func testAreEqualDifferentScreens() {
        let lhs = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let rhs = [
            TapPoint(text: "General", tapX: 205, tapY: 120, confidence: 0.97),
            TapPoint(text: "About", tapX: 205, tapY: 400, confidence: 0.92),
        ]

        XCTAssertFalse(ScreenFingerprint.areEqual(lhs, rhs),
            "Screens with different text should not be equal")
    }

    func testAreEqualIgnoresStatusBarDifferences() {
        let lhs = [
            TapPoint(text: "9:41", tapX: 50, tapY: 30, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let rhs = [
            TapPoint(text: "9:42", tapX: 50, tapY: 30, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]

        XCTAssertTrue(ScreenFingerprint.areEqual(lhs, rhs),
            "Status bar time changes should not affect equality")
    }
}
