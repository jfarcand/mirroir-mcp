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

    func testParseEmptyArgs() throws {
        let config = try TestRunner.parseArguments([])
        XCTAssertTrue(config.skillArgs.isEmpty)
        XCTAssertNil(config.junitPath)
        XCTAssertEqual(config.screenshotDir, "./mirroir-test-results")
        XCTAssertEqual(config.timeoutSeconds, 15)
        XCTAssertFalse(config.verbose)
        XCTAssertFalse(config.dryRun)
        XCTAssertNil(config.agent)
        XCTAssertFalse(config.showHelp)
    }

    func testParseHelpFlag() throws {
        let config = try TestRunner.parseArguments(["--help"])
        XCTAssertTrue(config.showHelp)
    }

    func testParseHelpShortFlag() throws {
        let config = try TestRunner.parseArguments(["-h"])
        XCTAssertTrue(config.showHelp)
    }

    func testParseVerboseFlag() throws {
        let config = try TestRunner.parseArguments(["--verbose"])
        XCTAssertTrue(config.verbose)
    }

    func testParseVerboseShortFlag() throws {
        let config = try TestRunner.parseArguments(["-v"])
        XCTAssertTrue(config.verbose)
    }

    func testParseDryRunFlag() throws {
        let config = try TestRunner.parseArguments(["--dry-run"])
        XCTAssertTrue(config.dryRun)
    }

    func testParseJUnitPath() throws {
        let config = try TestRunner.parseArguments(["--junit", "results.xml"])
        XCTAssertEqual(config.junitPath, "results.xml")
    }

    func testParseScreenshotDir() throws {
        let config = try TestRunner.parseArguments(["--screenshot-dir", "/tmp/shots"])
        XCTAssertEqual(config.screenshotDir, "/tmp/shots")
    }

    func testParseTimeout() throws {
        let config = try TestRunner.parseArguments(["--timeout", "30"])
        XCTAssertEqual(config.timeoutSeconds, 30)
    }

    func testParseSkillArgs() throws {
        let config = try TestRunner.parseArguments(["check-about", "send-message"])
        XCTAssertEqual(config.skillArgs, ["check-about", "send-message"])
    }

    func testParseMixedArgs() throws {
        let config = try TestRunner.parseArguments([
            "--verbose", "--junit", "out.xml",
            "--timeout", "20", "skill1", "skill2"
        ])
        XCTAssertTrue(config.verbose)
        XCTAssertEqual(config.junitPath, "out.xml")
        XCTAssertEqual(config.timeoutSeconds, 20)
        XCTAssertEqual(config.skillArgs, ["skill1", "skill2"])
    }

    /// A flag this command does not know is refused by name, never dropped: a
    /// caller passing a flag the CLI lacks must hear about it.
    func testParseRefusesUnknownFlags() {
        XCTAssertThrowsError(try TestRunner.parseArguments(["--unknown", "skill1"])) { error in
            XCTAssertEqual(error as? TestRunnerArgumentError, .unknownFlag("--unknown"))
            XCTAssertTrue(error.localizedDescription.contains("--unknown"))
        }
        XCTAssertThrowsError(try TestRunner.parseArguments(["-x"])) { error in
            XCTAssertEqual(error as? TestRunnerArgumentError, .unknownFlag("-x"))
        }
    }

    /// The flag that once disabled the CLI's auto-recompile no longer exists.
    func testParseRefusesTheRemovedAutoRecompileFlag() {
        XCTAssertThrowsError(try TestRunner.parseArguments(["--no-auto-recompile", "s.yaml"])) {
            XCTAssertEqual($0 as? TestRunnerArgumentError, .unknownFlag("--no-auto-recompile"))
        }
    }

    func testRunExitsTwoNamingAnUnknownFlag() {
        XCTAssertEqual(TestRunner.run(arguments: ["--bogus", "skill.yaml"]), TestRunner.usageExitCode)
        XCTAssertEqual(TestRunner.usageExitCode, 2)
    }

    func testParseRefusesAFlagMissingItsValue() {
        XCTAssertThrowsError(try TestRunner.parseArguments(["--report-json"])) {
            XCTAssertEqual($0 as? TestRunnerArgumentError, .missingValue(flag: "--report-json"))
        }
        XCTAssertThrowsError(try TestRunner.parseArguments(["--junit", "--verbose"])) {
            XCTAssertEqual($0 as? TestRunnerArgumentError, .missingValue(flag: "--junit"))
        }
        XCTAssertThrowsError(try TestRunner.parseArguments(["--timeout", "soon"])) {
            XCTAssertEqual($0 as? TestRunnerArgumentError,
                           .invalidValue(flag: "--timeout", value: "soon"))
        }
    }

    /// A dry run executes nothing, so it must never write a report a caller
    /// reads as a passing verdict.
    func testDryRunWithReportJSONIsRefused() {
        XCTAssertThrowsError(try TestRunner.parseArguments(
            ["--dry-run", "--report-json", "out.json", "skill.yaml"])) {
            XCTAssertEqual($0 as? TestRunnerArgumentError, .dryRunWithReport)
            XCTAssertTrue($0.localizedDescription.contains("--dry-run"))
        }
    }

    func testRunRefusesDryRunWithReportJSONAndWritesNoReport() throws {
        let dir = NSTemporaryDirectory() + "mirroir-dryrun-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let skill = dir + "/s.yaml"
        try "name: S\nsteps:\n  - home\n".write(toFile: skill, atomically: true, encoding: .utf8)
        let report = dir + "/report.json"

        XCTAssertEqual(TestRunner.run(arguments: ["--dry-run", "--report-json", report, skill]),
                       TestRunner.usageExitCode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: report))
    }

    // MARK: - Agent Flag Parsing

    func testParseBareAgentFlag() throws {
        // --agent with no model name → deterministic only (empty string)
        let config = try TestRunner.parseArguments(["--agent"])
        XCTAssertEqual(config.agent, "")
    }

    func testParseAgentWithModelName() throws {
        // --agent claude-sonnet-5-5 → AI model name
        let config = try TestRunner.parseArguments(["--agent", "claude-sonnet-5-5", "skill.yaml"])
        XCTAssertEqual(config.agent, "claude-sonnet-5-5")
        XCTAssertEqual(config.skillArgs, ["skill.yaml"])
    }

    func testParseAgentFollowedByYAML() throws {
        // --agent skill.yaml → bare agent, skill.yaml is a skill arg
        let config = try TestRunner.parseArguments(["--agent", "skill.yaml"])
        XCTAssertEqual(config.agent, "")
        XCTAssertEqual(config.skillArgs, ["skill.yaml"])
    }

    func testParseAgentFollowedByYMLFile() throws {
        // --agent test.yml → bare agent, test.yml is a skill arg
        let config = try TestRunner.parseArguments(["--agent", "test.yml"])
        XCTAssertEqual(config.agent, "")
        XCTAssertEqual(config.skillArgs, ["test.yml"])
    }

    func testParseAgentFollowedBySkillMd() throws {
        // --agent login.md → bare agent, login.md is a skill arg
        let config = try TestRunner.parseArguments(["--agent", "login.md"])
        XCTAssertEqual(config.agent, "")
        XCTAssertEqual(config.skillArgs, ["login.md"])
    }

    func testParseAgentFollowedByFlag() throws {
        // --agent --verbose → bare agent, verbose flag still parsed
        let config = try TestRunner.parseArguments(["--agent", "--verbose"])
        XCTAssertEqual(config.agent, "")
        XCTAssertTrue(config.verbose)
    }

    func testParseAgentOllamaModel() throws {
        // --agent ollama:llama3 → Ollama model
        let config = try TestRunner.parseArguments(["--agent", "ollama:llama3", "test.yaml"])
        XCTAssertEqual(config.agent, "ollama:llama3")
        XCTAssertEqual(config.skillArgs, ["test.yaml"])
    }

    func testParseNoAgentByDefault() throws {
        // No --agent flag → nil
        let config = try TestRunner.parseArguments(["skill.yaml"])
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
