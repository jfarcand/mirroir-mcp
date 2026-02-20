// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI orchestration for the `record` subcommand.
// ABOUTME: Captures user interactions with iPhone Mirroring and outputs scenario YAML.

import CoreGraphics
import Darwin
import Foundation

/// Global reference to the recording run loop, used by the SIGINT handler
/// (C function pointers cannot capture local variables).
nonisolated(unsafe) var recordingRunLoop: CFRunLoop?

/// Configuration parsed from `record` subcommand arguments.
struct RecordConfig {
    let outputPath: String
    let scenarioName: String
    let description: String
    let appName: String?
    let noOCR: Bool
    let showHelp: Bool
}

/// Orchestrates the `record` subcommand: installs a CGEvent tap, captures user
/// interactions with the iPhone Mirroring window, and writes scenario YAML on exit.
///
/// Usage: `iphone-mirroir-mcp record [options]`
enum RecordCommand {

    /// Parse arguments and run the recorder. Returns exit code (0 = success, 1 = error).
    static func run(arguments: [String]) -> Int32 {
        let config = parseArguments(arguments)

        if config.showHelp {
            printUsage()
            return 0
        }

        // Initialize subsystems
        let bridge = MirroringBridge()

        let state = bridge.getState()
        if state != .connected {
            fputs("Error: iPhone Mirroring is not connected (state: \(state))\n", stderr)
            fputs("Start iPhone Mirroring and connect your device before recording.\n", stderr)
            return 1
        }

        guard let info = bridge.getWindowInfo() else {
            fputs("Error: Cannot find iPhone Mirroring window.\n", stderr)
            return 1
        }

        let describer: ScreenDescribing? = config.noOCR
            ? nil
            : ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))

        let recorder = EventRecorder(bridge: bridge, describer: describer)

        fputs("mirroir record: Recording interactions on iPhone Mirroring window\n", stderr)
        fputs("  Window: \(Int(info.size.width))x\(Int(info.size.height)) at (\(Int(info.position.x)), \(Int(info.position.y)))\n", stderr)
        fputs("  Output: \(config.outputPath)\n", stderr)
        if config.noOCR {
            fputs("  OCR: disabled (taps will use coordinates only)\n", stderr)
        }
        fputs("  Press Ctrl+C to stop recording and save.\n\n", stderr)

        guard recorder.start() else {
            fputs("Error: Failed to create CGEvent tap.\n", stderr)
            fputs("Grant Accessibility permission: System Settings > Privacy & Security > Accessibility\n", stderr)
            return 1
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

        // Ctrl+C received — stop recording and generate YAML
        fputs("\n", stderr)
        let events = recorder.stop()

        if events.isEmpty {
            fputs("No interactions recorded.\n", stderr)
            return 0
        }

        fputs("Recorded \(events.count) interaction(s).\n", stderr)

        let yaml = YAMLGenerator.generate(
            events: events,
            name: config.scenarioName,
            description: config.description,
            appName: config.appName
        )

        // Write to stdout if output is "-", otherwise to file
        if config.outputPath == "-" {
            print(yaml, terminator: "")
        } else {
            do {
                try yaml.write(toFile: config.outputPath, atomically: true, encoding: .utf8)
                fputs("Scenario written to: \(config.outputPath)\n", stderr)
            } catch {
                fputs("Error writing file: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }

        return 0
    }

    // MARK: - Argument Parsing

    static func parseArguments(_ args: [String]) -> RecordConfig {
        var outputPath = "recorded-scenario.yaml"
        var scenarioName = "Recorded Scenario"
        var description = "Recorded from live interaction"
        var appName: String?
        var noOCR = false
        var showHelp = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                showHelp = true
            case "--output", "-o":
                i += 1
                if i < args.count { outputPath = args[i] }
            case "--name", "-n":
                i += 1
                if i < args.count { scenarioName = args[i] }
            case "--description":
                i += 1
                if i < args.count { description = args[i] }
            case "--app":
                i += 1
                if i < args.count { appName = args[i] }
            case "--no-ocr":
                noOCR = true
            default:
                break
            }
            i += 1
        }

        return RecordConfig(
            outputPath: outputPath,
            scenarioName: scenarioName,
            description: description,
            appName: appName,
            noOCR: noOCR,
            showHelp: showHelp
        )
    }

    static func printUsage() {
        let usage = """
        Usage: iphone-mirroir-mcp record [options]

        Record user interactions with iPhone Mirroring as a scenario YAML file.
        Captures taps, swipes, and keyboard input. Press Ctrl+C to stop.

        Options:
          --output, -o <path>    Output file path (default: recorded-scenario.yaml)
                                 Use "-" to write to stdout
          --name, -n <name>      Scenario name (default: "Recorded Scenario")
          --description <text>   Scenario description
          --app <name>           App name for the YAML header
          --no-ocr               Skip OCR label detection (faster, coordinates only)
          --help, -h             Show this help

        Examples:
          iphone-mirroir-mcp record -o login-flow.yaml -n "Login Flow" --app "MyApp"
          iphone-mirroir-mcp record --no-ocr -o quick-capture.yaml
          iphone-mirroir-mcp record -o - | tee scenario.yaml
        """
        fputs(usage + "\n", stderr)
    }
}
