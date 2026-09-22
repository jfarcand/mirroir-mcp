// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI diagnostic command that checks every prerequisite for a working setup.
// ABOUTME: Runs 10 checks with colored output and actionable fix hints.

import ApplicationServices
import CoreGraphics
import Foundation
import HelperLib

/// Configuration parsed from `doctor` subcommand arguments.
struct DoctorConfig {
    let showHelp: Bool
    let noColor: Bool
    let json: Bool
}

/// Result status for a single diagnostic check.
enum CheckStatus: String {
    case passed
    case failed
    case warned
}

/// A single diagnostic check result with optional fix hint.
struct DoctorCheck {
    let name: String
    let status: CheckStatus
    let detail: String
    let fixHint: String?
}

/// Runs diagnostic checks on the iPhone Mirroring setup and reports results
/// with colored output and actionable fix hints.
///
/// Usage: `mirroir-mcp doctor [--no-color] [--json] [--help]`
enum DoctorCommand {

    /// Parse arguments and run all checks. Returns exit code (0 = all pass, 1 = any failure).
    static func run(arguments: [String]) -> Int32 {
        let config = parseArguments(arguments)

        if config.showHelp {
            printUsage()
            return 0
        }

        let useColor = config.noColor ? false : isatty(STDERR_FILENO) != 0

        var checks = [DoctorCheck]()
        checks.append(checkMacOSVersion())
        checks.append(checkMirroringRunning())
        checks.append(checkMirroringConnected())
        checks.append(checkScreenRecording())
        checks.append(checkAccessibility())
        checks.append(EmbacleVersionCheck.run())
        checks.append(contentsOf: checkConfiguredTargets())

        if config.json {
            printJSON(checks: checks)
        } else {
            printReport(checks: checks, useColor: useColor)
        }

        let hasFailure = checks.contains { $0.status == .failed }
        return hasFailure ? 1 : 0
    }

    // MARK: - Argument Parsing

    static func parseArguments(_ args: [String]) -> DoctorConfig {
        var showHelp = false
        var noColor = false
        var json = false

        for arg in args {
            switch arg {
            case "--help", "-h":
                showHelp = true
            case "--no-color":
                noColor = true
            case "--json":
                json = true
            default:
                break
            }
        }

        return DoctorConfig(showHelp: showHelp, noColor: noColor, json: json)
    }

    static func printUsage() {
        let usage = """
        Usage: mirroir-mcp doctor [options]

        Check every prerequisite for a working mirroir-mcp setup.
        Runs diagnostic checks and reports results with fix hints.

        Options:
          --no-color    Disable colored output
          --json        Output results as JSON
          --help, -h    Show this help

        Examples:
          mirroir-mcp doctor
          mirroir-mcp doctor --json
          mirroir-mcp doctor --no-color
        """
        fputs(usage + "\n", stderr)
    }

    // MARK: - Diagnostic Checks

    static func checkMacOSVersion() -> DoctorCheck {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionStr = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        if version.majorVersion >= 15 {
            let codename = macOSCodename(major: version.majorVersion)
            return DoctorCheck(
                name: "macOS version",
                status: .passed,
                detail: "macOS \(versionStr) (\(codename))",
                fixHint: nil
            )
        }

        return DoctorCheck(
            name: "macOS version",
            status: .failed,
            detail: "macOS \(versionStr) (requires 15.0+)",
            fixHint: "iPhone Mirroring requires macOS 15 (Sequoia) or later. Update in System Settings > General > Software Update."
        )
    }

    static func checkMirroringRunning() -> DoctorCheck {
        let bridge = MirroringBridge()
        guard bridge.findProcess() != nil else {
            return DoctorCheck(
                name: "iPhone Mirroring",
                status: .failed,
                detail: "not running",
                fixHint: "Open iPhone Mirroring: open -a 'iPhone Mirroring'"
            )
        }

        return DoctorCheck(
            name: "iPhone Mirroring",
            status: .passed,
            detail: "running",
            fixHint: nil
        )
    }

    static func checkMirroringConnected() -> DoctorCheck {
        let bridge = MirroringBridge()
        let state = bridge.getState()

        switch state {
        case .connected:
            if let info = bridge.getWindowInfo() {
                let w = Int(info.size.width)
                let h = Int(info.size.height)
                let orientation = info.orientation.rawValue
                return DoctorCheck(
                    name: "Mirroring connected",
                    status: .passed,
                    detail: "\(w)x\(h), \(orientation)",
                    fixHint: nil
                )
            }
            return DoctorCheck(
                name: "Mirroring connected",
                status: .passed,
                detail: "connected",
                fixHint: nil
            )
        case .paused:
            return DoctorCheck(
                name: "Mirroring connected",
                status: .failed,
                detail: "paused",
                fixHint: "iPhone Mirroring is paused. Unlock your iPhone and click Resume in the mirroring window."
            )
        case .notRunning:
            return DoctorCheck(
                name: "Mirroring connected",
                status: .failed,
                detail: "app not running",
                fixHint: "Open iPhone Mirroring: open -a 'iPhone Mirroring'"
            )
        case .noWindow:
            return DoctorCheck(
                name: "Mirroring connected",
                status: .failed,
                detail: "no window",
                fixHint: "iPhone Mirroring has no window. Try closing and reopening the app."
            )
        }
    }

    static func checkScreenRecording() -> DoctorCheck {
        if #available(macOS 15.0, *) {
            let permitted = CGPreflightScreenCaptureAccess()
            if permitted {
                return DoctorCheck(
                    name: "Screen capture",
                    status: .passed,
                    detail: "permitted",
                    fixHint: nil
                )
            }
            return DoctorCheck(
                name: "Screen capture",
                status: .failed,
                detail: "not permitted",
                fixHint: "Open System Settings > Privacy & Security > Screen Recording and enable the terminal app you're using."
            )
        }

        return DoctorCheck(
            name: "Screen capture",
            status: .passed,
            detail: "pre-check not available (macOS <15)",
            fixHint: nil
        )
    }

    static func checkAccessibility() -> DoctorCheck {
        let trusted = AXIsProcessTrusted()
        if trusted {
            return DoctorCheck(
                name: "Accessibility",
                status: .passed,
                detail: "permitted",
                fixHint: nil
            )
        }

        return DoctorCheck(
            name: "Accessibility",
            status: .failed,
            detail: "not granted",
            fixHint: "Open System Settings > Privacy & Security > Accessibility and enable the terminal app you're using."
        )
    }

    static func checkConfiguredTargets() -> [DoctorCheck] {
        guard let targetsFile = TargetConfigLoader.load() else {
            return []
        }

        let targets = targetsFile.targets
        guard !targets.isEmpty else {
            return []
        }

        var checks: [DoctorCheck] = []

        let defaultTarget = targetsFile.defaultTarget ?? targets.keys.sorted().first ?? ""
        let names = targets.keys.sorted()
        checks.append(DoctorCheck(
            name: "Configured targets",
            status: .passed,
            detail: "\(names.count) target(s): \(names.joined(separator: ", ")) (default: \(defaultTarget))",
            fixHint: nil
        ))

        for name in names {
            guard let config = targets[name] else { continue }
            let typeName = config.type
            let bundleID = config.bundleID ?? "unset"
            checks.append(DoctorCheck(
                name: "Target '\(name)'",
                status: .passed,
                detail: "\(typeName) (bundle: \(bundleID))",
                fixHint: nil
            ))
        }

        return checks
    }

    // MARK: - Output Formatting

    /// Format a single check line for terminal output.
    static func formatCheck(_ check: DoctorCheck, useColor: Bool) -> String {
        let (icon, color, reset) = statusSymbols(check.status, useColor: useColor)
        var line = "  \(color)\(icon)\(reset) \(check.detail)"

        if let hint = check.fixHint, check.status != .passed {
            line += "\n    \(color)→\(reset) \(hint)"
        }

        return line
    }

    /// Format the summary line (e.g., "9 passed, 1 failed").
    static func formatSummary(checks: [DoctorCheck], useColor: Bool) -> String {
        let passed = checks.filter { $0.status == .passed }.count
        let failed = checks.filter { $0.status == .failed }.count
        let warned = checks.filter { $0.status == .warned }.count

        var parts = [String]()

        let (green, red, yellow, reset) = allColors(useColor: useColor)

        if passed > 0 { parts.append("\(green)\(passed) passed\(reset)") }
        if warned > 0 { parts.append("\(yellow)\(warned) warned\(reset)") }
        if failed > 0 { parts.append("\(red)\(failed) failed\(reset)") }

        return parts.joined(separator: ", ")
    }

    // MARK: - Private Helpers

    private static func printReport(checks: [DoctorCheck], useColor: Bool) {
        fputs("\nmirroir doctor\n\n", stderr)

        for check in checks {
            fputs(formatCheck(check, useColor: useColor) + "\n", stderr)
        }

        fputs("\n\(formatSummary(checks: checks, useColor: useColor))\n", stderr)
    }

    private static func printJSON(checks: [DoctorCheck]) {
        var results = [[String: Any]]()
        for check in checks {
            var entry: [String: Any] = [
                "name": check.name,
                "status": check.status.rawValue,
                "detail": check.detail,
            ]
            if let hint = check.fixHint {
                entry["fix_hint"] = hint
            }
            results.append(entry)
        }

        let passed = checks.filter { $0.status == .passed }.count
        let failed = checks.filter { $0.status == .failed }.count
        let warned = checks.filter { $0.status == .warned }.count

        let output: [String: Any] = [
            "checks": results,
            "summary": [
                "passed": passed,
                "failed": failed,
                "warned": warned,
                "total": checks.count,
            ],
        ]

        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            fputs(str + "\n", stderr)
        }
    }

    /// Returns (icon, colorCode, resetCode) for a check status.
    static func statusSymbols(_ status: CheckStatus, useColor: Bool) -> (String, String, String) {
        switch status {
        case .passed:
            return ("✓", useColor ? "\u{001B}[32m" : "", useColor ? "\u{001B}[0m" : "")
        case .failed:
            return ("✗", useColor ? "\u{001B}[31m" : "", useColor ? "\u{001B}[0m" : "")
        case .warned:
            return ("!", useColor ? "\u{001B}[33m" : "", useColor ? "\u{001B}[0m" : "")
        }
    }

    private static func allColors(useColor: Bool) -> (String, String, String, String) {
        if useColor {
            return ("\u{001B}[32m", "\u{001B}[31m", "\u{001B}[33m", "\u{001B}[0m")
        }
        return ("", "", "", "")
    }

    /// Map macOS major version to marketing codename.
    static func macOSCodename(major: Int) -> String {
        switch major {
        case 15: return "Sequoia"
        case 16: return "Tahoe"
        default: return "macOS \(major)"
        }
    }
}
