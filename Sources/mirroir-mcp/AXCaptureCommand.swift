// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI command that writes what Accessibility reports for the iPhone Mirroring window as a tagged fixture file.
// ABOUTME: Read-only: it calls the same probe the session-state check uses and presses nothing.

import Darwin
import Foundation
import HelperLib

/// Configuration parsed from `ax-capture` arguments.
struct AXCaptureConfig: Equatable {
    /// What the capture shows; it names the file.
    let name: String
    /// The directory to write to.
    let outputDirectory: String
    /// Poll for this long and write one file per distinct window, or nil for one capture now.
    let watchSeconds: Int?
}

/// Writes the iPhone Mirroring window, as Accessibility reports it, to a file
/// the session-state tests replay.
///
/// Usage: `mirroir-mcp ax-capture <name> [--out <dir>] [--watch <seconds>]`
enum AXCaptureCommand {

    /// How often watch mode reads the window.
    static let watchPollInterval: TimeInterval = 0.25

    /// Parse an `ax-capture` command line.
    ///
    /// - Throws: `CLIArgumentError` for an unknown option, a missing or bad
    ///   value, a missing name, or a second positional argument.
    static func parseArguments(_ args: [String]) throws -> AXCaptureConfig {
        var name: String?
        var outputDirectory = FileManager.default.currentDirectoryPath
        var watchSeconds: Int?

        var i = 0
        func value(for flag: String) throws -> String {
            i += 1
            guard i < args.count, !args[i].hasPrefix("-") else {
                throw CLIArgumentError.missingValue(flag: flag)
            }
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--out":
                outputDirectory = try value(for: arg)
            case "--watch":
                let raw = try value(for: arg)
                guard let seconds = Int(raw), seconds > 0 else {
                    throw CLIArgumentError.invalidValue(
                        flag: arg, value: raw, expected: "a positive whole number of seconds")
                }
                watchSeconds = seconds
            default:
                guard !arg.hasPrefix("-"), name == nil else {
                    throw CLIArguments.unrecognized(arg, command: commandName)
                }
                name = arg
            }
            i += 1
        }
        guard let name, !name.isEmpty else {
            throw CLIArgumentError.missingArgument("a name for the capture", command: commandName)
        }
        return AXCaptureConfig(name: name, outputDirectory: outputDirectory, watchSeconds: watchSeconds)
    }

    /// The word after `mirroir-mcp`.
    static let commandName = "ax-capture"

    /// Capture the window and write it. Returns 0 when at least one file was
    /// written, 1 when nothing could be captured or written, 2 for refused arguments.
    static func run(arguments: [String]) -> Int32 {
        let config: AXCaptureConfig
        do {
            config = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }
        let bundleID = EnvConfig.mirroringBundleID
        let probe = LiveMirroringProbe()
        let environment = AXCaptureEnvironment.live(bundleID: bundleID)

        guard let seconds = config.watchSeconds else {
            guard probe.processID(bundleID: bundleID) != nil else {
                fputs("iPhone Mirroring is not running. Open it, bring up the screen to capture, "
                    + "then run this again.\n", stderr)
                return 1
            }
            guard let capture = capture(
                name: config.name, bundleID: bundleID, probe: probe, environment: environment) else {
                fputs("iPhone Mirroring has no window to read.\n", stderr)
                return 1
            }
            return write(capture, in: config.outputDirectory) ? 0 : 1
        }

        var written: [MirroringAXWindow] = []
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            let name = "\(config.name)-\(written.count + 1)"
            if let capture = capture(name: name, bundleID: bundleID, probe: probe, environment: environment),
               written.last != capture.window {
                guard write(capture, in: config.outputDirectory) else { return 1 }
                written.append(capture.window)
            }
            Thread.sleep(forTimeInterval: watchPollInterval)
        }
        if written.isEmpty {
            fputs("No iPhone Mirroring window appeared in \(seconds) seconds.\n", stderr)
            return 1
        }
        return 0
    }

    /// One capture from `probe`: a single snapshot of the window, with the
    /// state and the move this binary reads from that same snapshot. Nil when
    /// the app is not running or exposes no window.
    static func capture(
        name: String, bundleID: String, probe: any MirroringSystemProbing,
        environment: AXCaptureEnvironment
    ) -> AXWindowCapture? {
        guard let pid = probe.processID(bundleID: bundleID),
              let window = probe.mainWindow(pid: pid) else { return nil }
        var frameAnswer: Bool?
        let state = MirroringWindowResolver.state(of: window) {
            let windowID = MirroringWindowResolver.windowInfo(
                pid: pid, axWindow: window, windowList: probe.windowList())?.windowID ?? 0
            let blank = probe.frameIsBlank(windowID: windowID)
            frameAnswer = blank
            return blank
        }
        let phrases = InterstitialPhrases(localize: { key in environment.strings[key].map { [$0] } ?? [] })
        let move = state == .paused
            ? SessionBlockClassifier.block(of: window, phrases: phrases).move : nil
        return AXWindowCapture(
            version: AXWindowCapture.currentVersion, name: name,
            macOSVersion: environment.macOSVersion, mirroringVersion: environment.mirroringVersion,
            localization: environment.localization, strings: environment.strings,
            state: state, move: move, frameIsBlank: frameAnswer, window: window)
    }

    /// Write `capture` and print what it holds, so the person sees the labels
    /// before committing them. Returns false when the file could not be written.
    private static func write(_ capture: AXWindowCapture, in directory: String) -> Bool {
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent(capture.name + AXWindowCapture.fileSuffix)
        do {
            try capture.write(to: url)
        } catch {
            fputs("Could not write \(url.path): \(error.localizedDescription)\n", stderr)
            return false
        }
        fputs("Wrote \(url.path): state \(capture.state.rawValue), "
            + "move \(capture.move?.rawValue ?? "none")\n", stderr)
        for label in capture.labels { fputs("  \"\(label)\"\n", stderr) }
        return true
    }

    /// The command's usage text.
    static var usage: String {
        """
        Usage: mirroir-mcp ax-capture <name> [--out <dir>] [--watch <seconds>]

        Writes what Accessibility reports for the iPhone Mirroring window right
        now as <dir>/<name>.axwindow.json: the tree the session-state check
        reads, tagged with the macOS version, the app version and the Mac's
        language. Read-only: nothing is pressed or typed.

        The labels it captured are printed. Read them before committing the
        file: a "Connecting to" screen names the iPhone.

        Options:
          --out <dir>        Directory to write to (default: the working directory)
          --watch <seconds>  Poll for that long and write one numbered file per
                             distinct window (<name>-1, <name>-2, ...), for
                             screens that pass too fast to catch by hand
          --help, -h         Show this help

        Examples:
          mirroir-mcp ax-capture connected --out Tests/Fixtures/mirroring-ax/macos-26.5-en
          mirroir-mcp ax-capture cold-launch --watch 30
        """
    }
}
