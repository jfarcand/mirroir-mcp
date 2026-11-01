// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests `record` argument parsing: required live flags, the refused --no-ocr, --from-recording exclusivity.
// ABOUTME: Also runs --from-recording on the FIXME fixture end to end and checks nothing is written.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class RecordCommandArgumentsTests: XCTestCase {

    private func parse(_ args: [String]) throws -> RecordInvocation {
        try RecordCommand.parseArguments(args)
    }

    private func assertRefused(
        _ args: [String], _ expected: RecordArgumentError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try parse(args), file: file, line: line) { error in
            XCTAssertEqual(error as? RecordArgumentError, expected, file: file, line: line)
        }
    }

    func testLiveRecordingParsesAppNameAndOutputDir() throws {
        XCTAssertEqual(
            try parse(["--app", "Calculator", "--name", "calculator-add", "--output-dir", "/repo"]),
            .record(RecordConfig(
                source: .live(appName: "Calculator", flowName: "calculator-add"),
                outputDir: "/repo")))
    }

    func testOutputDirIsOptional() throws {
        XCTAssertEqual(
            try parse(["--name", "f", "--app", "Notes"]),
            .record(RecordConfig(source: .live(appName: "Notes", flowName: "f"), outputDir: nil)))
    }

    func testLiveRecordingRequiresAppAndName() {
        assertRefused([], .missingRequired(flags: ["--app", "--name"]))
        assertRefused(["--app", "Notes"], .missingRequired(flags: ["--name"]))
        assertRefused(["--name", "f"], .missingRequired(flags: ["--app"]))
    }

    func testNoOCRIsRefused() {
        assertRefused(["--app", "Notes", "--name", "f", "--no-ocr"], .noOCRUnsupported)
    }

    func testFromRecordingExcludesAppAndName() {
        assertRefused(["--from-recording", "r.json", "--app", "Notes"],
                      .conflictsWithSavedRecording(flags: ["--app"]))
        assertRefused(["--name", "f", "--from-recording", "r.json", "--app", "Notes"],
                      .conflictsWithSavedRecording(flags: ["--app", "--name"]))
    }

    func testFromRecordingParses() throws {
        XCTAssertEqual(
            try parse(["--from-recording", "r.json", "--output-dir", "/repo"]),
            .record(RecordConfig(source: .savedRecording(path: "r.json"), outputDir: "/repo")))
    }

    func testRemovedAndUnknownFlagsAreRefused() {
        assertRefused(["-o", "out.yaml"], .unknownArgument("-o"))
        assertRefused(["--description", "x"], .unknownArgument("--description"))
    }

    func testFlagWithoutValueIsRefused() {
        assertRefused(["--app"], .missingValue(flag: "--app"))
        assertRefused(["--app", "Notes", "--name", ""], .missingValue(flag: "--name"))
    }

    func testHelp() throws {
        XCTAssertEqual(try parse(["--app", "Notes", "-h"]), .help)
        XCTAssertEqual(RecordCommand.run(arguments: ["--help"]), 0)
    }

    func testBadArgumentsExitOne() {
        XCTAssertEqual(RecordCommand.run(arguments: ["--no-ocr"]), 1)
    }

    /// A live session is saved under the global home, slugged by app and flow.
    func testRecordingPathIsSluggedUnderTheGlobalHome() {
        let path = RecordCommand.recordingPath(appName: "My App", flowName: "Add Item")
        XCTAssertEqual(
            path.path,
            PermissionPolicy.globalConfigDir + "/recordings/my-app/add-item.recording.json")
    }

    /// `--from-recording` on the FIXME fixture fails with exit 1 and writes no
    /// scenario — the emit refuses before touching the tree.
    func testFromRecordingFixmeFixtureExitsOneAndWritesNothing() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-record-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let code = RecordCommand.run(arguments: [
            "--from-recording", RecordingWalkTests.fixturePath("calculator-fixme"),
            "--output-dir", repo.path,
        ])

        XCTAssertEqual(code, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(MirroirRootLocator.dirName).path))
    }

    func testFromRecordingMissingFileExitsOne() {
        XCTAssertEqual(RecordCommand.run(arguments: [
            "--from-recording", "/nonexistent/\(UUID().uuidString)\(Recording.fileSuffix)",
        ]), 1)
    }
}
