// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for DoctorCommand argument parsing, output formatting, and JSON parsing.
// ABOUTME: Validates the diagnostic command's pure-logic methods without requiring system state.

import XCTest
@testable import iphone_mirroir_mcp

final class DoctorCommandTests: XCTestCase {

    // MARK: - Argument Parsing

    func testParseArgumentsDefault() {
        let config = DoctorCommand.parseArguments([])
        XCTAssertFalse(config.showHelp)
        XCTAssertFalse(config.noColor)
        XCTAssertFalse(config.json)
    }

    func testParseArgumentsHelp() {
        let config = DoctorCommand.parseArguments(["--help"])
        XCTAssertTrue(config.showHelp)
    }

    func testParseArgumentsHelpShort() {
        let config = DoctorCommand.parseArguments(["-h"])
        XCTAssertTrue(config.showHelp)
    }

    func testParseArgumentsNoColor() {
        let config = DoctorCommand.parseArguments(["--no-color"])
        XCTAssertTrue(config.noColor)
    }

    func testParseArgumentsJSON() {
        let config = DoctorCommand.parseArguments(["--json"])
        XCTAssertTrue(config.json)
    }

    func testParseArgumentsCombined() {
        let config = DoctorCommand.parseArguments(["--no-color", "--json"])
        XCTAssertTrue(config.noColor)
        XCTAssertTrue(config.json)
        XCTAssertFalse(config.showHelp)
    }

    // MARK: - formatCheck Output

    func testFormatCheckPassed() {
        let check = DoctorCheck(
            name: "macOS version",
            status: .passed,
            detail: "macOS 15.2.0 (Sequoia)",
            fixHint: nil
        )
        let output = DoctorCommand.formatCheck(check, useColor: false)
        XCTAssertTrue(output.contains("✓"))
        XCTAssertTrue(output.contains("macOS 15.2.0 (Sequoia)"))
        XCTAssertFalse(output.contains("→"))
    }

    func testFormatCheckFailed() {
        let check = DoctorCheck(
            name: "Accessibility",
            status: .failed,
            detail: "not granted",
            fixHint: "Open System Settings > Privacy & Security > Accessibility"
        )
        let output = DoctorCommand.formatCheck(check, useColor: false)
        XCTAssertTrue(output.contains("✗"))
        XCTAssertTrue(output.contains("not granted"))
        XCTAssertTrue(output.contains("→"))
        XCTAssertTrue(output.contains("System Settings"))
    }

    func testFormatCheckWarned() {
        let check = DoctorCheck(
            name: "Karabiner ignore rule",
            status: .warned,
            detail: "not configured",
            fixHint: "Add a device ignore rule"
        )
        let output = DoctorCommand.formatCheck(check, useColor: false)
        XCTAssertTrue(output.contains("!"))
        XCTAssertTrue(output.contains("not configured"))
        XCTAssertTrue(output.contains("→"))
    }

    func testFormatCheckNoColorNoANSI() {
        let check = DoctorCheck(
            name: "test",
            status: .passed,
            detail: "ok",
            fixHint: nil
        )
        let output = DoctorCommand.formatCheck(check, useColor: false)
        XCTAssertFalse(output.contains("\u{001B}"))
    }

    func testFormatCheckWithColorContainsANSI() {
        let check = DoctorCheck(
            name: "test",
            status: .passed,
            detail: "ok",
            fixHint: nil
        )
        let output = DoctorCommand.formatCheck(check, useColor: true)
        XCTAssertTrue(output.contains("\u{001B}[32m"))  // green
        XCTAssertTrue(output.contains("\u{001B}[0m"))    // reset
    }

    func testFormatCheckFailedColorContainsRed() {
        let check = DoctorCheck(
            name: "test",
            status: .failed,
            detail: "bad",
            fixHint: "fix it"
        )
        let output = DoctorCommand.formatCheck(check, useColor: true)
        XCTAssertTrue(output.contains("\u{001B}[31m"))  // red
    }

    // MARK: - Karabiner Config Parsing

    func testHasIgnoreRulePresent() {
        let json: [String: Any] = [
            "profiles": [[
                "name": "Default",
                "devices": [[
                    "identifiers": [
                        "vendor_id": 1452,
                        "product_id": 592,
                    ],
                    "ignore": true,
                ]],
            ]],
        ]
        XCTAssertTrue(DoctorCommand.hasIgnoreRule(in: json))
    }

    func testHasIgnoreRuleAbsent() {
        let json: [String: Any] = [
            "profiles": [[
                "name": "Default",
                "devices": [[
                    "identifiers": [
                        "vendor_id": 1452,
                        "product_id": 123,
                    ],
                    "ignore": true,
                ]],
            ]],
        ]
        XCTAssertFalse(DoctorCommand.hasIgnoreRule(in: json))
    }

    func testHasIgnoreRuleNotIgnored() {
        let json: [String: Any] = [
            "profiles": [[
                "name": "Default",
                "devices": [[
                    "identifiers": [
                        "vendor_id": 1452,
                        "product_id": 592,
                    ],
                    "ignore": false,
                ]],
            ]],
        ]
        XCTAssertFalse(DoctorCommand.hasIgnoreRule(in: json))
    }

    func testHasIgnoreRuleEmptyProfiles() {
        let json: [String: Any] = ["profiles": [[String: Any]]()]
        XCTAssertFalse(DoctorCommand.hasIgnoreRule(in: json))
    }

    func testHasIgnoreRuleNoProfiles() {
        let json: [String: Any] = ["global": ["check_for_updates_on_startup": true]]
        XCTAssertFalse(DoctorCommand.hasIgnoreRule(in: json))
    }

    // MARK: - Summary Formatting

    func testFormatSummaryAllPassed() {
        let checks = (0..<10).map { i in
            DoctorCheck(name: "check\(i)", status: .passed, detail: "ok", fixHint: nil)
        }
        let summary = DoctorCommand.formatSummary(checks: checks, useColor: false)
        XCTAssertTrue(summary.contains("10 passed"))
        XCTAssertFalse(summary.contains("failed"))
        XCTAssertFalse(summary.contains("warned"))
    }

    func testFormatSummaryMixed() {
        let checks = [
            DoctorCheck(name: "a", status: .passed, detail: "ok", fixHint: nil),
            DoctorCheck(name: "b", status: .passed, detail: "ok", fixHint: nil),
            DoctorCheck(name: "c", status: .failed, detail: "bad", fixHint: "fix"),
            DoctorCheck(name: "d", status: .warned, detail: "maybe", fixHint: "check"),
        ]
        let summary = DoctorCommand.formatSummary(checks: checks, useColor: false)
        XCTAssertTrue(summary.contains("2 passed"))
        XCTAssertTrue(summary.contains("1 failed"))
        XCTAssertTrue(summary.contains("1 warned"))
    }

    func testFormatSummaryNoColor() {
        let checks = [
            DoctorCheck(name: "a", status: .passed, detail: "ok", fixHint: nil),
        ]
        let summary = DoctorCommand.formatSummary(checks: checks, useColor: false)
        XCTAssertFalse(summary.contains("\u{001B}"))
    }

    // MARK: - macOS Codename

    func testMacOSCodename() {
        XCTAssertEqual(DoctorCommand.macOSCodename(major: 15), "Sequoia")
        XCTAssertEqual(DoctorCommand.macOSCodename(major: 16), "Tahoe")
        XCTAssertEqual(DoctorCommand.macOSCodename(major: 17), "macOS 17")
    }

    // MARK: - Status Symbols

    func testStatusSymbolsPassed() {
        let (icon, color, reset) = DoctorCommand.statusSymbols(.passed, useColor: true)
        XCTAssertEqual(icon, "✓")
        XCTAssertEqual(color, "\u{001B}[32m")
        XCTAssertEqual(reset, "\u{001B}[0m")
    }

    func testStatusSymbolsFailed() {
        let (icon, color, reset) = DoctorCommand.statusSymbols(.failed, useColor: true)
        XCTAssertEqual(icon, "✗")
        XCTAssertEqual(color, "\u{001B}[31m")
        XCTAssertEqual(reset, "\u{001B}[0m")
    }

    func testStatusSymbolsWarned() {
        let (icon, color, reset) = DoctorCommand.statusSymbols(.warned, useColor: true)
        XCTAssertEqual(icon, "!")
        XCTAssertEqual(color, "\u{001B}[33m")
        XCTAssertEqual(reset, "\u{001B}[0m")
    }

    func testStatusSymbolsNoColor() {
        let (icon, color, reset) = DoctorCommand.statusSymbols(.passed, useColor: false)
        XCTAssertEqual(icon, "✓")
        XCTAssertEqual(color, "")
        XCTAssertEqual(reset, "")
    }
}
