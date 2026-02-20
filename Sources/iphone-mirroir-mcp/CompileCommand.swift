// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI orchestration for the `compile` subcommand.
// ABOUTME: Runs scenarios against a real device, capturing coordinates and timing into compiled JSON.

import Foundation
import HelperLib

/// Orchestrates the `compile` subcommand: executes scenarios with a recording describer,
/// captures OCR coordinates and timing, and writes `.compiled.json` files.
///
/// Usage: `iphone-mirroir-mcp compile [options] <scenario...>`
enum CompileCommand {

    /// Parse arguments and run the compiler. Returns exit code (0 = success, 1 = error).
    static func run(arguments: [String]) -> Int32 {
        let config = parseArguments(arguments)

        if config.showHelp {
            printUsage()
            return 0
        }

        // Resolve scenario files
        let scenarioFiles: [String]
        do {
            scenarioFiles = try TestRunner.resolveScenarioFiles(config.scenarioArgs)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }

        if scenarioFiles.isEmpty {
            fputs("No scenarios found.\n", stderr)
            return 1
        }

        // Initialize subsystems
        let bridge = MirroringBridge()

        let state = bridge.getState()
        if state != .connected {
            fputs("Error: iPhone Mirroring is not connected (state: \(state))\n", stderr)
            fputs("Start iPhone Mirroring and connect your device before compiling.\n", stderr)
            return 1
        }

        guard let windowInfo = bridge.getWindowInfo() else {
            fputs("Error: Cannot find iPhone Mirroring window.\n", stderr)
            return 1
        }

        let capture = ScreenCapture(bridge: bridge)
        let input = InputSimulation(bridge: bridge)
        let realDescriber = ScreenDescriber(bridge: bridge)
        let recordingDescriber = RecordingDescriber(wrapping: realDescriber)

        let executorConfig = StepExecutorConfig(
            waitForTimeoutSeconds: config.timeoutSeconds,
            settlingDelayMs: 500,
            screenshotDir: NSTemporaryDirectory() + "mirroir-compile",
            dryRun: false
        )

        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: executorConfig
        )

        let windowWidth = Double(windowInfo.size.width)
        let windowHeight = Double(windowInfo.size.height)
        let orientation = bridge.getOrientation()?.rawValue ?? "portrait"

        fputs("mirroir compile: \(scenarioFiles.count) scenario(s) to compile\n", stderr)
        fputs("  Window: \(Int(windowWidth))x\(Int(windowHeight)) (\(orientation))\n\n", stderr)

        var anyFailed = false

        for filePath in scenarioFiles {
            let scenario: ScenarioDefinition
            do {
                scenario = try ScenarioParser.parse(filePath: filePath)
            } catch {
                fputs("Error parsing \(filePath): \(error.localizedDescription)\n", stderr)
                anyFailed = true
                continue
            }

            fputs("Compiling: \(scenario.name) (\(scenario.steps.count) steps)\n", stderr)

            let compiled = compileScenario(
                scenario: scenario,
                executor: executor,
                recordingDescriber: recordingDescriber,
                filePath: filePath,
                windowWidth: windowWidth,
                windowHeight: windowHeight,
                orientation: orientation
            )

            guard let compiled = compiled else {
                fputs("  FAIL: compilation aborted due to step failure\n", stderr)
                anyFailed = true
                continue
            }

            do {
                try CompiledScenarioIO.save(compiled, for: filePath)
                let outputPath = CompiledScenarioIO.compiledPath(for: filePath)
                let compiledSteps = compiled.steps.filter { $0.hints != nil }.count
                let passthroughSteps = compiled.steps.filter {
                    $0.hints?.compiledAction == .passthrough
                }.count
                fputs("  OK: \(compiledSteps) compiled, \(passthroughSteps) passthrough\n", stderr)
                fputs("  Output: \(outputPath)\n", stderr)
            } catch {
                fputs("  FAIL: \(error.localizedDescription)\n", stderr)
                anyFailed = true
            }
        }

        return anyFailed ? 1 : 0
    }

    /// Run a scenario with the recording describer and build a CompiledScenario.
    /// Returns nil if any step fails.
    static func compileScenario(
        scenario: ScenarioDefinition,
        executor: StepExecutor,
        recordingDescriber: RecordingDescriber,
        filePath: String,
        windowWidth: Double,
        windowHeight: Double,
        orientation: String
    ) -> CompiledScenario? {
        var compiledSteps: [CompiledStep] = []
        let sourceHash: String
        do {
            sourceHash = try CompiledScenarioIO.sha256(of: filePath)
        } catch {
            fputs("  Warning: cannot hash source file: \(error.localizedDescription)\n", stderr)
            sourceHash = ""
        }

        for (index, step) in scenario.steps.enumerated() {
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = executor.execute(step: step, stepIndex: index,
                                           scenarioName: scenario.name)

            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let statusTag = result.status == .passed ? "PASS" : result.status.rawValue

            fputs("  [\(index + 1)/\(scenario.steps.count)] \(step.displayName)  \(statusTag)\n", stderr)

            if result.status == .failed {
                fputs("    Error: \(result.message ?? "unknown")\n", stderr)
                return nil
            }

            let hints = buildHints(
                step: step,
                result: result,
                describer: recordingDescriber,
                elapsedMs: elapsedMs
            )

            compiledSteps.append(CompiledStep(
                index: index,
                type: step.typeKey,
                label: step.labelValue,
                hints: hints
            ))
        }

        let formatter = ISO8601DateFormatter()
        let compiledAt = formatter.string(from: Date())

        return CompiledScenario(
            version: CompiledScenario.currentVersion,
            source: SourceInfo(sha256: sourceHash, compiledAt: compiledAt),
            device: DeviceInfo(windowWidth: windowWidth, windowHeight: windowHeight,
                               orientation: orientation),
            steps: compiledSteps
        )
    }

    /// Build StepHints from the step execution result and the recording describer state.
    private static func buildHints(
        step: ScenarioStep,
        result: StepResult,
        describer: RecordingDescriber,
        elapsedMs: Int
    ) -> StepHints? {
        switch step {
        case .tap(let label):
            // Extract the tap coordinates from the describer's cached result
            if let lastResult = describer.lastResult,
               let match = ElementMatcher.findMatch(label: label, in: lastResult.elements) {
                return .tap(x: match.element.tapX, y: match.element.tapY,
                           confidence: match.element.confidence,
                           strategy: match.strategy.rawValue)
            }
            return .sleep(delayMs: elapsedMs)

        case .waitFor:
            return .sleep(delayMs: elapsedMs)

        case .assertVisible, .assertNotVisible:
            return .sleep(delayMs: elapsedMs)

        case .scrollTo(_, let direction, _):
            // Parse scroll count from result message (e.g. "found after 3 scroll(s)")
            let scrollCount = parseScrollCount(from: result.message)
            return .scrollSequence(count: scrollCount, direction: direction)

        case .measure:
            // Measure steps compile the observed total time as a sleep
            return .sleep(delayMs: elapsedMs)

        case .skipped:
            // AI-only steps cannot be compiled
            return nil

        // Steps that are already OCR-free
        case .launch, .type, .pressKey, .swipe, .home, .openURL, .shake,
             .resetApp, .setNetwork, .screenshot, .switchTarget:
            return .passthrough()
        }
    }

    /// Extract scroll count from a result message like "found after 3 scroll(s)".
    private static func parseScrollCount(from message: String?) -> Int {
        guard let message = message else { return 0 }
        if message == "already visible" { return 0 }
        // Match "found after N scroll(s)" or "N scroll(s)"
        let pattern = #"(\d+)\s+scroll"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message,
                                            range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else {
            return 0
        }
        return Int(message[range]) ?? 0
    }

    // MARK: - Argument Parsing

    struct CompileConfig {
        let scenarioArgs: [String]
        let timeoutSeconds: Int
        let showHelp: Bool
    }

    static func parseArguments(_ args: [String]) -> CompileConfig {
        var scenarioArgs: [String] = []
        var timeoutSeconds = EnvConfig.waitForTimeoutSeconds
        var showHelp = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                showHelp = true
            case "--timeout":
                i += 1
                if i < args.count, let t = Int(args[i]) { timeoutSeconds = t }
            default:
                if !arg.hasPrefix("-") {
                    scenarioArgs.append(arg)
                }
            }
            i += 1
        }

        return CompileConfig(
            scenarioArgs: scenarioArgs,
            timeoutSeconds: timeoutSeconds,
            showHelp: showHelp
        )
    }

    static func printUsage() {
        let usage = """
        Usage: iphone-mirroir-mcp compile [options] <scenario...>

        Run scenarios against a real device to capture coordinates and timing.
        Produces .compiled.json files for OCR-free replay via `test`.

        Arguments:
          <scenario>          Scenario name or .yaml file path (multiple allowed)

        Options:
          --timeout <sec>     wait_for timeout in seconds (default: 15)
          --help, -h          Show this help

        Examples:
          iphone-mirroir-mcp compile apps/settings/check-about
          iphone-mirroir-mcp compile check-about settings-wifi
          iphone-mirroir-mcp compile apps/settings/*.yaml
        """
        fputs(usage + "\n", stderr)
    }
}
