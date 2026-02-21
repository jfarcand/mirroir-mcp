// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for scenario helper functions: YAML discovery, header parsing, env var substitution.
// ABOUTME: Uses temporary directories to simulate project-local and global scenario layouts.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class ScenarioToolsTests: XCTestCase {

    private var tmpDir: String!

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "scenario-tests-\(UUID().uuidString)"
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
        let result = MirroirMCP.extractYAMLValue(from: "name: My Scenario", key: "name")
        XCTAssertEqual(result, "My Scenario")
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

    // MARK: - extractScenarioHeader (inline YAML)

    func testHeaderSimpleInline() {
        let yaml = """
        name: Send Message
        app: Slack
        description: Send a DM to someone
        steps:
          - launch: "Slack"
        """
        let info = MirroirMCP.extractScenarioHeader(
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
        let info = MirroirMCP.extractScenarioHeader(
            from: yaml, fallbackName: "my-scenario", source: "global")
        XCTAssertEqual(info.name, "my-scenario")
        XCTAssertEqual(info.description, "Check the forecast")
    }

    func testHeaderMissingDescription() {
        let yaml = """
        name: Quick Test
        app: Settings
        steps:
          - launch: "Settings"
        """
        let info = MirroirMCP.extractScenarioHeader(
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
        let info = MirroirMCP.extractScenarioHeader(
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
        let info = MirroirMCP.extractScenarioHeader(
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
        let info = MirroirMCP.extractScenarioHeader(
            from: yaml, fallbackName: "fallback", source: "test")
        XCTAssertEqual(info.name, "Strip Block")
        XCTAssertEqual(info.description, "Stripped trailing newline")
    }

    func testHeaderEmptyContent() {
        let info = MirroirMCP.extractScenarioHeader(
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
        let info = MirroirMCP.extractScenarioHeader(
            from: yaml, fallbackName: "fallback", source: "test")
        XCTAssertEqual(info.description, "Description content here")
    }

    // MARK: - extractScenarioHeader (from file)

    func testHeaderFromFile() {
        let path = createFile("test.yaml", content: """
        name: File Test
        description: Read from disk
        steps:
          - launch: "App"
        """)
        let info = MirroirMCP.extractScenarioHeader(
            from: path, source: "local")
        XCTAssertEqual(info.name, "File Test")
        XCTAssertEqual(info.description, "Read from disk")
    }

    func testHeaderFromMissingFile() {
        let info = MirroirMCP.extractScenarioHeader(
            from: tmpDir + "/nonexistent.yaml", source: "local")
        XCTAssertEqual(info.name, "nonexistent")
        XCTAssertEqual(info.description, "")
    }

    // MARK: - substituteEnvVars

    func testSubstituteWithEnvVar() {
        setenv("SCENARIO_TEST_VAR", "hello", 1)
        defer { unsetenv("SCENARIO_TEST_VAR") }

        let result = MirroirMCP.substituteEnvVars(in: "say ${SCENARIO_TEST_VAR}")
        XCTAssertEqual(result, "say hello")
    }

    func testSubstituteWithDefault() {
        unsetenv("SCENARIO_UNSET_VAR")

        let result = MirroirMCP.substituteEnvVars(in: "city: ${SCENARIO_UNSET_VAR:-Montreal}")
        XCTAssertEqual(result, "city: Montreal")
    }

    func testSubstituteUnsetNoDefault() {
        unsetenv("SCENARIO_MISSING_VAR")

        let result = MirroirMCP.substituteEnvVars(in: "value: ${SCENARIO_MISSING_VAR}")
        XCTAssertEqual(result, "value: ${SCENARIO_MISSING_VAR}")
    }

    func testSubstituteEnvOverridesDefault() {
        setenv("SCENARIO_SET_VAR", "actual", 1)
        defer { unsetenv("SCENARIO_SET_VAR") }

        let result = MirroirMCP.substituteEnvVars(in: "${SCENARIO_SET_VAR:-fallback}")
        XCTAssertEqual(result, "actual")
    }

    func testSubstituteMultipleVars() {
        setenv("SCENARIO_A", "alpha", 1)
        setenv("SCENARIO_B", "beta", 1)
        defer { unsetenv("SCENARIO_A"); unsetenv("SCENARIO_B") }

        let result = MirroirMCP.substituteEnvVars(in: "${SCENARIO_A} and ${SCENARIO_B}")
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
        unsetenv("SCENARIO_EMPTY_DEFAULT")

        let result = MirroirMCP.substituteEnvVars(in: "val=${SCENARIO_EMPTY_DEFAULT:-}")
        XCTAssertEqual(result, "val=")
    }

    // MARK: - resolveScenario

    func testResolveExactPath() {
        createFile("apps/slack/send-message.yaml", content: "name: Send")
        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "apps/slack/send-message", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("apps/slack/send-message.yaml"))
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveBasenameUnique() {
        createFile("apps/slack/send-message.yaml", content: "name: Send")
        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "send-message", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("send-message.yaml"))
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveBasenameAmbiguous() {
        createFile("apps/slack/send-message.yaml", content: "name: Slack Send")
        createFile("apps/teams/send-message.yaml", content: "name: Teams Send")
        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "send-message", dirs: [tmpDir])
        XCTAssertNil(path)
        XCTAssertEqual(ambiguous.count, 2)
    }

    func testResolveNotFound() {
        let (path, ambiguous) = MirroirMCP.resolveScenario(
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

        let (path, _) = MirroirMCP.resolveScenario(
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

        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "list-apps", dirs: [localDir, globalDir])
        XCTAssertNotNil(path, "Same rel path in both dirs should resolve, not be ambiguous")
        XCTAssertTrue(ambiguous.isEmpty)
        XCTAssertTrue(path!.contains("/local/"))
    }

    func testResolveWithYamlExtension() {
        createFile("test.yaml", content: "name: Test")
        let (path, _) = MirroirMCP.resolveScenario(
            name: "test.yaml", dirs: [tmpDir])
        XCTAssertNotNil(path)
    }

    // MARK: - findScenarioFiles (.md + .yaml)

    func testFindScenarioFilesIncludesMd() {
        createFile("a.yaml", content: "name: A")
        createFile("b.md", content: "---\nname: B\n---\n\nBody")
        createFile("c.txt", content: "not a scenario")

        let results = MirroirMCP.findScenarioFiles(in: tmpDir)
        XCTAssertTrue(results.contains("a.yaml"))
        XCTAssertTrue(results.contains("b.md"))
        XCTAssertFalse(results.contains("c.txt"))
    }

    func testFindScenarioFilesMdBeforeYamlForSameStem() {
        createFile("test.yaml", content: "name: YAML")
        createFile("test.md", content: "---\nname: MD\n---\n\nBody")

        let results = MirroirMCP.findScenarioFiles(in: tmpDir)
        // .md should come before .yaml for the same stem
        let mdIndex = results.firstIndex(of: "test.md")
        let yamlIndex = results.firstIndex(of: "test.yaml")
        XCTAssertNotNil(mdIndex)
        XCTAssertNotNil(yamlIndex)
        XCTAssertTrue(mdIndex! < yamlIndex!)
    }

    // MARK: - discoverScenarios with .md

    func testDiscoverMdFiles() {
        // Create a scenario dir structure that mimics what discoverScenarios expects
        let scenarioDir = tmpDir + "/scenarios"
        createFile("scenarios/test.md",
                    content: "---\nname: MD Scenario\n---\n\nDescription here.",
                    baseDir: tmpDir)

        // Directly test findScenarioFiles and extractScenarioHeader on the dir
        let files = MirroirMCP.findScenarioFiles(in: scenarioDir)
        XCTAssertEqual(files, ["test.md"])

        let filePath = scenarioDir + "/" + files[0]
        let info = MirroirMCP.extractScenarioHeader(from: filePath, source: "local")
        XCTAssertEqual(info.name, "MD Scenario")
        XCTAssertEqual(info.description, "Description here.")
    }

    func testMdOverridesYamlInDiscovery() {
        // When both .md and .yaml exist with the same stem, .md wins
        let scenarioDir = tmpDir + "/scenarios"
        createFile("scenarios/test.yaml", content: "name: YAML Version\ndescription: from yaml",
                    baseDir: tmpDir)
        createFile("scenarios/test.md",
                    content: "---\nname: MD Version\n---\n\nFrom markdown.",
                    baseDir: tmpDir)

        let files = MirroirMCP.findScenarioFiles(in: scenarioDir)
        // Both files should be found
        XCTAssertTrue(files.contains("test.md"))
        XCTAssertTrue(files.contains("test.yaml"))

        // Simulate discoverScenarios dedup: first seen stem wins
        var seenStems = Set<String>()
        var results: [MirroirMCP.ScenarioInfo] = []
        for relPath in files {
            let stem = MirroirMCP.scenarioStem(relPath)
            if seenStems.contains(stem) { continue }
            seenStems.insert(stem)
            let filePath = scenarioDir + "/" + relPath
            let info = MirroirMCP.extractScenarioHeader(from: filePath, source: "local")
            results.append(info)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "MD Version")
    }

    // MARK: - resolveScenario with .md

    func testResolveMdFile() {
        createFile("test.md", content: "---\nname: MD Test\n---\n\nBody")
        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "test", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.md"))
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveMdPreferredOverYaml() {
        createFile("test.yaml", content: "name: YAML")
        createFile("test.md", content: "---\nname: MD\n---\n\nBody")

        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "test", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.md"), "Expected .md to be preferred over .yaml")
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveMdWithExplicitExtension() {
        createFile("test.md", content: "---\nname: MD\n---\n\nBody")
        let (path, _) = MirroirMCP.resolveScenario(
            name: "test.md", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.md"))
    }

    func testResolveYamlStillWorksWhenNoMd() {
        createFile("test.yaml", content: "name: YAML Only")
        let (path, _) = MirroirMCP.resolveScenario(
            name: "test", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.yaml"))
    }

    func testResolveMdInSubdirectory() {
        createFile("apps/slack/send.md",
                    content: "---\nname: Send\n---\n\nBody")
        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "apps/slack/send", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("send.md"))
        XCTAssertTrue(ambiguous.isEmpty)
    }

    // MARK: - resolveScenario with yamlOnly

    func testResolveYamlOnlySkipsMd() {
        // When both .md and .yaml exist, yamlOnly: true returns the .yaml
        createFile("test.yaml", content: "name: YAML Version")
        createFile("test.md", content: "---\nname: MD Version\n---\n\nBody")

        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "test", dirs: [tmpDir], yamlOnly: true)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.yaml"),
            "yamlOnly should resolve to .yaml, got: \(path!)")
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveYamlOnlyPhase2() {
        // Basename resolution with yamlOnly: true finds YAML in subdirectory
        createFile("apps/slack/send.yaml", content: "name: Slack Send")
        createFile("apps/slack/send.md", content: "---\nname: Slack Send MD\n---\n\nBody")

        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "send", dirs: [tmpDir], yamlOnly: true)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("send.yaml"),
            "yamlOnly Phase 2 should resolve to .yaml, got: \(path!)")
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveYamlOnlyMdOnlyFileNotFound() {
        // When only .md exists, yamlOnly: true should not find it
        createFile("test.md", content: "---\nname: MD Only\n---\n\nBody")

        let (path, ambiguous) = MirroirMCP.resolveScenario(
            name: "test", dirs: [tmpDir], yamlOnly: true)
        XCTAssertNil(path, "yamlOnly should not resolve .md-only scenarios")
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveYamlOnlyDefaultFalse() {
        // Default behavior (yamlOnly not specified) still prefers .md
        createFile("test.yaml", content: "name: YAML")
        createFile("test.md", content: "---\nname: MD\n---\n\nBody")

        let (path, _) = MirroirMCP.resolveScenario(
            name: "test", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.md"),
            "Default behavior should prefer .md")
    }

    // MARK: - scenarioStem

    func testScenarioStemYaml() {
        XCTAssertEqual(MirroirMCP.scenarioStem("apps/slack/send.yaml"), "apps/slack/send")
    }

    func testScenarioStemMd() {
        XCTAssertEqual(MirroirMCP.scenarioStem("apps/slack/send.md"), "apps/slack/send")
    }

    func testScenarioStemNoExtension() {
        XCTAssertEqual(MirroirMCP.scenarioStem("apps/slack/send"), "apps/slack/send")
    }

    // MARK: - Helpers

    @discardableResult
    private func createFile(
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
