// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that an emitted landmark is one item of an OCR line, never a line OCR merged from several.
// ABOUTME: Covers separators, segments, the Horloge walk, fingerprints, MIRROIR_SKILLS, and the missing-rules refusal.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class EmittedLandmarkSegmentTests: XCTestCase {

    private static let rules = ComponentLoader.TextCleanupRules(
        stripPrefixes: ["•", "·"], segmentSeparators: ["|", "•", "·"], excludeLabels: ["icon"])

    // MARK: - Rules

    /// The `## Segment Separators` section is read alongside the prefixes and
    /// exclusions, one character per bullet.
    func testTheSegmentSeparatorsSectionIsParsed() {
        let rules = ComponentLoader.parseTextCleanup(content: """
            ## Strip Prefixes

            - •

            ## Segment Separators

            - |
            - ·

            ## Exclude Labels

            - icon
            """)
        XCTAssertEqual(rules.stripPrefixes, ["•"])
        XCTAssertEqual(rules.segmentSeparators, ["|", "·"])
        XCTAssertEqual(rules.excludeLabels, ["icon"])
    }

    /// The skills checkout the emitter reads declares the separators: without
    /// them every merged OCR line would be a landmark candidate again.
    func testTheSkillsTextCleanupDeclaresSegmentSeparators() {
        let rules = ComponentLoader.loadTextCleanupRules()
        XCTAssertTrue(rules.segmentSeparators.contains("|"),
                      "text-cleanup.md declares no '|' separator: \(rules.segmentSeparators)")
    }

    // MARK: - Segments

    /// A merged line splits into its cleaned items, in reading order.
    func testAMergedLineSplitsIntoItsItems() {
        XCTAssertEqual(ActionStepFormatter.segments(of: "• Sommeil | Réveil", rules: Self.rules),
                       ["Sommeil", "Réveil"])
    }

    /// A line with no separator is its one cleaned segment.
    func testALineWithoutSeparatorIsOneSegment() {
        XCTAssertEqual(ActionStepFormatter.segments(of: "• Aucune alarme", rules: Self.rules),
                       ["Aucune alarme"])
    }

    /// Separators alone, or doubled, leave no empty segment behind.
    func testSeparatorRunsLeaveNoEmptySegment() {
        XCTAssertEqual(ActionStepFormatter.segments(of: "| Sommeil || · ", rules: Self.rules),
                       ["Sommeil"])
        XCTAssertEqual(ActionStepFormatter.segments(of: "•", rules: Self.rules), [])
    }

    // MARK: - Emitted landmark

    private static let tabBar = [
        TapPoint(text: "Horloges", tapX: 60, tapY: 857, confidence: 1),
        TapPoint(text: "Alarmes", tapX: 163, tapY: 857, confidence: 1),
        TapPoint(text: "Chronomètre", tapX: 267, tapY: 857, confidence: 1),
        TapPoint(text: "Minuteurs", tapX: 370, tapY: 857, confidence: 1),
    ]

    /// The Minuteurs tab as OCR read it on the XR.
    private static let minuteurs = [
        TapPoint(text: "Minuteurs", tapX: 108, tapY: 155, confidence: 1),
        TapPoint(text: "Annuler", tapX: 66, tapY: 479, confidence: 1),
        TapPoint(text: "Démarrer", tapX: 364, tapY: 479, confidence: 1),
        TapPoint(text: "Description", tapX: 87, tapY: 583, confidence: 1),
    ] + tabBar

    /// The YAML for a Minuteurs → tap "Alarmes" walk arriving on `alarmes`.
    private func alarmesWalk(_ alarmes: [TapPoint]) throws -> String {
        try ScenarioStepFormatter.scenarioYAML(name: "onglets", appName: "Horloge", screens: [
            ExploredScreen(index: 0, elements: Self.minuteurs, hints: [], actionType: nil,
                           arrivedVia: nil, screenshotBase64: ""),
            ExploredScreen(index: 1, elements: alarmes + Self.tabBar, hints: [], actionType: "tap",
                           arrivedVia: "Alarmes", screenshotBase64: ""),
        ])
    }

    /// The Alarmes tab as OCR read it on the XR. Its title shares its text
    /// with the tab bar on the screen before, so the candidates are the new
    /// items; the merged "• Sommeil | Réveil" line counts as two shorter ones,
    /// and the longest single item, "Aucune alarme", is the wait.
    func testTheHorlogeAlarmesWaitIsASingleItemNotTheMergedLine() throws {
        let yaml = try alarmesWalk([
            TapPoint(text: "+", tapX: 390, tapY: 108, confidence: 1),
            TapPoint(text: "Alarmes", tapX: 93, tapY: 155, confidence: 1),
            TapPoint(text: "• Sommeil | Réveil", tapX: 117, tapY: 211, confidence: 1),
            TapPoint(text: "CONFIGURER", tapX: 343, tapY: 260, confidence: 1),
            TapPoint(text: "Aucune alarme", tapX: 84, tapY: 261, confidence: 1),
        ])
        XCTAssertTrue(yaml.contains("  - wait_for: \"Aucune alarme\"\n"), yaml)
        XCTAssertFalse(yaml.contains("Sommeil |"), "a merged OCR line was emitted: \(yaml)")
    }

    /// When the merged line holds the longest new text, the wait names its
    /// longest item, which a read splitting the line still shows.
    func testAMergedLineContributesItsLongestItem() throws {
        let yaml = try alarmesWalk([
            TapPoint(text: "Alarmes", tapX: 93, tapY: 155, confidence: 1),
            TapPoint(text: "• Sommeil | Réveil", tapX: 117, tapY: 211, confidence: 1),
        ])
        XCTAssertTrue(yaml.contains("  - wait_for: \"Sommeil\"\n"), yaml)
    }

    // MARK: - Screen fingerprint

    /// Two XR reads of the Alarmes tab: the bullet came back as "•" then "*".
    /// The fingerprint records the items, so both reads are the same screen;
    /// a read that splits the line is too.
    func testTheFingerprintIgnoresHowOCRReadTheBulletAndTheMerge() {
        func fingerprint(_ line: [String]) -> ScreenFingerprint {
            let texts = ["Alarmes", "CONFIGURER", "Aucune alarme"] + line
            return StructuralFingerprint.buildScreenFingerprint(
                elements: texts.enumerated().map {
                    TapPoint(text: $0.element, tapX: 120, tapY: 155 + Double($0.offset) * 50, confidence: 1)
                },
                icons: [])
        }
        let bullet = fingerprint(["• Sommeil | Réveil"])
        let star = fingerprint(["* Sommeil | Réveil"])
        let split = fingerprint(["Sommeil", "Réveil"])
        XCTAssertEqual(bullet.structuralTexts,
                       ["Alarmes", "Aucune alarme", "CONFIGURER", "Réveil", "Sommeil"])
        XCTAssertEqual(star, bullet)
        XCTAssertEqual(split, bullet)
    }

    // MARK: - Skills checkout

    /// `mirroir-run` starts `mirroir-mcp test` in a scratch workspace and names
    /// the checkout in `MIRROIR_SKILLS`: every pattern loader reads it first,
    /// so the replay cleans OCR text with the same rules the emit used.
    func testTheMirroirSkillsCheckoutIsReadFirstByEveryLoader() throws {
        let checkout = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-checkout-\(UUID().uuidString)")
        let elements = checkout.appendingPathComponent("patterns/elements")
        try FileManager.default.createDirectory(at: elements, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        try "## Segment Separators\n\n- ¦\n".write(
            to: elements.appendingPathComponent(ComponentLoader.textCleanupFileName),
            atomically: true, encoding: .utf8)
        let variable = PermissionPolicy.skillsCheckoutVariable
        let previous = ProcessInfo.processInfo.environment[variable]
        setenv(variable, checkout.path, 1)
        defer {
            if let previous { setenv(variable, previous, 1) } else { unsetenv(variable) }
        }

        XCTAssertEqual(PermissionPolicy.skillsCheckouts.first, checkout.path)
        XCTAssertEqual(ComponentLoader.loadTextCleanupRules().segmentSeparators, ["¦"])
        XCTAssertEqual(RecipeLoader.searchPaths().first(where: { $0.contains("patterns/screens") }),
                       checkout.path + "/patterns/screens")
        XCTAssertEqual(AppDescriptionLoader.searchPaths().first, checkout.path + "/patterns/apps")
        XCTAssertEqual(DriftDefaultsSeeder.candidatePaths().first,
                       checkout.path + "/" + DriftDefaultsSeeder.fileName)
    }

    // MARK: - Missing rules

    /// With no text-cleanup.md at any candidate, the emit is refused naming
    /// every path searched, and nothing is written.
    func testEmitIsRefusedWithoutTextCleanupRules() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("consumer/.mirroir")
        let searched = [
            scratch.appendingPathComponent("skills/one/\(ComponentLoader.textCleanupFileName)").path,
            scratch.appendingPathComponent("skills/two/\(ComponentLoader.textCleanupFileName)").path,
        ]
        let flow = MirroirAppTreeEmitter.Flow(name: "Add Alarm", screens: [
            ExploredScreen(index: 0,
                           elements: [TapPoint(text: "Add Alarm", tapX: 200, tapY: 140, confidence: 1)],
                           hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: ""),
            ExploredScreen(index: 1,
                           elements: [TapPoint(text: "Cancel", tapX: 200, tapY: 100, confidence: 1)],
                           hints: [], actionType: "tap", arrivedVia: "Add Alarm", screenshotBase64: ""),
        ])

        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: [flow], root: root, textCleanupCandidates: searched)
        ) { error in
            XCTAssertEqual(error as? MirroirAppTreeEmitter.EmitError,
                           .textCleanupMissing(searched: searched))
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            for path in searched {
                XCTAssertTrue(message.contains(path), "the refusal omits \(path): \(message)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "a refused emit must leave the tree untouched")
    }
}
