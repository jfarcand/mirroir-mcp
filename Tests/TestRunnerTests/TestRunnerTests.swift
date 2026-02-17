// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for TestRunner: CLI argument parsing, scenario resolution, and help flag.
// ABOUTME: Tests pure logic functions without requiring system access.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class TestRunnerConfigTests: XCTestCase {

    // MARK: - Argument Parsing

    func testParseEmptyArgs() {
        let config = TestRunner.parseArguments([])
        XCTAssertTrue(config.scenarioArgs.isEmpty)
        XCTAssertNil(config.junitPath)
        XCTAssertEqual(config.screenshotDir, "./mirroir-test-results")
        XCTAssertEqual(config.timeoutSeconds, 15)
        XCTAssertFalse(config.verbose)
        XCTAssertFalse(config.dryRun)
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

    func testParseScenarioArgs() {
        let config = TestRunner.parseArguments(["check-about", "send-message"])
        XCTAssertEqual(config.scenarioArgs, ["check-about", "send-message"])
    }

    func testParseMixedArgs() {
        let config = TestRunner.parseArguments([
            "--verbose", "--junit", "out.xml",
            "--timeout", "20", "scenario1", "scenario2"
        ])
        XCTAssertTrue(config.verbose)
        XCTAssertEqual(config.junitPath, "out.xml")
        XCTAssertEqual(config.timeoutSeconds, 20)
        XCTAssertEqual(config.scenarioArgs, ["scenario1", "scenario2"])
    }

    func testParseIgnoresUnknownFlags() {
        let config = TestRunner.parseArguments(["--unknown", "scenario1"])
        // --unknown starts with - so it's treated as a flag, not a scenario
        XCTAssertEqual(config.scenarioArgs, ["scenario1"])
    }

    // MARK: - Scenario Resolution

    func testResolveDirectFilePath() throws {
        let tmpDir = NSTemporaryDirectory() + "test-resolve-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
        let filePath = tmpDir + "/test.yaml"
        try "name: Test\nsteps:\n  - home".write(
            toFile: filePath, atomically: true, encoding: .utf8)

        let files = try TestRunner.resolveScenarioFiles([filePath])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0], filePath)
    }

    func testResolveNotFoundThrows() {
        XCTAssertThrowsError(
            try TestRunner.resolveScenarioFiles(["nonexistent-scenario-xyz"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
    }
}
