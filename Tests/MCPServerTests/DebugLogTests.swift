// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the shared debug log: pid-tagged lines, appends that never truncate, rotation past the size limit,
// ABOUTME: and how --debug or the Claude extension's MIRROIR_DEBUG option turn verbose logging on. Files live in a temp dir.

import HelperLib
import XCTest
@testable import mirroir_mcp

final class DebugLogTests: XCTestCase {

    private var directory = ""
    private var log: String { directory + "/debug.log" }
    private var rotated: String { log + ".1" }

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "debug-log-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    func testEveryLineNamesTheProcessThatWroteIt() {
        XCTAssertEqual(DebugLog.line(tag: "startup", time: "12:00:00.000", pid: 4242, message: "version: abc"),
                       "[startup 12:00:00.000 pid 4242] version: abc\n")
    }

    /// Two servers write one file: the second one's lines follow the first's
    /// instead of erasing them.
    func testAppendsFromTwoProcessesKeepBothLogs() throws {
        DebugLog.appendToFile(DebugLog.line(tag: "a", time: "t", pid: 1, message: "first server"), path: log)
        DebugLog.appendToFile(DebugLog.line(tag: "b", time: "t", pid: 2, message: "second server"), path: log)
        XCTAssertEqual(try contents(log), "[a t pid 1] first server\n[b t pid 2] second server\n")
    }

    func testALogUnderTheLimitStaysWhereItIs() throws {
        DebugLog.appendToFile("short\n", path: log)
        DebugLog.rotateIfLarger(than: 1024, path: log, rotatedPath: rotated)
        XCTAssertEqual(try contents(log), "short\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated))
    }

    /// Past the limit the log is moved aside, never truncated: its lines stay
    /// readable in debug.log.1 and the next write starts a new file.
    func testALogPastTheLimitIsMovedAsideWithItsLines() throws {
        DebugLog.appendToFile(String(repeating: "x", count: 64) + "\n", path: log)
        DebugLog.rotateIfLarger(than: 16, path: log, rotatedPath: rotated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log))
        XCTAssertEqual(try contents(rotated).count, 65)
        DebugLog.appendToFile("next\n", path: log)
        XCTAssertEqual(try contents(log), "next\n")
    }

    func testDebugIsRequestedByTheFlagOrTheSetting() {
        XCTAssertTrue(DebugLog.isRequested(arguments: ["mirroir-mcp", "--debug"], setting: false))
        XCTAssertTrue(DebugLog.isRequested(arguments: ["mirroir-mcp"], setting: true))
        XCTAssertFalse(DebugLog.isRequested(arguments: ["mirroir-mcp"], setting: false))
    }

    /// The extension's boolean option reaches the server as the text "true" or
    /// "false"; a host that does not substitute it passes the placeholder.
    func testTheExtensionOptionValuesReadAsOnOrOff() {
        XCTAssertTrue(EnvConfig.isTrue("true"))
        XCTAssertTrue(EnvConfig.isTrue("TRUE"))
        XCTAssertTrue(EnvConfig.isTrue("1"))
        XCTAssertFalse(EnvConfig.isTrue("false"))
        XCTAssertFalse(EnvConfig.isTrue(""))
        XCTAssertFalse(EnvConfig.isTrue("${user_config.debug_logging}"))
    }

    /// The manifest maps the option to the variable the server reads, never to
    /// an argument: a stray "true" argument would stop the server from starting.
    func testTheExtensionMapsDebugLoggingToTheEnvironment() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("mcpb/manifest.json")
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let option = try XCTUnwrap((manifest["user_config"] as? [String: Any])?["debug_logging"] as? [String: Any])
        XCTAssertEqual(option["type"] as? String, "boolean")
        XCTAssertEqual(option["default"] as? Bool, false)
        let config = try XCTUnwrap((manifest["server"] as? [String: Any])?["mcp_config"] as? [String: Any])
        XCTAssertEqual((config["env"] as? [String: String])?["MIRROIR_DEBUG"], "${user_config.debug_logging}")
        XCTAssertEqual((config["args"] as? [String])?.isEmpty, true)
        if case .refused = CLIDispatch.route(["true"]) {} else {
            XCTFail("a bare value as an argument is refused, which is why the option is not an argument")
        }
    }
}
