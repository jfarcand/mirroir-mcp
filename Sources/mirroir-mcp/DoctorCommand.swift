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
    var noColor = false
    var json = false
    /// Walk through each missing privacy grant (`--fix`).
    var fix = false
    /// Check only the privacy grants (`--grants`).
    var grantsOnly = false
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
    /// A link that opens the place to fix it (a System Settings pane), when there is one.
    var fixURL: String? = nil
}

/// Runs diagnostic checks on the iPhone Mirroring setup and reports results
/// with colored output and actionable fix hints.
///
/// Usage: `mirroir-mcp doctor [--no-color] [--json] [--help]`
enum DoctorCommand {

    /// Parse arguments and run all checks. Returns exit code (0 = all pass,
    /// 1 = any failure, 2 = refused arguments).
    static func run(arguments: [String]) -> Int32 {
        let config: DoctorConfig
        do {
            config = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }

        let useColor = TerminalColor.isEnabled(for: STDERR_FILENO, disabledByFlag: config.noColor)

        let grantee = HostApp.current
        if config.grantsOnly {
            let checks = [checkScreenRecording(grantee: grantee), checkAccessibility(grantee: grantee)]
            return report(checks, config: config, useColor: useColor)
        }
        var checks = [DoctorCheck]()
        checks.append(checkMacOSVersion())
        checks.append(checkMirroringRunning())
        let connected = checkMirroringConnected()
        checks.append(connected)
        let screenRecording = checkScreenRecording(grantee: grantee)
        checks.append(screenRecording)
        // Reading the screen proves the grant is in effect, which needs a live mirror.
        if connected.status == .passed, screenRecording.status == .passed {
            checks.append(DoctorCaptureCheck.run(grantee: grantee))
        }
        checks.append(checkAccessibility(grantee: grantee))
        checks.append(updateCheck(notice: UpdateCheck.liveNotice()))
        checks.append(EmbacleVersionCheck.run())
        checks.append(contentsOf: PromptOverrideCheck.run())
        checks.append(contentsOf: checkConfiguredTargets())

        let status = report(checks, config: config, useColor: useColor)
        guard config.fix else { return status }
        let panes = DoctorGrantFix.missingPanes(in: checks)
        guard !panes.isEmpty else { return status }
        let pollUs = max(EnvConfig.grantPollUs, 1)
        let outcomes = DoctorGrantFix.run(
            panes: panes, grantee: grantee, system: LivePrivacyGrants(),
            polls: Int(EnvConfig.grantWaitUs / pollUs) + 1,
            wait: { usleep(pollUs) }, say: { fputs($0 + "\n", stderr) })
        return outcomes.allSatisfy { $0.1 == .granted } ? 0 : 1
    }

    /// Print the checks as JSON or as the colored report, and return 1 when one failed.
    private static func report(_ checks: [DoctorCheck], config: DoctorConfig, useColor: Bool) -> Int32 {
        if config.json {
            printJSON(checks: checks)
        } else {
            printReport(checks: checks, useColor: useColor)
        }
        return checks.contains { $0.status == .failed } ? 1 : 0
    }

    /// The option that checks only the privacy grants; `--fix` runs it in a
    /// fresh process to learn whether a grant is on.
    static let grantsOption = "--grants"

    /// The names of the two grant checks, which `--fix` reads back.
    static let screenCaptureCheckName = "Screen capture"
    static let accessibilityCheckName = "Accessibility"

    // MARK: - Argument Parsing

    /// Parse a `doctor` command line.
    ///
    /// - Throws: `CLIArgumentError` for anything but `--no-color` and `--json`.
    static func parseArguments(_ args: [String]) throws -> DoctorConfig {
        var config = DoctorConfig()

        for arg in args {
            switch arg {
            case "--no-color":
                config.noColor = true
            case "--json":
                config.json = true
            case "--fix":
                config.fix = true
            case grantsOption:
                config.grantsOnly = true
            default:
                throw CLIArguments.unrecognized(arg, command: "doctor")
            }
        }
        if config.fix, config.json {
            throw CLIArgumentError.invalidValue(flag: "--fix", value: "--json",
                                                expected: "the interactive report (--fix waits for you)")
        }
        if config.fix, config.grantsOnly {
            throw CLIArgumentError.invalidValue(flag: "--fix", value: grantsOption,
                                                expected: "the full report (--fix checks the grants itself)")
        }
        return config
    }

    /// The command's usage text.
    static var usage: String {
        """
        Usage: mirroir-mcp doctor [options]

        Check every prerequisite for a working mirroir-mcp setup.
        Runs diagnostic checks and reports results with fix hints.

        Options:
          --no-color    Disable colored output (it is also off when NO_COLOR is
                        set, or when the output is not a terminal)
          --json        Output results as JSON
          --fix         For each missing Accessibility or Screen Recording grant,
                        name the app to turn on, open its pane in System
                        Settings, and wait until a new process is granted it
          --grants      Check only the two privacy grants
          --help, -h    Show this help

        Examples:
          mirroir-mcp doctor
          mirroir-mcp doctor --json
          mirroir-mcp doctor --fix
          mirroir-mcp doctor --no-color
        """
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
            let block = bridge.sessionBlock()
            return DoctorCheck(
                name: "Mirroring connected",
                status: .failed,
                detail: block.map { "paused: \($0.said)" } ?? "paused",
                fixHint: block?.move.advice
                    ?? "Clear the interruption in the iPhone Mirroring window on the Mac, then retry."
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
        case .minimized:
            return DoctorCheck(
                name: "Mirroring connected",
                status: .failed,
                detail: "window minimized",
                fixHint: "Bring the iPhone Mirroring window back: click it in the Dock."
            )
        }
    }

    static func checkScreenRecording(grantee: HostApp.Grantee?) -> DoctorCheck {
        if #available(macOS 15.0, *) {
            let permitted = CGPreflightScreenCaptureAccess()
            if permitted {
                return DoctorCheck(
                    name: screenCaptureCheckName,
                    status: .passed,
                    detail: "permitted",
                    fixHint: nil
                )
            }
            return DoctorCheck(
                name: screenCaptureCheckName,
                status: .failed,
                detail: "not permitted",
                fixHint: PermissionGuidance.hint(.screenRecording, grantee: grantee),
                fixURL: PermissionGuidance.Pane.screenRecording.url
            )
        }

        return DoctorCheck(
            name: screenCaptureCheckName,
            status: .passed,
            detail: "pre-check not available (macOS <15)",
            fixHint: nil
        )
    }

    /// Whether a newer release is published; a warning, never a failure.
    static func updateCheck(notice: String?) -> DoctorCheck {
        guard let notice else {
            let detail = EnvConfig.updateCheck
                ? "\(MirroirVersion.current) (no newer release found)" : "\(MirroirVersion.current) (check off)"
            return DoctorCheck(name: "mirroir-mcp version", status: .passed, detail: detail, fixHint: nil)
        }
        return DoctorCheck(name: "mirroir-mcp version", status: .warned, detail: notice,
                           fixHint: "Run `mirroir-mcp update`.")
    }

    static func checkAccessibility(grantee: HostApp.Grantee?) -> DoctorCheck {
        let trusted = AXIsProcessTrusted()
        if trusted {
            return DoctorCheck(
                name: accessibilityCheckName,
                status: .passed,
                detail: "permitted",
                fixHint: nil
            )
        }

        return DoctorCheck(
            name: accessibilityCheckName,
            status: .failed,
            detail: "not granted",
            fixHint: PermissionGuidance.hint(.accessibility, grantee: grantee),
            fixURL: PermissionGuidance.Pane.accessibility.url
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
            let known = TargetKind.builders[typeName] != nil
            checks.append(DoctorCheck(
                name: "Target '\(name)'",
                status: known ? .passed : .failed,
                detail: "\(typeName) (bundle: \(bundleID))",
                fixHint: known ? nil : TargetKind.unknownTypeMessage(type: typeName, name: name)
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
            if let url = check.fixURL {
                entry["fix_url"] = url
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
        let (green, red, yellow, reset) = allColors(useColor: useColor)
        switch status {
        case .passed:
            return ("✓", green, reset)
        case .failed:
            return ("✗", red, reset)
        case .warned:
            return ("!", yellow, reset)
        }
    }

    /// The green, red, yellow and reset codes, or empty strings without colour.
    private static func allColors(useColor: Bool) -> (String, String, String, String) {
        if useColor {
            return (TerminalColor.green, TerminalColor.red, TerminalColor.yellow, TerminalColor.reset)
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
