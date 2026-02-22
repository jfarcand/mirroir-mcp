// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for TestRunner: CLI argument parsing, skill resolution, and help flag.
// ABOUTME: Tests pure logic functions without requiring system access.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class TestRunnerConfigTests: XCTestCase {

    // MARK: - Argument Parsing

    func testParseEmptyArgs() {
        let config = TestRunner.parseArguments([])
        XCTAssertTrue(config.skillArgs.isEmpty)
        XCTAssertNil(config.junitPath)
        XCTAssertEqual(config.screenshotDir, "./mirroir-test-results")
        XCTAssertEqual(config.timeoutSeconds, 15)
        XCTAssertFalse(config.verbose)
        XCTAssertFalse(config.dryRun)
        XCTAssertNil(config.agent)
        XCTAssertFalse(config.showHelp)
    }

    func testParseHelpFlag() {
        let config = TestRunner.parseArguments(["--help"])
        XCTAssertTrue(config.showHelp)
    }

    func testParseHelpShortFlag() {
        let config = TestRunner.parseArguments(["-h"])
        XCTAssertTrue(config.showHelp)
    }

    func testParseVerboseFlag() {
        let config = TestRunner.parseArguments(["--verbose"])
        XCTAssertTrue(config.verbose)
    }

    func testParseVerboseShortFlag() {
        let config = TestRunner.parseArguments(["-v"])
        XCTAssertTrue(config.verbose)
    }

    func testParseDryRunFlag() {
        let config = TestRunner.parseArguments(["--dry-run"])
        XCTAssertTrue(config.dryRun)
    }

    func testParseJUnitPath() {
        let config = TestRunner.parseArguments(["--junit", "results.xml"])
        XCTAssertEqual(config.junitPath, "results.xml")
    }

    func testParseScreenshotDir() {
        let config = TestRunner.parseArguments(["--screenshot-dir", "/tmp/shots"])
        XCTAssertEqual(config.screenshotDir, "/tmp/shots")
    }

    func testParseTimeout() {
        let config = TestRunner.parseArguments(["--timeout", "30"])
        XCTAssertEqual(config.timeoutSeconds, 30)
    }

    func testParseSkillArgs() {
        let config = TestRunner.parseArguments(["check-about", "send-message"])
        XCTAssertEqual(config.skillArgs, ["check-about", "send-message"])
    }

    func testParseMixedArgs() {
        let config = TestRunner.parseArguments([
            "--verbose", "--junit", "out.xml",
            "--timeout", "20", "skill1", "skill2"
        ])
        XCTAssertTrue(config.verbose)
        XCTAssertEqual(config.junitPath, "out.xml")
        XCTAssertEqual(config.timeoutSeconds, 20)
        XCTAssertEqual(config.skillArgs, ["skill1", "skill2"])
    }

    func testParseIgnoresUnknownFlags() {
        let config = TestRunner.parseArguments(["--unknown", "skill1"])
        // --unknown starts with - so it's treated as a flag, not a skill
        XCTAssertEqual(config.skillArgs, ["skill1"])
    }

    // MARK: - Agent Flag Parsing

    func testParseBareAgentFlag() {
        // --agent with no model name → deterministic only (empty string)
        let config = TestRunner.parseArguments(["--agent"])
        XCTAssertEqual(config.agent, "")
    }

    func testParseAgentWithModelName() {
        // --agent claude-sonnet-4-6 → AI model name
        let config = TestRunner.parseArguments(["--agent", "claude-sonnet-4-6", "skill.yaml"])
        XCTAssertEqual(config.agent, "claude-sonnet-4-6")
        XCTAssertEqual(config.skillArgs, ["skill.yaml"])
    }

    func testParseAgentFollowedByYAML() {
        // --agent skill.yaml → bare agent, skill.yaml is a skill arg
        let config = TestRunner.parseArguments(["--agent", "skill.yaml"])
        XCTAssertEqual(config.agent, "")
        XCTAssertEqual(config.skillArgs, ["skill.yaml"])
    }

    func testParseAgentFollowedByYMLFile() {
        // --agent test.yml → bare agent, test.yml is a skill arg
        let config = TestRunner.parseArguments(["--agent", "test.yml"])
        XCTAssertEqual(config.agent, "")
        XCTAssertEqual(config.skillArgs, ["test.yml"])
    }

    func testParseAgentFollowedByFlag() {
        // --agent --verbose → bare agent, verbose flag still parsed
        let config = TestRunner.parseArguments(["--agent", "--verbose"])
        XCTAssertEqual(config.agent, "")
        XCTAssertTrue(config.verbose)
    }

    func testParseAgentOllamaModel() {
        // --agent ollama:llama3 → Ollama model
        let config = TestRunner.parseArguments(["--agent", "ollama:llama3", "test.yaml"])
        XCTAssertEqual(config.agent, "ollama:llama3")
        XCTAssertEqual(config.skillArgs, ["test.yaml"])
    }

    func testParseNoAgentByDefault() {
        // No --agent flag → nil
        let config = TestRunner.parseArguments(["skill.yaml"])
        XCTAssertNil(config.agent)
    }

    // MARK: - Skill Resolution

    func testResolveDirectFilePath() throws {
        let tmpDir = NSTemporaryDirectory() + "test-resolve-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
        let filePath = tmpDir + "/test.yaml"
        try "name: Test\nsteps:\n  - home".write(
            toFile: filePath, atomically: true, encoding: .utf8)

        let files = try TestRunner.resolveSkillFiles([filePath])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0], filePath)
    }

    func testResolveNotFoundThrows() {
        XCTAssertThrowsError(
            try TestRunner.resolveSkillFiles(["nonexistent-skill-xyz"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
    }
}
