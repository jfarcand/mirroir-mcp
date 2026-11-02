// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that APP.md `## Landmarks` and `## Skip` steer generated waits: a declared landmark wins,
// ABOUTME: a Skip text never qualifies; a SKILL.md taps the label it acted on, then waits for the screen it reached.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class AppMdLandmarkPolicyTests: XCTestCase {

    private static let appMd = """
        ---
        version: 1
        app: Brawl Stars
        ---

        ## Structure

        Arena brawler; the shop sells seasonal offers.

        ## Landmarks
        - RESSOURCES

        ## Skip
        - MEILLEURE OFFRE
        - PASS BRAWL
        """

    /// The Brawl Stars main menu as OCR read it on the XR (landscape).
    private static let menu = [
        TapPoint(text: "INFOS", tapX: 829, tapY: 127, confidence: 1),
        TapPoint(text: "MAGASIN", tapX: 80, tapY: 186, confidence: 1),
        TapPoint(text: "BRAWLERS", tapX: 80, tapY: 235, confidence: 1),
        TapPoint(text: "JOUER", tapX: 768, tapY: 411, confidence: 1),
    ]

    /// The shop as OCR read it on the XR: the paid offer is the longest new
    /// text and changes with the season; RESSOURCES is a permanent category.
    private static let shop = [
        TapPoint(text: "MAGASIN", tapX: 176, tapY: 57, confidence: 1),
        TapPoint(text: "PASS BRAWL", tapX: 349, tapY: 131, confidence: 1),
        TapPoint(text: "RESSOURCES", tapX: 98, tapY: 290, confidence: 1),
        TapPoint(text: "MEILLEURE OFFRE DE BRAWL", tapX: 344, tapY: 377, confidence: 1),
    ]

    private static let walk = [
        ExploredScreen(index: 0, elements: menu, hints: [], actionType: nil,
                       arrivedVia: nil, screenshotBase64: ""),
        ExploredScreen(index: 1, elements: shop, hints: [], actionType: "tap",
                       arrivedVia: "MAGASIN", screenshotBase64: ""),
    ]

    private func description() throws -> AppDescription {
        try XCTUnwrap(AppDescriptionParser.parse(content: Self.appMd))
    }

    func testTheLandmarksSectionIsParsedAndJoinsTheStableAnchors() throws {
        let desc = try description()
        XCTAssertEqual(desc.landmarks, ["RESSOURCES"])
        XCTAssertEqual(desc.stableAnchors, desc.tabs + ["RESSOURCES"])
    }

    func testWithoutAnAppMdTheLongestNewTextIsTheWait() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "shop", appName: "Brawl Stars", screens: Self.walk)
        XCTAssertTrue(yaml.contains("  - wait_for: \"MEILLEURE OFFRE DE BRAWL\"\n"), yaml)
    }

    func testADeclaredLandmarkIsTheWaitOverALongerText() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "shop", appName: "Brawl Stars", screens: Self.walk,
            landmarks: .init(anchors: ["RESSOURCES"]))
        XCTAssertTrue(yaml.contains("  - tap: \"MAGASIN\"\n  - wait_for: \"RESSOURCES\"\n"), yaml)
        XCTAssertFalse(yaml.contains("MEILLEURE"), yaml)
    }

    func testASkipTextIsNeverTheWait() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "shop", appName: "Brawl Stars", screens: Self.walk,
            landmarks: .init(exclusions: ["MEILLEURE OFFRE", "PASS BRAWL"]))
        XCTAssertTrue(yaml.contains("  - wait_for: \"RESSOURCES\"\n"), yaml)
        XCTAssertFalse(yaml.contains("MEILLEURE") || yaml.contains("PASS BRAWL"), yaml)
    }

    func testTheEmitterTakesItsPolicyFromTheAppMd() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("landmark-policy-\(UUID().uuidString)/.mirroir", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let result = try MirroirAppTreeEmitter.emit(
            appName: "Brawl Stars",
            flows: [MirroirAppTreeEmitter.Flow(name: "open the shop", screens: Self.walk)],
            root: root,
            landmarks: ScenarioStepFormatter.LandmarkPolicy(description: try description()))
        let yaml = try String(contentsOf: try XCTUnwrap(result.scenarioPaths.first), encoding: .utf8)
        XCTAssertTrue(yaml.contains("  - wait_for: \"RESSOURCES\"\n"), yaml)
    }

    func testTheSkillMdTapNamesTheLabelOnTheScreenItActedOn() {
        let brawlers = [
            TapPoint(text: "BRAWLERS À DÉBLOQUER", tapX: 685, tapY: 91, confidence: 1),
            TapPoint(text: "SHELLY", tapX: 510, tapY: 181, confidence: 1),
        ]
        let skill = SkillMdGenerator.generate(
            appName: "Brawl Stars", goal: "open the brawlers", screens: [
                ExploredScreen(index: 0, elements: Self.menu, hints: [], actionType: nil,
                               arrivedVia: nil, screenshotBase64: ""),
                ExploredScreen(index: 1, elements: brawlers, hints: [], actionType: "tap",
                               arrivedVia: "BRAWLERS", screenshotBase64: ""),
            ])
        XCTAssertTrue(skill.contains("Tap \"BRAWLERS\"\n"), skill)
        XCTAssertFalse(skill.contains("Tap \"BRAWLERS À DÉBLOQUER\""), skill)
    }

    func testTheSkillMdWaitsForTheShopAfterTheTapThatReachesIt() throws {
        let skill = SkillMdGenerator.generate(
            appName: "Brawl Stars", goal: "open the shop", screens: Self.walk,
            appDescription: try description())
        let tap = try XCTUnwrap(skill.range(of: "Tap \"MAGASIN\""))
        let wait = try XCTUnwrap(skill.range(of: "Wait for \"RESSOURCES\" to appear"))
        XCTAssertLessThan(tap.lowerBound, wait.lowerBound, skill)
    }
}
