// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for SkillBundleGenerator: multi-skill and single-skill output.
// ABOUTME: Verifies correct delegation to SkillMdGenerator and path-based skill generation.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class SkillBundleGeneratorTests: XCTestCase {

    // MARK: - Helpers

    private func makeElements(_ texts: [String], startY: Double = 120) -> [TapPoint] {
        texts.enumerated().map { (i, text) in
            TapPoint(text: text, tapX: 205, tapY: startY + Double(i) * 80, confidence: 0.95)
        }
    }

    private func makeFlatScreens() -> [ExploredScreen] {
        [
            ExploredScreen(
                index: 0,
                elements: makeElements(["Settings", "General"]),
                hints: [], actionType: nil, arrivedVia: nil,
                screenshotBase64: "img0"
            ),
            ExploredScreen(
                index: 1,
                elements: makeElements(["About", "Version"]),
                hints: [], actionType: "tap", arrivedVia: "General",
                screenshotBase64: "img1"
            ),
        ]
    }

    // MARK: - Single Path Fallback

    func testSinglePathGraphProducesSingleSkill() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings", "General"]),
            icons: [], hints: [], screenshot: "img0", screenType: .settings
        )
        _ = graph.recordTransition(
            elements: makeElements(["About", "Version"]),
            icons: [], hints: [], screenshot: "img1",
            actionType: "tap", elementText: "General", screenType: .detail
        )
        let snapshot = graph.finalize()
        let screens = makeFlatScreens()

        let bundle = SkillBundleGenerator.generate(
            appName: "Settings", goal: "check version",
            snapshot: snapshot, allScreens: screens
        )

        XCTAssertEqual(bundle.appName, "Settings")
        XCTAssertEqual(bundle.skills.count, 1)
        XCTAssertTrue(bundle.skills[0].content.contains("Settings"))
    }

    // MARK: - Multi-Path Bundle

    func testBranchingGraphProducesMultipleSkills() {
        let graph = NavigationGraph()
        let rootElements = makeElements(["Settings", "General", "Privacy"])
        graph.start(
            rootElements: rootElements, icons: [], hints: [],
            screenshot: "root_img", screenType: .settings
        )

        // Branch A
        _ = graph.recordTransition(
            elements: makeElements(["About", "Name", "Version"]),
            icons: [], hints: [], screenshot: "a_img",
            actionType: "tap", elementText: "General", screenType: .list
        )

        // Back to root
        _ = graph.recordTransition(
            elements: rootElements, icons: [], hints: [],
            screenshot: "root2_img", actionType: "press_key",
            elementText: "[", screenType: .settings
        )

        // Branch B
        _ = graph.recordTransition(
            elements: makeElements(["Location Services", "Analytics"]),
            icons: [], hints: [], screenshot: "b_img",
            actionType: "tap", elementText: "Privacy", screenType: .list
        )

        let snapshot = graph.finalize()
        let screens = makeFlatScreens()

        let bundle = SkillBundleGenerator.generate(
            appName: "Settings", goal: "",
            snapshot: snapshot, allScreens: screens
        )

        XCTAssertEqual(bundle.skills.count, 2,
            "Branching graph should produce 2 skills")

        // Each skill should contain valid SKILL.md content
        for skill in bundle.skills {
            XCTAssertTrue(skill.content.contains("---"),
                "Each skill should have YAML front matter")
            XCTAssertTrue(skill.content.contains("## Steps"),
                "Each skill should have a Steps section")
        }
    }

    // MARK: - Empty Graph Fallback

    func testEmptyGraphFallsBackToFlatScreens() {
        let snapshot = GraphSnapshot(nodes: [:], edges: [], rootFingerprint: "", deadEdges: [], recoveryEvents: [])
        let screens = makeFlatScreens()

        let bundle = SkillBundleGenerator.generate(
            appName: "Settings", goal: "test",
            snapshot: snapshot, allScreens: screens
        )

        XCTAssertEqual(bundle.skills.count, 1)
        XCTAssertTrue(bundle.skills[0].content.contains("Settings"))
    }

    // MARK: - Skill Names

    func testSkillNamesAreTitleCased() {
        let graph = NavigationGraph()
        graph.start(
            rootElements: makeElements(["Settings"]),
            icons: [], hints: [], screenshot: "img", screenType: .settings
        )
        let snapshot = graph.finalize()
        let screens = makeFlatScreens()

        let bundle = SkillBundleGenerator.generate(
            appName: "Settings", goal: "check version",
            snapshot: snapshot, allScreens: screens
        )

        XCTAssertEqual(bundle.skills[0].name, "Check Version")
    }
}
