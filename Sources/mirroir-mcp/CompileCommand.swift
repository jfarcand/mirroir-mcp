// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI orchestration for the `compile` subcommand.
// ABOUTME: Runs skills against a real device, capturing coordinates and timing into compiled JSON.

import Foundation
import HelperLib

/// Orchestrates the `compile` subcommand: executes skills with a recording describer,
/// captures OCR coordinates and timing, and writes `.compiled.json` files.
///
/// Usage: `mirroir-mcp compile [options] <skill...>`
enum CompileCommand {

    /// Whether `skill` is a SKILL.md holding a tap recorded by coordinates alone (an icon
    /// with no text): a live run cannot find it, so it is recompiled only through an MCP
    /// client.
    static func hasCoordinateOnlyTap(_ skill: SkillDefinition) -> Bool {
        skill.filePath.hasSuffix(".md") && skill.steps.contains {
            if case .tap(let label) = $0 { return label.isEmpty }
            return false
        }
    }

    /// The resolved skill files `mirroir compile` compiles: every file named by path or
    /// skill name, and of the rest (found by discovery or a glob) only YAML skills whose
    /// compiled file is not their SKILL.md twin's.
    /// Each file left out is reported with its reason.
    static func filesToCompile(_ resolved: [String], named: Set<String>) -> [String] {
        resolved.filter { path in
            if named.contains(path) { return true }
            if path.hasSuffix(".md") {
                fputs("Skipping \(path): a SKILL.md is recompiled only when named\n", stderr)
                return false
            }
            if let owner = CompiledSkillIO.skillMdTwinOwningCompiledFile(for: path) {
                fputs("Skipping \(path): \(CompiledSkillIO.compiledPath(for: path)) holds the "
                    + "recorded steps of \(owner)\n", stderr)
                return false
            }
            return true
        }
    }

    /// Parse arguments and run the compiler. Returns exit code (0 = success, 1 = error).
    static func run(arguments: [String]) -> Int32 {
        let config = parseArguments(arguments)

        if config.showHelp {
            printUsage()
            return 0
        }

        // Resolve skill files
        let skillFiles: [String]
        do {
            // A SKILL.md is recompiled only when named (not found by discovery or a
            // glob): its steps come from what an AI recorded (a coordinate tap on an
            // icon, say), which a live OCR run may not find again. Nor is a YAML skill
            // whose compiled file holds its SKILL.md twin's steps, which compiling would
            // overwrite, unless named: it is then refused below with that reason.
            let resolved = try TestRunner.resolveSkillFiles(config.skillArgs)
            var named = Set<String>()
            for arg in config.skillArgs where !arg.contains("*") {
                named.formUnion(try TestRunner.resolveSkillFiles([arg]))
            }
            skillFiles = filesToCompile(resolved, named: named)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }

        if skillFiles.isEmpty {
            fputs("No skills found.\n", stderr)
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

        guard let device = deviceInfo(of: bridge) else {
            fputs("Error: Cannot find iPhone Mirroring window.\n", stderr)
            return 1
        }

        let capture = ScreenCapture(bridge: bridge)
        let realDescriber = ScreenDescriber(bridge: bridge, capture: capture)
        let input = InputSimulation(bridge: bridge, pasteVerifier: realDescriber)
        let recordingDescriber = RecordingDescriber(wrapping: realDescriber)

        let executorConfig = StepExecutorConfig(
            waitForTimeoutSeconds: config.timeoutSeconds,
            settlingDelayMs: 500,
            screenshotDir: NSTemporaryDirectory() + "mirroir-compile",
            dryRun: false
        )

        // The registry resolves `target:` steps; without it the first one fails.
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: recordingDescriber, capture: capture,
            config: executorConfig,
            registry: MirroirMCP.buildTargetRegistry()
        )

        let windowWidth = device.windowWidth
        let windowHeight = device.windowHeight
        let orientation = device.orientation

        fputs("mirroir compile: \(skillFiles.count) skill(s) to compile\n", stderr)
        fputs("  Window: \(Int(windowWidth))x\(Int(windowHeight)) (\(orientation))\n\n", stderr)

        var anyFailed = false

        for filePath in skillFiles {
            let skill: SkillDefinition
            do {
                skill = try SkillFileLoader.load(filePath: filePath)
            } catch {
                fputs("Error loading \(filePath): \(error.localizedDescription)\n", stderr)
                anyFailed = true
                continue
            }

            if skill.kind == "game" {
                fputs("Skipping \(skill.name): kind:game is model-interpreted — "
                    + "never compiled to a .compiled.json.\n", stderr)
                continue
            }

            if hasCoordinateOnlyTap(skill) {
                fputs("Refusing to compile \(filePath): it has a tap recorded by coordinates, "
                    + "which a live run cannot find; recompile it through an MCP client.\n", stderr)
                anyFailed = true
                continue
            }

            // A YAML skill and a SKILL.md of the same stem share one compiled file, and
            // for the SKILL.md it holds the only replayable copy of its steps.
            if let owner = CompiledSkillIO.skillMdTwinOwningCompiledFile(for: filePath) {
                fputs("Refusing to compile \(filePath): \(CompiledSkillIO.compiledPath(for: filePath)) "
                    + "holds the recorded steps of \(owner), which it would overwrite.\n", stderr)
                anyFailed = true
                continue
            }

            fputs("Compiling: \(skill.name) (\(skill.steps.count) steps)\n", stderr)

            let compiled = compileSkill(
                skill: skill,
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
                try CompiledSkillIO.save(compiled, for: filePath)
                let outputPath = CompiledSkillIO.compiledPath(for: filePath)
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

    /// Run a skill with the recording describer and build a CompiledSkill.
    /// Returns nil if any step fails.
    static func compileSkill(
        skill: SkillDefinition,
        executor: StepExecutor,
        recordingDescriber: RecordingDescriber,
        filePath: String,
        windowWidth: Double,
        windowHeight: Double,
        orientation: String
    ) -> CompiledSkill? {
        var compiledSteps: [CompiledStep] = []
        let sourceHash: String
        do {
            sourceHash = try CompiledSkillIO.sha256(of: filePath)
        } catch {
            fputs("  Warning: cannot hash source file: \(error.localizedDescription)\n", stderr)
            sourceHash = ""
        }

        let labelSteps = labelSteps(for: skill)

        // The screen the skill starts from, read before its first step runs: the one
        // moment every producer of a compiled skill fingerprints.
        let fingerprint = screenFingerprint(describer: recordingDescriber)

        for (index, step) in skill.steps.enumerated() {
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = executor.execute(step: step, stepIndex: index,
                                           skillName: skill.name)

            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let statusTag = result.status == .passed ? "PASS" : result.status.rawValue

            fputs("  [\(index + 1)/\(skill.steps.count)] \(step.displayName)  \(statusTag)\n", stderr)

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
                label: compiledLabel(labelSteps[index]),
                hints: hints
            ))
        }

        let formatter = ISO8601DateFormatter()
        let compiledAt = formatter.string(from: Date())

        return CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: sourceHash, compiledAt: compiledAt),
            device: DeviceInfo(windowWidth: windowWidth, windowHeight: windowHeight,
                               orientation: orientation),
            steps: compiledSteps,
            screenFingerprint: fingerprint
        )
    }

    /// The steps a compiled skill takes its labels from: `skill`'s own, re-read from
    /// its file with `${VAR}` placeholders unresolved, so a value such as a password
    /// never lands in the compiled file. The resolved steps stand in when the re-read
    /// fails or disagrees on the step count.
    static func labelSteps(for skill: SkillDefinition) -> [SkillStep] {
        let placeholderSteps = (try? SkillFileLoader.load(
            filePath: skill.filePath, substitutingEnv: false))?.steps
        return placeholderSteps?.count == skill.steps.count
            ? placeholderSteps ?? skill.steps : skill.steps
    }

    /// The label a compiled step records: its replay value. A value no replay form
    /// carries (one holding both quote characters) keeps at least its element text,
    /// with its placeholders.
    static func compiledLabel(_ step: SkillStep) -> String? {
        step.replayValue ?? step.labelValue
    }

    /// The window a compiled skill is recorded in, or nil when the bridge finds no window.
    static func deviceInfo(of bridge: any WindowBridging) -> DeviceInfo? {
        guard let window = bridge.getWindowInfo() else { return nil }
        return DeviceInfo(
            windowWidth: Double(window.size.width),
            windowHeight: Double(window.size.height),
            orientation: bridge.getOrientation()?.rawValue ?? "portrait")
    }

    /// Fingerprint of the screen `describer` shows now, or nil when it reads nothing.
    static func screenFingerprint(describer: ScreenDescribing) -> ScreenFingerprint? {
        guard let screen = describer.describe() else { return nil }
        return StructuralFingerprint.buildScreenFingerprint(
            elements: screen.elements, icons: screen.icons)
    }

    /// Build StepHints from the step execution result and the recording describer state.
    private static func buildHints(
        step: SkillStep,
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
                           strategy: match.strategy.rawValue)
            }
            // No cached match: replay it live. A sleep would pass without tapping.
            return .passthrough()

        case .waitFor:
            // Replayed live: polls the screen until the element shows or its timeout
            // passes. A recorded delay would pass without looking.
            return .passthrough()

        case .assertVisible, .assertNotVisible:
            return .assertion(delayMs: elapsedMs)

        case .scrollTo(_, let direction, _):
            // Parse scroll count from result message (e.g. "found after 3 scroll(s)")
            let scrollCount = parseScrollCount(from: result.message)
            return .scrollSequence(count: scrollCount, direction: direction)

        case .measure:
            // Replayed live: a sleep would pass without running the action or the check.
            return .passthrough()

        case .skipped, .invalid:
            // AI-only steps cannot be compiled
            return nil

        case .longPress, .drag:
            // A compiled tap would replay a long press as a short tap, and a drag needs
            // two OCR lookups at runtime: both replay live through the normal executor.
            return .passthrough()

        // Steps with no screen lookup to pre-resolve: they replay live
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
        let skillArgs: [String]
        let timeoutSeconds: Int
        let showHelp: Bool
    }

    static func parseArguments(_ args: [String]) -> CompileConfig {
        var skillArgs: [String] = []
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
                    skillArgs.append(arg)
                }
            }
            i += 1
        }

        return CompileConfig(
            skillArgs: skillArgs,
            timeoutSeconds: timeoutSeconds,
            showHelp: showHelp
        )
    }

    static func printUsage() {
        let usage = """
        Usage: mirroir-mcp compile [options] <skill...>

        Run skills against a real device to capture coordinates and timing.
        Produces .compiled.json files that `test` replays without AI, verifying each step.

        Arguments:
          <skill>             Skill name or .yaml file path (multiple allowed)

        Options:
          --timeout <sec>     wait_for timeout in seconds (default: 15)
          --help, -h          Show this help

        Examples:
          mirroir-mcp compile apps/settings/check-about
          mirroir-mcp compile check-about settings-wifi
          mirroir-mcp compile apps/settings/*.yaml
        """
        fputs(usage + "\n", stderr)
    }
}
