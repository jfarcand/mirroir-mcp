// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for LandmarkPicker: OCR element filtering and landmark selection.
// ABOUTME: Covers status bar filtering, time patterns, bare numbers, confidence, and header zone preference.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class LandmarkPickerTests: XCTestCase {

    // MARK: - pickLandmark

    func testPickLandmark() {
        let elements = [
            TapPoint(text: "Privacy & Security", tapX: 205, tapY: 400, confidence: 0.93),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Settings",
            "Should pick element in header zone")
    }

    func testPickLandmarkEmpty() {
        let landmark = LandmarkPicker.pickLandmark(from: [])
        XCTAssertNil(landmark, "Empty elements should return nil")
    }

    func testPickLandmarkFiltersShortText() {
        let elements = [
            TapPoint(text: "OK", tapX: 205, tapY: 120, confidence: 0.99),
            TapPoint(text: "Cancel Button", tapX: 205, tapY: 150, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Cancel Button",
            "Should skip elements shorter than 3 chars")
    }

    func testPickLandmarkFiltersLowConfidence() {
        let elements = [
            TapPoint(text: "Fuzzy Match", tapX: 205, tapY: 120, confidence: 0.3),
            TapPoint(text: "Clear Text", tapX: 205, tapY: 150, confidence: 0.85),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Clear Text",
            "Should skip elements with confidence below threshold")
    }

    func testPickLandmarkFiltersLongText() {
        let longText = String(repeating: "A", count: 50)
        let elements = [
            TapPoint(text: longText, tapX: 205, tapY: 120, confidence: 0.95),
            TapPoint(text: "Reasonable Label", tapX: 205, tapY: 150, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Reasonable Label",
            "Should skip elements longer than 40 chars")
    }

    func testPickLandmarkFiltersStatusBar() {
        let elements = [
            TapPoint(text: "12:25", tapX: 100, tapY: 20, confidence: 0.99),
            TapPoint(text: "Settings", tapX: 205, tapY: 30, confidence: 0.98),
            TapPoint(text: "100", tapX: 350, tapY: 20, confidence: 0.97),
            TapPoint(text: "General", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "General",
            "Should skip status bar elements (tapY < 80)")
    }

    func testPickLandmarkFiltersTimePatterns() {
        let elements = [
            TapPoint(text: "12:251", tapX: 100, tapY: 120, confidence: 0.99),
            TapPoint(text: "9:41", tapX: 100, tapY: 130, confidence: 0.99),
            TapPoint(text: "Notes", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Notes",
            "Should skip time-like patterns even outside status bar zone")
    }

    func testPickLandmarkFiltersBareNumbers() {
        let elements = [
            TapPoint(text: "100", tapX: 350, tapY: 120, confidence: 0.97),
            TapPoint(text: "55", tapX: 350, tapY: 130, confidence: 0.97),
            TapPoint(text: "App Title", tapX: 205, tapY: 200, confidence: 0.95),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "App Title",
            "Should skip bare numbers (battery %, signal)")
    }

    func testPickLandmarkPrefersHeaderZone() {
        let elements = [
            TapPoint(text: "Header Title", tapX: 205, tapY: 150, confidence: 0.90),
            TapPoint(text: "Bottom Item", tapX: 205, tapY: 500, confidence: 0.98),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Header Title",
            "Should prefer elements in 100-250pt header zone")
    }

    func testPickLandmarkFallsBackOutsideHeaderZone() {
        let elements = [
            TapPoint(text: "Deep Content", tapX: 205, tapY: 400, confidence: 0.90),
        ]

        let landmark = LandmarkPicker.pickLandmark(from: elements)
        XCTAssertEqual(landmark, "Deep Content",
            "Should fall back to topmost element when none in header zone")
    }

    // MARK: - isTimePattern / isBareNumber

    func testIsTimePattern() {
        XCTAssertTrue(LandmarkPicker.isTimePattern("12:25"))
        XCTAssertTrue(LandmarkPicker.isTimePattern("9:41"))
        XCTAssertTrue(LandmarkPicker.isTimePattern("12:251"))
        XCTAssertFalse(LandmarkPicker.isTimePattern("Settings"))
        XCTAssertFalse(LandmarkPicker.isTimePattern("12:25 PM"))
    }

    func testIsBareNumber() {
        XCTAssertTrue(LandmarkPicker.isBareNumber("100"))
        XCTAssertTrue(LandmarkPicker.isBareNumber("55"))
        XCTAssertTrue(LandmarkPicker.isBareNumber("5"))
        XCTAssertFalse(LandmarkPicker.isBareNumber("1234"))
        XCTAssertFalse(LandmarkPicker.isBareNumber("General"))
    }
}
