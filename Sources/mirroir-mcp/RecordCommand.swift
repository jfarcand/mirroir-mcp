// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI orchestration for the `record` subcommand.
// ABOUTME: Records a walk on iPhone Mirroring (or loads a saved one) and emits it as a .mirroir/ ios scenario.

import CoreGraphics
import Darwin
import Foundation
import HelperLib

/// Global reference to the recording run loop, used by the SIGINT handler
/// (C function pointers cannot capture local variables).
nonisolated(unsafe) var recordingRunLoop: CFRunLoop?

/// Configuration parsed from `record` subcommand arguments.
struct RecordConfig: Equatable {
    /// Where the walk comes from.
    enum Source: Equatable {
        /// Record live on iPhone Mirroring, for `appName`, as flow `flowName`.
        case live(appName: String, flowName: String)
        /// Render a recording saved by an earlier live session; the file
        /// names its own app and flow.
        case savedRecording(path: String)
    }

    let source: Source
    /// Consumer repo root holding (or to hold) `.mirroir/`; nil resolves it
    /// from the working directory like `generate_skill`.
    let outputDir: String?
}

/// What a `record` command line asks for.
enum RecordInvocation: Equatable {
    case help
    case record(RecordConfig)
}

/// Command lines `record` refuses, each naming what to change.
enum RecordArgumentError: LocalizedError, Equatable {
    case missingValue(flag: String)
    case unknownArgument(String)
    case missingRequired(flags: [String])
    case noOCRUnsupported
    case conflictsWithSavedRecording(flags: [String])

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "\(flag) needs a value"
        case .unknownArgument(let arg):
            return "unknown argument \"\(arg)\""
        case .missingRequired(let flags):
            return "live recording requires \(flags.joined(separator: " and "))"
        case .noOCRUnsupported:
            return "--no-ocr is not supported: a walk recorded without OCR names no element " +
                "for any tap, and a scenario cannot replay an unnamed tap"
        case .conflictsWithSavedRecording(let flags):
            return "--from-recording cannot be combined with \(flags.joined(separator: ", ")): " +
                "the saved recording names its own app and flow"
        }
    }
}

/// Orchestrates the `record` subcommand: resets and launches the app, installs
/// a CGEvent tap, captures each interaction with the screen it acted on, saves
/// the session, and emits it into the consumer repo's `.mirroir/apps/<app>/`
/// tree through `MirroirAppTreeEmitter` — the same scenario `generate_skill`
/// writes.
///
/// Usage: `mirroir-mcp record --app <name> --name <flow> [--output-dir <repo>]`
/// or `mirroir-mcp record --from-recording <file> [--output-dir <repo>]`.
enum RecordCommand {

    /// Directory under the global `~/.mirroir-mcp/` home holding saved recordings.
    static let recordingsDirName = "recordings"

    /// Parse arguments and run the recorder. Returns exit code (0 = success, 1 = error).
    static func run(arguments: [String]) -> Int32 {
        let invocation: RecordInvocation
        do {
            invocation = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n\n", stderr)
            printUsage()
            return 1
        }
        guard case .record(let config) = invocation else {
            printUsage()
            return 0
        }

        switch config.source {
        case .savedRecording(let path):
            let recording: Recording
            do {
                recording = try Recording.load(path: path)
            } catch {
                fputs("Error reading recording \(path): \(error.localizedDescription)\n", stderr)
                return 1
            }
            return emit(recording, outputDir: config.outputDir, savedAt: path)
        case .live(let appName, let flowName):
            guard let recording = recordLive(appName: appName, flowName: flowName) else {
                return 1
            }
            let path = recordingPath(appName: appName, flowName: flowName)
            do {
                try recording.write(to: path)
            } catch {
                fputs("Error saving recording to \(path.path): \(error.localizedDescription)\n", stderr)
                return 1
            }
            fputs("Recording saved to: \(path.path)\n", stderr)
            return emit(recording, outputDir: config.outputDir, savedAt: path.path)
        }
    }

    /// Where a live session for `appName`/`flowName` is saved:
    /// `~/.mirroir-mcp/recordings/<app-slug>/<flow-slug>.recording.json`.
    static func recordingPath(appName: String, flowName: String) -> URL {
        URL(fileURLWithPath: PermissionPolicy.globalConfigDir, isDirectory: true)
            .appendingPathComponent(recordingsDirName, isDirectory: true)
            .appendingPathComponent(MirroirAppTreeEmitter.slugify(appName), isDirectory: true)
            .appendingPathComponent(MirroirAppTreeEmitter.slugify(flowName) + Recording.fileSuffix)
    }

    // MARK: - Emit

    /// Emit `recording` into the `.mirroir/` tree and report the written
    /// paths. A refused emit prints why and where the recording is kept, so
    /// the session can be re-rendered with `--from-recording`.
    private static func emit(_ recording: Recording, outputDir: String?, savedAt: String) -> Int32 {
        do {
            let note = try ExplorationLoopRunner.emitNote(
                appName: recording.appName,
                flows: [RecordingWalk.flow(from: recording)],
                outputDir: outputDir)
            fputs(note.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", stderr)
            return 0
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            fputs("The recording is kept at: \(savedAt)\n", stderr)
            return 1
        }
    }

    // MARK: - Live Recording

    /// Reset and launch `appName` so the walk starts where its replay starts,
    /// record until Ctrl+C, and read the final screen. Nil (after printing
    /// why) when the device is not ready, the app cannot start, nothing was
    /// recorded, or the final screen could not be read.
    private static func recordLive(appName: String, flowName: String) -> Recording? {
        let bridge = MirroringBridge()

        // A paused session is freed first, the way every MCP input tool does.
        if let refusal = IPhoneMirroringTarget.input(bridge: bridge).ensureConnected(tag: "record") {
            fputs("Error: \(refusal)\n", stderr)
            fputs("Start iPhone Mirroring and connect your device before recording.\n", stderr)
            return nil
        }

        guard let info = bridge.getWindowInfo() else {
            fputs("Error: Cannot find iPhone Mirroring window.\n", stderr)
            return nil
        }

        let capture = ScreenCapture(bridge: bridge)
        let describer = ScreenDescriber(
            bridge: bridge, capture: capture, textRecognizer: MirroirMCP.buildTextRecognizer())
        guard startApp(appName, bridge: bridge, describer: describer, capture: capture) else {
            return nil
        }

        let recorder = EventRecorder(bridge: bridge, describer: describer)

        fputs("mirroir record: Recording \(flowName) on \(appName)\n", stderr)
        fputs("  Window: \(Int(info.size.width))x\(Int(info.size.height)) at (\(Int(info.position.x)), \(Int(info.position.y)))\n", stderr)
        fputs("  Press Ctrl+C to stop recording and save.\n\n", stderr)

        guard recorder.start() else {
            fputs("Error: Failed to create CGEvent tap.\n", stderr)
            fputs("Grant Accessibility permission: System Settings > Privacy & Security > Accessibility\n", stderr)
            return nil
        }

        // Install SIGINT handler to stop the run loop gracefully.
        // Store the run loop reference in a global so the C callback can access it
        // (C function pointers cannot capture context).
        recordingRunLoop = CFRunLoopGetCurrent()
        signal(SIGINT) { _ in
            if let rl = recordingRunLoop {
                CFRunLoopStop(rl)
            }
        }

        // Run the event loop until Ctrl+C
        CFRunLoopRun()

        fputs("\n", stderr)
        let (steps, finalScreen) = recorder.stop()

        if steps.isEmpty {
            fputs("No interactions recorded; nothing saved or emitted.\n", stderr)
            return nil
        }
        guard let finalScreen else {
            fputs("Error: could not read the final screen after \(steps.count) interaction(s); "
                + "the scenario's closing assertion needs it, so nothing was saved.\n", stderr)
            return nil
        }

        fputs("Recorded \(steps.count) interaction(s).\n", stderr)
        return Recording(appName: appName, flowName: flowName, steps: steps, finalScreen: finalScreen)
    }

    /// Run the scenario's opening `reset_app` then `launch` on the device.
    /// False (after printing the failing step) when either fails.
    private static func startApp(
        _ appName: String, bridge: MirroringBridge,
        describer: ScreenDescriber, capture: ScreenCapture
    ) -> Bool {
        let executor = StepExecutor(
            bridge: bridge,
            input: FocusObservingInput(
                wrapping: IPhoneMirroringTarget.input(bridge: bridge, pasteVerifier: describer),
                bridge: bridge),
            describer: describer, capture: capture,
            config: .default)
        let opening: [SkillStep] = [.resetApp(appName: appName), .launch(appName: appName)]
        for (index, step) in opening.enumerated() {
            let result = executor.execute(step: step, stepIndex: index, skillName: appName)
            guard result.status == .passed else {
                fputs("Error: \(step.typeKey) \(appName) failed before recording: "
                    + "\(result.message ?? result.status.rawValue)\n", stderr)
                return false
            }
        }
        return true
    }

    // MARK: - Argument Parsing

    /// Parse a `record` command line.
    ///
    /// - Throws: `RecordArgumentError` for an unknown argument, a flag with
    ///   no value, `--no-ocr`, a live recording missing `--app` or `--name`,
    ///   or `--from-recording` alongside either.
    static func parseArguments(_ args: [String]) throws -> RecordInvocation {
        var appName: String?
        var flowName: String?
        var outputDir: String?
        var fromRecording: String?

        var i = 0
        func value(for flag: String) throws -> String {
            i += 1
            guard i < args.count, !args[i].isEmpty else {
                throw RecordArgumentError.missingValue(flag: flag)
            }
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                return .help
            case "--app":
                appName = try value(for: arg)
            case "--name":
                flowName = try value(for: arg)
            case "--output-dir":
                outputDir = try value(for: arg)
            case "--from-recording":
                fromRecording = try value(for: arg)
            case "--no-ocr":
                throw RecordArgumentError.noOCRUnsupported
            default:
                throw RecordArgumentError.unknownArgument(arg)
            }
            i += 1
        }

        if let fromRecording {
            let conflicts = [("--app", appName), ("--name", flowName)]
                .filter { $0.1 != nil }.map(\.0)
            guard conflicts.isEmpty else {
                throw RecordArgumentError.conflictsWithSavedRecording(flags: conflicts)
            }
            return .record(RecordConfig(source: .savedRecording(path: fromRecording), outputDir: outputDir))
        }
        guard let appName, let flowName else {
            let missing = [("--app", appName), ("--name", flowName)]
                .filter { $0.1 == nil }.map(\.0)
            throw RecordArgumentError.missingRequired(flags: missing)
        }
        return .record(RecordConfig(
            source: .live(appName: appName, flowName: flowName), outputDir: outputDir))
    }

    static func printUsage() {
        let usage = """
        Usage: mirroir-mcp record --app <name> --name <flow> [--output-dir <repo>]
               mirroir-mcp record --from-recording <file> [--output-dir <repo>]

        Record a walk on iPhone Mirroring and emit it as a replayable ios scenario
        in the consumer repo's .mirroir/apps/<app>/ tree — the same scenario
        generate_skill writes. The app is reset and launched first, so the walk
        starts where its replay starts. Captures taps, long presses, swipes and
        keyboard input, each with the OCR text of the screen it acted on.
        Press Ctrl+C to stop.

        Every session is saved to
        ~/.mirroir-mcp/recordings/<app>/<flow>.recording.json first, so a
        refused emit (a tap OCR could not name, say) loses nothing.

        Options:
          --app <name>             App to record (required for a live recording)
          --name <flow>            Flow name; its slug names the scenario file
                                   (required for a live recording)
          --output-dir <repo>      Consumer repo root; the scenario lands in
                                   <repo>/.mirroir/apps/<app>/scenarios/
                                   (default: nearest .mirroir/ above the cwd)
          --from-recording <file>  Emit a saved recording without the device
                                   (the file names its own app and flow)
          --help, -h               Show this help

        Examples:
          mirroir-mcp record --app Calculator --name calculator-add --output-dir .
          mirroir-mcp record --from-recording ~/.mirroir-mcp/recordings/calculator/calculator-add.recording.json
        """
        fputs(usage + "\n", stderr)
    }
}
