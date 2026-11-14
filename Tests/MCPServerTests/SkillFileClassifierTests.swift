// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for SkillFileClassifier and the skill list discoverSkills builds from it.
// ABOUTME: READMEs, APP.md files, patterns and scenarios are left out; a YAML twin of a SKILL.md is listed once.

import XCTest
@testable import mirroir_mcp

final class SkillFileClassifierTests: XCTestCase {

    private var skillsDir = ""

    override func setUpWithError() throws {
        skillsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-classifier-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: skillsDir)
    }

    private func write(_ relPath: String, _ content: String) throws {
        let path = skillsDir + "/" + relPath
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static let skillMd = """
        ---
        version: 1
        name: Set Alarm
        app: Clock
        ---

        Create a new alarm in the Clock app

        ## Steps

        1. Launch **Clock**
        """

    private static let skillYaml = """
        name: Set Alarm
        app: Clock
        description: Create a new alarm

        steps:
          - launch: "Clock"
        """

    // MARK: - Classifier

    func testSkillMdIsASkill() {
        XCTAssertEqual(
            SkillFileClassifier.identity(content: Self.skillMd, isMarkdown: true),
            SkillFileClassifier.Identity(name: "Set Alarm", app: "Clock"))
    }

    func testYamlSkillIsASkill() {
        XCTAssertEqual(
            SkillFileClassifier.identity(content: Self.skillYaml, isMarkdown: false),
            SkillFileClassifier.Identity(name: "Set Alarm", app: "Clock"))
    }

    func testReadmeWithoutFrontMatterIsNotASkill() {
        let readme = "# mirroir-skills\n\nCommunity skills.\n\n---\n\nname: x\napp: y\n---\n"
        XCTAssertNil(SkillFileClassifier.identity(content: readme, isMarkdown: true))
    }

    func testAppMdIsNotASkill() {
        let appMd = "---\nversion: 1\napp: Weather\nspotlight_name: Weather\n---\n\n# Weather\n"
        XCTAssertNil(SkillFileClassifier.identity(content: appMd, isMarkdown: true))
    }

    func testElementPatternIsNotASkill() {
        let pattern = "---\nversion: 1\nname: toggle-row\nplatform: ios\n---\n\n# Toggle Row\n"
        XCTAssertNil(SkillFileClassifier.identity(content: pattern, isMarkdown: true))
    }

    func testScenarioYamlWithoutAppIsNotASkill() {
        let scenario = "version: 1\nname: chat-stream\nsteps:\n  - tap: \"#send\"\n"
        XCTAssertNil(SkillFileClassifier.identity(content: scenario, isMarkdown: false))
    }

    func testAppNamedOnlyInsideAStepDoesNotMakeAYamlSkill() {
        let scenario = "name: chat-stream\nsteps:\n  - target:\n      app: Safari\n  - tap: \"Go\"\n"
        XCTAssertNil(SkillFileClassifier.identity(content: scenario, isMarkdown: false))
    }

    func testYamlWithoutStepsIsNotASkill() {
        XCTAssertNil(SkillFileClassifier.identity(
            content: "name: Thresholds\napp: Clock\n", isMarkdown: false))
    }

    // MARK: - discoverSkills

    func testDiscoveryListsOnlySkills() throws {
        try write("README.md", "# Skills\n\nHow to contribute.\n")
        try write("patterns/apps/weather/APP.md",
                  "---\nversion: 1\napp: Weather\nspotlight_name: Weather\n---\n\n# Weather\n")
        try write("patterns/elements/toggle-row.md",
                  "---\nversion: 1\nname: toggle-row\nplatform: ios\n---\n\n# Toggle Row\n")
        try write("skills/apps/clock/set-alarm.md", Self.skillMd)

        let names = MirroirMCP.discoverSkills(in: [skillsDir]).map(\.name)
        XCTAssertEqual(names, ["Set Alarm"])
    }

    func testYamlTwinOfASkillMdIsListedOnce() throws {
        // legacy/ sorts before skills/, so the YAML copy is seen first.
        try write("legacy/apps/clock/set-alarm.yaml", Self.skillYaml)
        try write("skills/apps/clock/set-alarm.md", Self.skillMd)

        let skills = MirroirMCP.discoverSkills(in: [skillsDir])
        XCTAssertEqual(skills.map(\.name), ["Set Alarm"])
        XCTAssertEqual(skills.first?.description, "Create a new alarm in the Clock app",
                       "the SKILL.md copy is the one listed")
    }

    func testYamlSkillWithNoMarkdownTwinIsListed() throws {
        try write("apps/clock/set-alarm.yaml", Self.skillYaml)

        XCTAssertEqual(MirroirMCP.discoverSkills(in: [skillsDir]).map(\.name), ["Set Alarm"])
    }
}
