// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the one decision that lets CLI output carry ANSI colour.
// ABOUTME: Also checks that no other source file holds an escape code of its own.

import XCTest
@testable import mirroir_mcp

final class TerminalColorTests: XCTestCase {

    func testColorNeedsATerminal() {
        XCTAssertFalse(TerminalColor.isEnabled(isTerminal: false, environment: [:], disabledByFlag: false))
    }

    func testColorIsOnForATerminal() {
        XCTAssertTrue(TerminalColor.isEnabled(isTerminal: true, environment: [:], disabledByFlag: false))
    }

    func testNoColorVariableDisablesColor() {
        XCTAssertFalse(TerminalColor.isEnabled(
            isTerminal: true, environment: ["NO_COLOR": "1"], disabledByFlag: false))
    }

    func testEmptyNoColorVariableIsIgnored() {
        XCTAssertTrue(TerminalColor.isEnabled(
            isTerminal: true, environment: ["NO_COLOR": ""], disabledByFlag: false))
    }

    func testNoColorFlagDisablesColor() {
        XCTAssertFalse(TerminalColor.isEnabled(isTerminal: true, environment: [:], disabledByFlag: true))
    }

    /// A test run is piped, so the live decision for stderr is off.
    func testTheLiveDecisionFollowsTheFlag() {
        XCTAssertFalse(TerminalColor.isEnabled(for: STDERR_FILENO, disabledByFlag: true))
    }

    func testEscapeCodesLiveOnlyInTerminalColor() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/mirroir-mcp")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "the scan must see the sources")
        let holders = try files.filter {
            try String(contentsOf: $0, encoding: .utf8).contains("\\u{001B}[")
        }.map(\.lastPathComponent)
        XCTAssertEqual(holders, ["TerminalColor.swift"])
    }
}
