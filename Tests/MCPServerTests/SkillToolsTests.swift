// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for skill helper functions: YAML discovery, header parsing, env var substitution.
// ABOUTME: Uses temporary directories to simulate project-local and global skill layouts.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SkillToolsTests: XCTestCase {

    var tmpDir: String!

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "skill-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    // MARK: - findYAMLFiles

    func testFindYAMLFilesEmpty() {
        let results = MirroirMCP.findYAMLFiles(in: tmpDir)
        XCTAssertTrue(results.isEmpty)
    }

    func testFindYAMLFilesFlat() {
        createFile("a.yaml", content: "name: A")
        createFile("b.yaml", content: "name: B")
        createFile("c.txt", content: "not yaml")

        let results = MirroirMCP.findYAMLFiles(in: tmpDir)
        XCTAssertEqual(results, ["a.yaml", "b.yaml"])
    }

    func testFindYAMLFilesNested() {
        createFile("apps/slack/send.yaml", content: "name: Send")
        createFile("apps/calendar/event.yaml", content: "name: Event")
        createFile("testing/login.yaml", content: "name: Login")

        let results = MirroirMCP.findYAMLFiles(in: tmpDir)
        XCTAssertEqual(results, [
            "apps/calendar/event.yaml",
            "apps/slack/send.yaml",
            "testing/login.yaml",
        ])
    }

    func testFindYAMLFilesNonexistentDir() {
        let results = MirroirMCP.findYAMLFiles(in: "/nonexistent-path-xyz")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - extractYAMLValue

    func testExtractSimpleValue() {
        let result = MirroirMCP.extractYAMLValue(from: "name: My Skill", key: "name")
        XCTAssertEqual(result, "My Skill")
    }

    func testExtractDoubleQuotedValue() {
        let result = MirroirMCP.extractYAMLValue(from: "name: \"Quoted Name\"", key: "name")
        XCTAssertEqual(result, "Quoted Name")
    }

    func testExtractSingleQuotedValue() {
        let result = MirroirMCP.extractYAMLValue(from: "name: 'Single Quoted'", key: "name")
        XCTAssertEqual(result, "Single Quoted")
    }

    func testExtractEmptyValue() {
        let result = MirroirMCP.extractYAMLValue(from: "name:", key: "name")
        XCTAssertEqual(result, "")
    }

    func testExtractValueWithExtraSpaces() {
        let result = MirroirMCP.extractYAMLValue(from: "name:   spaced  out  ", key: "name")
        XCTAssertEqual(result, "spaced  out")
    }

    // MARK: - extractSkillHeader (inline YAML)

    func testHeaderSimpleInline() {
        let yaml = """
        name: Send Message
        app: Slack
        description: Send a DM to someone
        steps:
          - launch: "Slack"
        """
        let info = MirroirMCP.extractSkillHeader(
            from: yaml, fallbackName: "fallback", source: "test")
        XCTAssertEqual(info.name, "Send Message")
        XCTAssertEqual(info.description, "Send a DM to someone")
        XCTAssertEqual(info.source, "test")
    }

    func testHeaderMissingName() {
        let yaml = """
        app: Weather
        description: Check the forecast
        steps:
          - launch: "Weather"
        """
        let info = MirroirMCP.extractSkillHeader(
            from: yaml, fallbackName: "my-skill", source: "global")
        XCTAssertEqual(info.name, "my-skill")
        XCTAssertEqual(info.description, "Check the forecast")
    }

    func testHeaderMissingDescription() {
        let yaml = """
        name: Quick Test
        app: Settings
        steps:
          - launch: "Settings"
        """
        let info = MirroirMCP.extractSkillHeader(
            from: yaml, fallbackName: "fallback", source: "local")
        XCTAssertEqual(info.name, "Quick Test")
        XCTAssertEqual(info.description, "")
    }

    func testHeaderBlockScalarFolded() {
        let yaml = """
        name: Multi Line
        app: Notes
        description: >
          This is a long description
          that spans multiple lines
          in folded style.
        steps:
          - launch: "Notes"
        """
        let info = MirroirMCP.extractSkillHeader(
            from: yaml, fallbackName: "fallback", source: "test")
        XCTAssertEqual(info.name, "Multi Line")
        XCTAssertEqual(info.description,
            "This is a long description that spans multiple lines in folded style.")
    }

    func testHeaderBlockScalarLiteral() {
        let yaml = """
        name: Literal Block
        description: |
          Line one
          Line two
        steps:
          - launch: "App"
        """
        let info = MirroirMCP.extractSkillHeader(
            from: yaml, fallbackName: "fallback", source: "test")
        XCTAssertEqual(info.name, "Literal Block")
        XCTAssertEqual(info.description, "Line one Line two")
    }

    func testHeaderBlockScalarStrip() {
        let yaml = """
        name: Strip Block
        description: >-
          Stripped trailing newline
        steps:
          - launch: "App"
        """
        let info = MirroirMCP.extractSkillHeader(
            from: yaml, fallbackName: "fallback", source: "test")
        XCTAssertEqual(info.name, "Strip Block")
        XCTAssertEqual(info.description, "Stripped trailing newline")
    }

    func testHeaderEmptyContent() {
        let info = MirroirMCP.extractSkillHeader(
            from: "", fallbackName: "empty", source: "test")
        XCTAssertEqual(info.name, "empty")
        XCTAssertEqual(info.description, "")
    }

    func testHeaderBlockScalarStopsAtNextKey() {
        let yaml = """
        name: Block Stop
        description: >
          Description content here
        app: Calendar
        steps:
          - launch: "Calendar"
        """
        let info = MirroirMCP.extractSkillHeader(
            from: yaml, fallbackName: "fallback", source: "test")
        XCTAssertEqual(info.description, "Description content here")
    }

    // MARK: - extractSkillHeader (from file)

    func testHeaderFromFile() {
        let path = createFile("test.yaml", content: """
        name: File Test
        description: Read from disk
        steps:
          - launch: "App"
        """)
        let info = MirroirMCP.extractSkillHeader(
            from: path, source: "local")
        XCTAssertEqual(info.name, "File Test")
        XCTAssertEqual(info.description, "Read from disk")
    }

    func testHeaderFromMissingFile() {
        let info = MirroirMCP.extractSkillHeader(
            from: tmpDir + "/nonexistent.yaml", source: "local")
        XCTAssertEqual(info.name, "nonexistent")
        XCTAssertEqual(info.description, "")
    }

    // MARK: - substituteEnvVars

    func testSubstituteWithEnvVar() {
        setenv("SKILL_TEST_VAR", "hello", 1)
        defer { unsetenv("SKILL_TEST_VAR") }

        let result = MirroirMCP.substituteEnvVars(in: "say ${SKILL_TEST_VAR}")
        XCTAssertEqual(result, "say hello")
    }

    func testSubstituteWithDefault() {
        unsetenv("SKILL_UNSET_VAR")

        let result = MirroirMCP.substituteEnvVars(in: "city: ${SKILL_UNSET_VAR:-Montreal}")
        XCTAssertEqual(result, "city: Montreal")
    }

    func testSubstituteUnsetNoDefault() {
        unsetenv("SKILL_MISSING_VAR")

        let result = MirroirMCP.substituteEnvVars(in: "value: ${SKILL_MISSING_VAR}")
        XCTAssertEqual(result, "value: ${SKILL_MISSING_VAR}")
    }

    func testSubstituteEnvOverridesDefault() {
        setenv("SKILL_SET_VAR", "actual", 1)
        defer { unsetenv("SKILL_SET_VAR") }

        let result = MirroirMCP.substituteEnvVars(in: "${SKILL_SET_VAR:-fallback}")
        XCTAssertEqual(result, "actual")
    }

    func testSubstituteMultipleVars() {
        setenv("SKILL_A", "alpha", 1)
        setenv("SKILL_B", "beta", 1)
        defer { unsetenv("SKILL_A"); unsetenv("SKILL_B") }

        let result = MirroirMCP.substituteEnvVars(in: "${SKILL_A} and ${SKILL_B}")
        XCTAssertEqual(result, "alpha and beta")
    }

    func testSubstituteNoPlaceholders() {
        let input = "plain text with no variables"
        let result = MirroirMCP.substituteEnvVars(in: input)
        XCTAssertEqual(result, input)
    }

    func testSubstituteSingleBracesUntouched() {
        let input = "AI var: {commute_time}"
        let result = MirroirMCP.substituteEnvVars(in: input)
        XCTAssertEqual(result, input)
    }

    func testSubstituteEmptyDefault() {
        unsetenv("SKILL_EMPTY_DEFAULT")

        let result = MirroirMCP.substituteEnvVars(in: "val=${SKILL_EMPTY_DEFAULT:-}")
        XCTAssertEqual(result, "val=")
    }

    // MARK: - resolveSkill

    func testResolveExactPath() {
        createFile("apps/slack/send-message.yaml", content: "name: Send")
        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "apps/slack/send-message", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("apps/slack/send-message.yaml"))
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveBasenameUnique() {
        createFile("apps/slack/send-message.yaml", content: "name: Send")
        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "send-message", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("send-message.yaml"))
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveBasenameAmbiguous() {
        createFile("apps/slack/send-message.yaml", content: "name: Slack Send")
        createFile("apps/teams/send-message.yaml", content: "name: Teams Send")
        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "send-message", dirs: [tmpDir])
        XCTAssertNil(path)
        XCTAssertEqual(ambiguous.count, 2)
    }

    func testResolveNotFound() {
        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "nonexistent", dirs: [tmpDir])
        XCTAssertNil(path)
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveLocalOverridesGlobal() {
        let localDir = tmpDir + "/local"
        let globalDir = tmpDir + "/global"
        try? FileManager.default.createDirectory(
            atPath: localDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            atPath: globalDir, withIntermediateDirectories: true)
        createFile("local/test.yaml", content: "name: Local", baseDir: tmpDir)
        createFile("global/test.yaml", content: "name: Global", baseDir: tmpDir)

        let (path, _) = MirroirMCP.resolveSkill(
            name: "test", dirs: [localDir, globalDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.contains("/local/"))
    }

    func testResolveSameRelPathInBothDirsIsNotAmbiguous() {
        let localDir = tmpDir + "/local"
        let globalDir = tmpDir + "/global"
        try? FileManager.default.createDirectory(
            atPath: localDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            atPath: globalDir, withIntermediateDirectories: true)
        // Same relative path in both dirs (e.g., marketplace cloned to both)
        createFile("local/apps/settings/list-apps.yaml",
            content: "name: Local List", baseDir: tmpDir)
        createFile("global/apps/settings/list-apps.yaml",
            content: "name: Global List", baseDir: tmpDir)

        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "list-apps", dirs: [localDir, globalDir])
        XCTAssertNotNil(path, "Same rel path in both dirs should resolve, not be ambiguous")
        XCTAssertTrue(ambiguous.isEmpty)
        XCTAssertTrue(path!.contains("/local/"))
    }

    func testResolveWithYamlExtension() {
        createFile("test.yaml", content: "name: Test")
        let (path, _) = MirroirMCP.resolveSkill(
            name: "test.yaml", dirs: [tmpDir])
        XCTAssertNotNil(path)
    }

    // MARK: - skillStem

    func testSkillStemYaml() {
        XCTAssertEqual(MirroirMCP.skillStem("apps/slack/send.yaml"), "apps/slack/send")
    }

    func testSkillStemMd() {
        XCTAssertEqual(MirroirMCP.skillStem("apps/slack/send.md"), "apps/slack/send")
    }

    func testSkillStemNoExtension() {
        XCTAssertEqual(MirroirMCP.skillStem("apps/slack/send"), "apps/slack/send")
    }

    // MARK: - Helpers

    @discardableResult
    func createFile(
        _ relativePath: String,
        content: String,
        baseDir: String? = nil
    ) -> String {
        let base = baseDir ?? tmpDir!
        let fullPath = base + "/" + relativePath
        let dir = (fullPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try? content.write(toFile: fullPath, atomically: true, encoding: .utf8)
        return fullPath
    }
}
