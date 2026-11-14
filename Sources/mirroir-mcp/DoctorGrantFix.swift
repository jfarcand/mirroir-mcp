// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: `doctor --fix`: walks the user through each missing Accessibility or Screen Recording grant, one pane at a time.
// ABOUTME: Names the app to turn on, opens its pane, and moves on once a freshly started process sees the grant.

import Foundation
import HelperLib

/// The guided fix for missing privacy grants.
///
/// For each missing pane it says which app to turn on (the process macOS holds
/// responsible for mirroir-mcp, see `HostApp`), opens the pane, and waits until
/// a new process is granted it: the running one would keep its old answer.
enum DoctorGrantFix {

    /// How one pane's fix ended.
    enum Outcome: Equatable {
        case granted
        case timedOut
        case paneDidNotOpen
        case probeFailed
    }

    /// The grants doctor fixes, in the order it fixes them: Accessibility needs
    /// no restart, so it goes first and Screen Recording's restart comes last.
    static let order: [PermissionGuidance.Pane] = [.accessibility, .screenRecording]

    /// The panes `checks` report as not granted, in fixing order.
    static func missingPanes(in checks: [DoctorCheck]) -> [PermissionGuidance.Pane] {
        order.filter { pane in
            checks.contains { $0.status == .failed && $0.fixURL == pane.url }
        }
    }

    /// Fix each of `panes` in turn.
    ///
    /// - Parameters:
    ///   - grantee: what holds the grants, named in every instruction.
    ///   - system: opens panes and probes a fresh process.
    ///   - polls: how many times to probe per pane before giving up.
    ///   - wait: called between probes; sleeps outside tests.
    ///   - say: prints one line to the user.
    /// - Returns: each pane's outcome, in order.
    static func run(panes: [PermissionGuidance.Pane], grantee: HostApp.Grantee?,
                    system: any PrivacyGrantChecking, polls: Int,
                    wait: () -> Void, say: (String) -> Void) -> [(PermissionGuidance.Pane, Outcome)] {
        var outcomes: [(PermissionGuidance.Pane, Outcome)] = []
        for pane in panes {
            say("\n\(pane.title): " + PermissionGuidance.hint(pane, grantee: grantee))
            guard system.open(pane) else {
                say("  Could not open System Settings; open the pane with the link above.")
                outcomes.append((pane, .paneDidNotOpen))
                continue
            }
            say("  Opened System Settings. Waiting for the switch to be turned on (Ctrl+C to stop)...")
            let outcome = waitForGrant(pane, system: system, polls: polls, wait: wait)
            switch outcome {
            case .granted: say("  \(pane.title) is granted.")
            case .timedOut: say("  \(pane.title) is still off. Turn it on, then run `mirroir-mcp doctor --fix` again.")
            case .probeFailed: say("  Could not start a new process to check the grant; run `mirroir-mcp doctor` again.")
            case .paneDidNotOpen: break
            }
            outcomes.append((pane, outcome))
        }
        if outcomes.contains(where: { $0.0 == .screenRecording && $0.1 == .granted }) {
            say("\nNow \(PermissionGuidance.restart(grantee)): Screen Recording takes effect only after a restart.")
        }
        say("\nThis checked the grants of \(grantee.map { "\"\($0.displayName)\"" } ?? "this process"). "
            + "A server your AI client starts may answer for itself: its check_health tool names what to turn on.")
        return outcomes
    }

    private static func waitForGrant(_ pane: PermissionGuidance.Pane, system: any PrivacyGrantChecking,
                                     polls: Int, wait: () -> Void) -> Outcome {
        for attempt in 0..<max(polls, 1) {
            if attempt > 0 { wait() }
            guard let granted = system.grantedToFreshProcess() else { return .probeFailed }
            if granted.contains(pane) { return .granted }
        }
        return .timedOut
    }

    /// Read the panes a `doctor --json --grants` run reports as passed.
    static func grantedPanes(inDoctorJSON data: Data) -> Set<PermissionGuidance.Pane>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checks = object["checks"] as? [[String: Any]] else { return nil }
        var granted = Set<PermissionGuidance.Pane>()
        for check in checks where check["status"] as? String == CheckStatus.passed.rawValue {
            switch check["name"] as? String {
            case DoctorCommand.screenCaptureCheckName: granted.insert(.screenRecording)
            case DoctorCommand.accessibilityCheckName: granted.insert(.accessibility)
            default: continue
            }
        }
        return granted
    }
}

/// System Settings and a fresh `mirroir-mcp doctor --json --grants` process.
struct LivePrivacyGrants: PrivacyGrantChecking {

    func open(_ pane: PermissionGuidance.Pane) -> Bool {
        run("/usr/bin/open", [pane.url])?.status == 0
    }

    func grantedToFreshProcess() -> Set<PermissionGuidance.Pane>? {
        guard let result = run(InstallAgentCommand.invokedExecutablePath(),
                               ["doctor", "--json", DoctorCommand.grantsOption]) else { return nil }
        return DoctorGrantFix.grantedPanes(inDoctorJSON: result.output)
    }

    private func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // doctor writes its report, JSON included, to stderr.
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
