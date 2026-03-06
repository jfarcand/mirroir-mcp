// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for StructuralFingerprint: structural element extraction, similarity, and filtering.
// ABOUTME: Verifies that dynamic content is excluded and stable elements produce consistent fingerprints.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class StructuralFingerprintTests: XCTestCase {

    // MARK: - Structural Extraction

    func testExtractFiltersStatusBar() {
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "Carrier", tapX: 50, tapY: 30, confidence: 0.90),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]

        let structural = StructuralFingerprint.extractStructural(from: elements)

        XCTAssertTrue(structural.contains("Settings"))
        XCTAssertTrue(structural.contains("General"))
        XCTAssertFalse(structural.contains("Carrier"),
            "Status bar elements should be excluded")
    }

    func testExtractFiltersTimePatterns() {
        let elements = [
            TapPoint(text: "12:25", tapX: 100, tapY: 120, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 200, confidence: 0.98),
        ]

        let structural = StructuralFingerprint.extractStructural(from: elements)

        XCTAssertFalse(structural.contains("12:25"))
        XCTAssertTrue(structural.contains("Settings"))
    }

    func testExtractFiltersBareNumbers() {
        let elements = [
            TapPoint(text: "100", tapX: 100, tapY: 120, confidence: 0.95),
            TapPoint(text: "42", tapX: 200, tapY: 150, confidence: 0.90),
            TapPoint(text: "Settings", tapX: 205, tapY: 200, confidence: 0.98),
        ]

        let structural = StructuralFingerprint.extractStructural(from: elements)

        XCTAssertFalse(structural.contains("100"))
        XCTAssertFalse(structural.contains("42"))
        XCTAssertTrue(structural.contains("Settings"))
    }

    func testExtractFiltersLongText() {
        let longText = String(repeating: "x", count: 51)
        let elements = [
            TapPoint(text: longText, tapX: 205, tapY: 200, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]

        let structural = StructuralFingerprint.extractStructural(from: elements)

        XCTAssertFalse(structural.contains(longText),
            "Text longer than 50 chars should be excluded")
        XCTAssertTrue(structural.contains("General"))
    }

    func testExtractFiltersDatePatterns() {
        let elements = [
            TapPoint(text: "Monday", tapX: 100, tapY: 120, confidence: 0.95),
            TapPoint(text: "Feb 23", tapX: 200, tapY: 150, confidence: 0.90),
            TapPoint(text: "Settings", tapX: 205, tapY: 200, confidence: 0.98),
        ]

        let structural = StructuralFingerprint.extractStructural(from: elements)

        XCTAssertFalse(structural.contains("Monday"),
            "Day names should be filtered as date patterns")
        XCTAssertFalse(structural.contains("Feb 23"),
            "Month+day patterns should be filtered")
        XCTAssertTrue(structural.contains("Settings"))
    }

    // MARK: - Fingerprint Stability

    func testComputeProducesConsistentHash() {
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let icons: [IconDetector.DetectedIcon] = []

        let fp1 = StructuralFingerprint.compute(elements: elements, icons: icons)
        let fp2 = StructuralFingerprint.compute(elements: elements, icons: icons)

        XCTAssertEqual(fp1, fp2, "Same inputs should produce same fingerprint")
        XCTAssertEqual(fp1.count, 64, "SHA256 hex string should be 64 characters")
    }

    func testComputeIgnoresDynamicContent() {
        let base = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]

        let withTime = base + [
            TapPoint(text: "9:41", tapX: 50, tapY: 30, confidence: 0.95),
        ]
        let withDifferentTime = base + [
            TapPoint(text: "9:42", tapX: 50, tapY: 30, confidence: 0.95),
        ]

        let fp1 = StructuralFingerprint.compute(elements: withTime, icons: [])
        let fp2 = StructuralFingerprint.compute(elements: withDifferentTime, icons: [])

        XCTAssertEqual(fp1, fp2,
            "Different status bar times should produce same fingerprint")
    }

    func testComputeDiffersForDifferentScreens() {
        let screenA = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let screenB = [
            TapPoint(text: "Photos", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "Albums", tapX: 205, tapY: 340, confidence: 0.95),
        ]

        let fp1 = StructuralFingerprint.compute(elements: screenA, icons: [])
        let fp2 = StructuralFingerprint.compute(elements: screenB, icons: [])

        XCTAssertNotEqual(fp1, fp2,
            "Different screens should produce different fingerprints")
    }

    func testComputeIncludesIconCount() {
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
        ]
        let noIcons: [IconDetector.DetectedIcon] = []
        let twoIcons = [
            IconDetector.DetectedIcon(tapX: 56, tapY: 850, estimatedSize: 24),
            IconDetector.DetectedIcon(tapX: 158, tapY: 850, estimatedSize: 24),
        ]

        let fp1 = StructuralFingerprint.compute(elements: elements, icons: noIcons)
        let fp2 = StructuralFingerprint.compute(elements: elements, icons: twoIcons)

        XCTAssertNotEqual(fp1, fp2,
            "Different icon counts should produce different fingerprints")
    }

    // MARK: - Similarity

    func testSimilarityIdenticalSets() {
        let set1: Set<String> = ["Settings", "General", "Privacy"]
        let set2: Set<String> = ["Settings", "General", "Privacy"]

        XCTAssertEqual(
            StructuralFingerprint.similarity(set1, set2), 1.0, accuracy: 0.001)
    }

    func testSimilarityDisjointSets() {
        let set1: Set<String> = ["Settings", "General"]
        let set2: Set<String> = ["Photos", "Albums"]

        XCTAssertEqual(
            StructuralFingerprint.similarity(set1, set2), 0.0, accuracy: 0.001)
    }

    func testSimilarityPartialOverlap() {
        // Jaccard = 2 / 4 = 0.5
        let set1: Set<String> = ["Settings", "General", "Privacy"]
        let set2: Set<String> = ["Settings", "General", "About"]

        XCTAssertEqual(
            StructuralFingerprint.similarity(set1, set2), 0.5, accuracy: 0.001)
    }

    func testSimilarityBothEmpty() {
        let set1: Set<String> = []
        let set2: Set<String> = []

        XCTAssertEqual(
            StructuralFingerprint.similarity(set1, set2), 1.0, accuracy: 0.001)
    }

    // MARK: - AreEquivalent

    func testAreEquivalentSameScreen() {
        let lhs = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let rhs = [
            TapPoint(text: "General", tapX: 200, tapY: 345, confidence: 0.90),
            TapPoint(text: "Settings", tapX: 210, tapY: 125, confidence: 0.92),
        ]

        XCTAssertTrue(StructuralFingerprint.areEquivalent(lhs, rhs))
    }

    func testAreEquivalentDifferentScreens() {
        let lhs = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let rhs = [
            TapPoint(text: "Photos", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "Albums", tapX: 205, tapY: 340, confidence: 0.95),
        ]

        XCTAssertFalse(StructuralFingerprint.areEquivalent(lhs, rhs))
    }

    // MARK: - Date Pattern Detection

    func testIsDatePatternDayNames() {
        XCTAssertTrue(StructuralFingerprint.isDatePattern("Monday"))
        XCTAssertTrue(StructuralFingerprint.isDatePattern("tuesday"))
        XCTAssertTrue(StructuralFingerprint.isDatePattern("Wed"))
        XCTAssertTrue(StructuralFingerprint.isDatePattern("thu"))
    }

    func testIsDatePatternMonthDay() {
        XCTAssertTrue(StructuralFingerprint.isDatePattern("Feb 23"))
        XCTAssertTrue(StructuralFingerprint.isDatePattern("Mar 5"))
        XCTAssertTrue(StructuralFingerprint.isDatePattern("January 1"))
    }

    func testIsDatePatternNonDates() {
        XCTAssertFalse(StructuralFingerprint.isDatePattern("Settings"))
        XCTAssertFalse(StructuralFingerprint.isDatePattern("General"))
        XCTAssertFalse(StructuralFingerprint.isDatePattern("February Blues"))
    }

    // MARK: - Nav Bar Title Extraction

    func testExtractNavBarTitle() {
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "Wi", tapX: 50, tapY: 120, confidence: 0.90),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]

        let title = StructuralFingerprint.extractNavBarTitle(from: elements)
        XCTAssertEqual(title, "Settings",
            "Should pick the longest text in the header zone")
    }

    func testExtractNavBarTitleFiltersTimePatterns() {
        let elements = [
            TapPoint(text: "12:25", tapX: 100, tapY: 150, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 180, confidence: 0.98),
        ]

        let title = StructuralFingerprint.extractNavBarTitle(from: elements)
        XCTAssertEqual(title, "Settings",
            "Time patterns should be excluded from title candidates")
    }

    func testExtractNavBarTitleReturnsNilForEmptyHeaderZone() {
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 340, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 420, confidence: 0.95),
        ]

        let title = StructuralFingerprint.extractNavBarTitle(from: elements)
        XCTAssertNil(title,
            "Should return nil when no qualifying elements in header zone")
    }

    func testExtractNavBarTitleFiltersShortText() {
        let elements = [
            TapPoint(text: "Ab", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "Settings", tapX: 205, tapY: 180, confidence: 0.95),
        ]

        let title = StructuralFingerprint.extractNavBarTitle(from: elements)
        XCTAssertEqual(title, "Settings",
            "Text shorter than 3 chars should be excluded")
    }

    // MARK: - Title-Aware Similarity

    func testTitleAwareSimilarityDifferentTitles() {
        // Both screens share many elements but have different nav bar titles
        let settings = [
            TapPoint(text: "Settings", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "Privacy", tapX: 205, tapY: 420, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 500, confidence: 0.95),
        ]
        let general = [
            TapPoint(text: "General", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "Privacy", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 420, confidence: 0.95),
            TapPoint(text: "Storage", tapX: 205, tapY: 500, confidence: 0.95),
        ]

        let sim = StructuralFingerprint.titleAwareSimilarity(settings, general)
        XCTAssertEqual(sim, 0.0,
            "Different nav bar titles should short-circuit to 0.0")
    }

    func testTitleAwareSimilaritySameTitles() {
        // Same title, same elements — should get 1.0
        let lhs = [
            TapPoint(text: "Settings", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let rhs = [
            TapPoint(text: "Settings", tapX: 210, tapY: 155, confidence: 0.92),
            TapPoint(text: "General", tapX: 200, tapY: 345, confidence: 0.90),
        ]

        let sim = StructuralFingerprint.titleAwareSimilarity(lhs, rhs)
        XCTAssertEqual(sim, 1.0, accuracy: 0.001,
            "Same titles should fall through to Jaccard similarity")
    }

    func testTitleAwareSimilarityOneTitleMissing() {
        // One screen has a title, the other does not — fall through to Jaccard
        let withTitle = [
            TapPoint(text: "Settings", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let noTitle = [
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "Settings", tapX: 205, tapY: 500, confidence: 0.95),
        ]

        let sim = StructuralFingerprint.titleAwareSimilarity(withTitle, noTitle)
        XCTAssertGreaterThan(sim, 0.0,
            "When one title is missing, should fall through to Jaccard")
    }

    func testAreEquivalentTitleAwareRejectsDifferentTitles() {
        let settings = [
            TapPoint(text: "Settings", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "Privacy", tapX: 205, tapY: 420, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 500, confidence: 0.95),
        ]
        let general = [
            TapPoint(text: "General", tapX: 205, tapY: 150, confidence: 0.98),
            TapPoint(text: "Privacy", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "About", tapX: 205, tapY: 420, confidence: 0.95),
            TapPoint(text: "Storage", tapX: 205, tapY: 500, confidence: 0.95),
        ]

        XCTAssertFalse(
            StructuralFingerprint.areEquivalentTitleAware(settings, general),
            "Settings vs General should never be confused")
    }

    // MARK: - Screen Fingerprint

    func testBuildScreenFingerprint() {
        let elements = [
            TapPoint(text: "Settings", tapX: 205, tapY: 120, confidence: 0.98),
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
        ]
        let icons = [
            IconDetector.DetectedIcon(tapX: 56, tapY: 850, estimatedSize: 24),
        ]

        let fp = StructuralFingerprint.buildScreenFingerprint(
            elements: elements, icons: icons)

        XCTAssertEqual(fp.hash.count, 64, "SHA256 hex = 64 chars")
        XCTAssertTrue(fp.structuralTexts.contains("Settings"))
        XCTAssertTrue(fp.structuralTexts.contains("General"))
        XCTAssertEqual(fp.structuralTexts, fp.structuralTexts.sorted(),
            "structuralTexts should be sorted")
        XCTAssertEqual(fp.iconCount, 1)
    }

    func testScreenFingerprintSimilarityExactMatch() {
        let fp = ScreenFingerprint(
            hash: "abc", structuralTexts: ["A", "B", "C"], iconCount: 2)

        XCTAssertEqual(
            StructuralFingerprint.screenFingerprintSimilarity(fp, fp),
            1.0, accuracy: 0.001,
            "Identical hashes should fast-path to 1.0")
    }

    func testScreenFingerprintSimilarityPartialOverlap() {
        let fp1 = ScreenFingerprint(
            hash: "hash1",
            structuralTexts: ["Settings", "General", "Privacy"],
            iconCount: 2)
        let fp2 = ScreenFingerprint(
            hash: "hash2",
            structuralTexts: ["Settings", "General", "About"],
            iconCount: 3)

        // Jaccard: 2 / 4 = 0.5
        let sim = StructuralFingerprint.screenFingerprintSimilarity(fp1, fp2)
        XCTAssertEqual(sim, 0.5, accuracy: 0.001)
    }

    func testScreenFingerprintSimilarityNoOverlap() {
        let fp1 = ScreenFingerprint(
            hash: "hash1",
            structuralTexts: ["Settings", "General"],
            iconCount: 0)
        let fp2 = ScreenFingerprint(
            hash: "hash2",
            structuralTexts: ["Photos", "Albums"],
            iconCount: 5)

        let sim = StructuralFingerprint.screenFingerprintSimilarity(fp1, fp2)
        XCTAssertEqual(sim, 0.0, accuracy: 0.001)
    }
}
