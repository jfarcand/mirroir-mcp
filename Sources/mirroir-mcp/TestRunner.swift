// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Top-level orchestrator for the `mirroir test` CLI subcommand.
// ABOUTME: Parses CLI args, discovers skills, executes them, and reports results.

import Darwin
import Foundation
import HelperLib

/// Configuration parsed from CLI arguments.
struct TestRunConfig {
    let skillArgs: [String]
    let junitPath: String?
    let screenshotDir: String
    let timeoutSeconds: Int
    let verbose: Bool
    let dryRun: Bool
    let noCompiled: Bool
    /// Agent mode: nil = no agent, "" = deterministic only, non-empty = AI model name.
    let agent: String?
    let showHelp: Bool
}

/// Orchestrates skill test execution from the CLI.
enum TestRunner {

    /// Parse CLI arguments and run tests. Returns exit code (0 = all pass, 1 = any fail).
    static func run(arguments: [String]) -> Int32 {
        let config = parseArguments(arguments)

        if config.showHelp {
            printUsage()
            return 0
        }

        // Resolve skill files
        let skillFiles: [String]
        do {
            skillFiles = try resolveSkillFiles(config.skillArgs)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }

        if skillFiles.isEmpty {
            fputs("No skills found.\n", stderr)
            fputs("Place .yaml files in .mirroir-mcp/skills/ or specify paths.\n", stderr)
            return 1
        }

        fputs("mirroir test: \(skillFiles.count) skill(s) to run\n", stderr)

        // Parse all skills upfront to catch errors early
        var skills: [SkillDefinition] = []
        for filePath in skillFiles {
            do {
                let skill = try SkillParser.parse(filePath: filePath)
                skills.append(skill)
            } catch {
                fputs("Error parsing \(filePath): \(error.localizedDescription)\n", stderr)
                return 1
            }
        }

        // Initialize subsystems (skip for dry run — no system access needed)
        let bridge = MirroringBridge()
        let capture = ScreenCapture(bridge: bridge)
        let input = InputSimulation(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge, capture: capture)

        // Pre-flight check: verify mirroring is connected (unless dry run)
        if !config.dryRun {
            let state = bridge.getState()
            if state != .connected {
                fputs("Error: iPhone Mirroring is not connected (state: \(state))\n", stderr)
                fputs("Start iPhone Mirroring and connect your device before running tests.\n", stderr)
                return 1
            }
        }

        let executorConfig = StepExecutorConfig(
            waitForTimeoutSeconds: config.timeoutSeconds,
            settlingDelayMs: 500,
            screenshotDir: config.screenshotDir,
            dryRun: config.dryRun
        )

        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: executorConfig
        )

        // Load compiled skills if available
        let windowInfo = bridge.getWindowInfo()
        var compiledMap: [String: CompiledSkill] = [:]
        if !config.noCompiled {
            let windowWidth = windowInfo.map { Double($0.size.width) } ?? 0
            let windowHeight = windowInfo.map { Double($0.size.height) } ?? 0
            for skill in skills {
                if let compiled = try? CompiledSkillIO.load(for: skill.filePath) {
                    let staleness = CompiledSkillIO.checkStaleness(
                        compiled: compiled, skillPath: skill.filePath,
                        windowWidth: windowWidth, windowHeight: windowHeight)
                    switch staleness {
                    case .fresh:
                        compiledMap[skill.filePath] = compiled
                    case .stale(let reason):
                        fputs("Warning: compiled skill stale for \(skill.name): \(reason)\n", stderr)
                    }
                }
            }
        }

        // Execute skills
        var allResults: [ConsoleReporter.SkillResult] = []
        var totalCompiledSteps = 0
        var totalNormalSteps = 0

        for skill in skills {
            let result: ConsoleReporter.SkillResult
            if let compiled = compiledMap[skill.filePath] {
                let compiledExecutor = CompiledStepExecutor(
                    bridge: bridge, input: input,
                    describer: describer, capture: capture,
                    config: executorConfig
                )
                result = executeCompiledSkill(
                    skill: skill, compiled: compiled,
                    compiledExecutor: compiledExecutor,
                    normalExecutor: executor,
                    describer: describer, agent: config.agent,
                    verbose: config.verbose)
                totalCompiledSteps += compiled.steps.filter {
                    $0.hints?.compiledAction != .passthrough
                }.count
                totalNormalSteps += compiled.steps.filter {
                    $0.hints?.compiledAction == .passthrough || $0.hints == nil
                }.count
            } else {
                result = executeSkill(skill: skill, executor: executor,
                                      verbose: config.verbose)
                totalNormalSteps += skill.steps.count
            }
            allResults.append(result)
        }

        if totalCompiledSteps > 0 {
            fputs("\nCompiled: \(totalCompiledSteps) step(s) OCR-free, \(totalNormalSteps) normal\n", stderr)
        }

        // Print summary
        ConsoleReporter.reportSummary(results: allResults)

        // Write JUnit XML if requested
        if let junitPath = config.junitPath {
            do {
                try JUnitReporter.writeXML(results: allResults, to: junitPath)
                fputs("\nJUnit XML written to: \(junitPath)\n", stderr)
            } catch {
                fputs("\nWarning: Failed to write JUnit XML: \(error.localizedDescription)\n", stderr)
            }
        }

        // Exit code
        let anyFailed = allResults.contains { result in
            result.stepResults.contains { $0.status == .failed }
        }
        return anyFailed ? 1 : 0
    }

    /// Execute a single skill and return results.
    static func executeSkill(skill: SkillDefinition,
                             executor: StepExecutor,
                             verbose: Bool) -> ConsoleReporter.SkillResult {
        let stepCount = skill.steps.count
        ConsoleReporter.reportSkillStart(
            name: skill.name, filePath: skill.filePath, stepCount: stepCount)

        let startTime = CFAbsoluteTimeGetCurrent()
        var stepResults: [StepResult] = []
        var stopOnFailure = false

        for (index, step) in skill.steps.enumerated() {
            if stopOnFailure {
                // Skip remaining steps after a failure
                let skippedResult = StepResult(
                    step: step, status: .skipped,
                    message: "Skipped due to previous failure",
                    durationSeconds: 0)
                stepResults.append(skippedResult)
                ConsoleReporter.reportStep(index: index, total: stepCount,
                                           result: skippedResult, verbose: verbose)
                continue
            }

            let result = executor.execute(step: step, stepIndex: index,
                                          skillName: skill.name)
            stepResults.append(result)
            ConsoleReporter.reportStep(index: index, total: stepCount,
                                       result: result, verbose: verbose)

            if result.status == .failed {
                stopOnFailure = true
            }
        }

        let totalDuration = CFAbsoluteTimeGetCurrent() - startTime
        let skillResult = ConsoleReporter.SkillResult(
            name: skill.name,
            filePath: skill.filePath,
            stepResults: stepResults,
            durationSeconds: totalDuration
        )
        ConsoleReporter.reportSkillEnd(result: skillResult)
        return skillResult
    }

    /// Execute a skill using compiled hints for OCR-free replay.
    /// When `agent` is non-nil, failed steps trigger a diagnostic OCR call.
    /// When `agent` is a non-empty model name, AI diagnosis runs after deterministic analysis.
    static func executeCompiledSkill(
        skill: SkillDefinition,
        compiled: CompiledSkill,
        compiledExecutor: CompiledStepExecutor,
        normalExecutor: StepExecutor,
        describer: ScreenDescribing,
        agent: String?,
        verbose: Bool
    ) -> ConsoleReporter.SkillResult {
        let agentEnabled = agent != nil
        let stepCount = skill.steps.count
        let tag: String
        if let modelName = agent, !modelName.isEmpty {
            tag = " [compiled+agent:\(modelName)]"
        } else if agentEnabled {
            tag = " [compiled+agent]"
        } else {
            tag = " [compiled]"
        }
        ConsoleReporter.reportSkillStart(
            name: skill.name + tag,
            filePath: skill.filePath, stepCount: stepCount)

        let startTime = CFAbsoluteTimeGetCurrent()
        var stepResults: [StepResult] = []
        var stopOnFailure = false
        var recommendations: [AgentDiagnostic.Recommendation] = []

        for (index, step) in skill.steps.enumerated() {
            if stopOnFailure {
                let skippedResult = StepResult(
                    step: step, status: .skipped,
                    message: "Skipped due to previous failure",
                    durationSeconds: 0)
                stepResults.append(skippedResult)
                ConsoleReporter.reportStep(index: index, total: stepCount,
                                           result: skippedResult, verbose: verbose)
                continue
            }

            let result: StepResult
            if index < compiled.steps.count {
                let compiledStep = compiled.steps[index]
                result = compiledExecutor.execute(
                    step: step, compiledStep: compiledStep,
                    stepIndex: index, skillName: skill.name)

                // Agent diagnostic on failure
                if agentEnabled && result.status == .failed {
                    if let rec = AgentDiagnostic.diagnose(
                        step: step, compiledStep: compiledStep,
                        failureMessage: result.message, describer: describer) {
                        recommendations.append(rec)
                    }
                }
            } else {
                result = normalExecutor.execute(
                    step: step, stepIndex: index, skillName: skill.name)

                // Agent diagnostic on normal step failure within a compiled skill
                if agentEnabled && result.status == .failed {
                    let synthStep = CompiledStep(
                        index: index, type: step.typeKey,
                        label: step.labelValue,
                        hints: StepHints.passthrough())
                    if let rec = AgentDiagnostic.diagnose(
                        step: step, compiledStep: synthStep,
                        failureMessage: result.message, describer: describer) {
                        recommendations.append(rec)
                    }
                }
            }

            stepResults.append(result)
            ConsoleReporter.reportStep(index: index, total: stepCount,
                                       result: result, verbose: verbose)

            if result.status == .failed {
                stopOnFailure = true
            }
        }

        // Print deterministic diagnostic report
        if agentEnabled && !recommendations.isEmpty {
            AgentDiagnostic.printReport(recommendations: recommendations,
                                         skillName: skill.name)
        }

        // Run AI diagnosis if a model name was specified
        if let modelName = agent, !modelName.isEmpty, !recommendations.isEmpty {
            runAIDiagnosis(
                modelName: modelName,
                recommendations: recommendations,
                skillName: skill.name,
                skillFilePath: skill.filePath)
        }

        let totalDuration = CFAbsoluteTimeGetCurrent() - startTime
        let skillResult = ConsoleReporter.SkillResult(
            name: skill.name,
            filePath: skill.filePath,
            stepResults: stepResults,
            durationSeconds: totalDuration
        )
        ConsoleReporter.reportSkillEnd(result: skillResult)
        return skillResult
    }

    /// Resolve and invoke the AI agent for diagnosis. Errors are non-fatal warnings.
    private static func runAIDiagnosis(
        modelName: String,
        recommendations: [AgentDiagnostic.Recommendation],
        skillName: String,
        skillFilePath: String
    ) {
        guard let agentConfig = AIAgentRegistry.resolve(name: modelName) else {
            let available = AIAgentRegistry.availableAgents().joined(separator: ", ")
            fputs("Error: Unknown agent '\(modelName)'. Available: \(available)\n", stderr)
            return
        }

        guard let provider = AIAgentRegistry.createProvider(config: agentConfig) else {
            fputs("Warning: Could not create provider for agent '\(modelName)'\n", stderr)
            return
        }

        let payload = AgentDiagnostic.buildPayload(
            recommendations: recommendations,
            skillName: skillName,
            skillFilePath: skillFilePath)

        if let diagnosis = provider.diagnose(payload: payload) {
            AgentDiagnostic.printAIReport(diagnosis: diagnosis, skillName: skillName)
        }
    }

    // MARK: - Argument Parsing

    /// Parse CLI arguments into TestRunConfig.
    static func parseArguments(_ args: [String]) -> TestRunConfig {
        var skillArgs: [String] = []
        var junitPath: String?
        var screenshotDir = "./mirroir-test-results"
        var timeoutSeconds = EnvConfig.waitForTimeoutSeconds
        var verbose = false
        var dryRun = false
        var noCompiled = false
        var agent: String?
        var showHelp = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                showHelp = true
            case "--junit":
                i += 1
                if i < args.count { junitPath = args[i] }
            case "--screenshot-dir":
                i += 1
                if i < args.count { screenshotDir = args[i] }
            case "--timeout":
                i += 1
                if i < args.count, let t = Int(args[i]) { timeoutSeconds = t }
            case "--verbose", "-v":
                verbose = true
            case "--dry-run":
                dryRun = true
            case "--no-compiled":
                noCompiled = true
            case "--agent":
                // Peek-ahead: if next arg doesn't start with "-" and isn't a .yaml path,
                // consume it as the model name. Otherwise, bare --agent = deterministic only.
                if i + 1 < args.count {
                    let next = args[i + 1]
                    if !next.hasPrefix("-") && !next.hasSuffix(".yaml") && !next.hasSuffix(".yml") {
                        agent = next
                        i += 1
                    } else {
                        agent = ""
                    }
                } else {
                    agent = ""
                }
            default:
                if !arg.hasPrefix("-") {
                    skillArgs.append(arg)
                }
            }
            i += 1
        }

        return TestRunConfig(
            skillArgs: skillArgs,
            junitPath: junitPath,
            screenshotDir: screenshotDir,
            timeoutSeconds: timeoutSeconds,
            verbose: verbose,
            dryRun: dryRun,
            noCompiled: noCompiled,
            agent: agent,
            showHelp: showHelp
        )
    }

    /// Resolve skill arguments to file paths.
    /// If no args given, discovers all skills from default directories.
    static func resolveSkillFiles(_ args: [String]) throws -> [String] {
        if args.isEmpty {
            // Discover all skills from skill directories
            return discoverAllSkillFiles()
        }

        var files: [String] = []
        let dirs = PermissionPolicy.skillDirs

        for arg in args {
            // Check if it's a direct file path
            if FileManager.default.fileExists(atPath: arg) {
                files.append(arg)
                continue
            }

            // Check if it's a glob pattern (contains *)
            if arg.contains("*") {
                let expanded = expandGlob(arg)
                if expanded.isEmpty {
                    throw TestRunnerError.noSkillsFound(pattern: arg)
                }
                files.append(contentsOf: expanded)
                continue
            }

            // Try to resolve as skill name (yamlOnly: deterministic runner needs YAML)
            let (path, ambiguous) = MirroirMCP.resolveSkill(
                name: arg, dirs: dirs, yamlOnly: true)
            if let path = path {
                files.append(path)
            } else if !ambiguous.isEmpty {
                let matches = ambiguous.joined(separator: ", ")
                throw TestRunnerError.ambiguousSkill(name: arg, matches: matches)
            } else {
                throw TestRunnerError.skillNotFound(name: arg)
            }
        }

        return files
    }

    /// Discover all skill YAML files from default directories.
    private static func discoverAllSkillFiles() -> [String] {
        let dirs = PermissionPolicy.skillDirs
        var files: [String] = []
        var seenRelPaths = Set<String>()

        for dir in dirs {
            for relPath in MirroirMCP.findYAMLFiles(in: dir) {
                if seenRelPaths.contains(relPath) { continue }
                seenRelPaths.insert(relPath)
                files.append(dir + "/" + relPath)
            }
        }

        return files
    }

    /// Expand a glob pattern to matching file paths.
    private static func expandGlob(_ pattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }

        let result = glob(pattern, 0, nil, &gt)
        guard result == 0 else { return [] }

        var files: [String] = []
        for i in 0..<Int(gt.gl_matchc) {
            if let path = gt.gl_pathv[i] {
                files.append(String(cString: path))
            }
        }
        return files.filter { $0.hasSuffix(".yaml") }.sorted()
    }

    /// Print usage information.
    static func printUsage() {
        let usage = """
        Usage: mirroir-mcp test [options] [skill...]

        Run skill YAML files deterministically against iPhone Mirroring.

        Arguments:
          <skill>             Skill name or .yaml file path (multiple allowed)
                              If none specified, discovers all from skill dirs

        Options:
          --junit <path>      Write JUnit XML report to <path>
          --screenshot-dir    Failure screenshot directory (default: ./mirroir-test-results/)
          --timeout <sec>     wait_for timeout in seconds (default: 15)
          --verbose, -v       Show detailed output
          --dry-run           Parse and validate without executing
          --no-compiled       Skip compiled skills (force full OCR)
          --agent [model]     Diagnose compiled failures. Without model: deterministic OCR only.
                              With model: deterministic + AI diagnosis.
                              Built-in: claude-sonnet-4-6, claude-haiku-4-5, gpt-4o
                              Ollama: ollama:<model>  Custom: name from agents/ dir
          --help, -h          Show this help

        Examples:
          mirroir-mcp test check-about
          mirroir-mcp test apps/settings/check-about.yaml
          mirroir-mcp test --junit results.xml apps/settings/*.yaml
          mirroir-mcp test --agent skill.yaml           # deterministic diagnosis
          mirroir-mcp test --agent claude-sonnet-4-6 skill.yaml  # AI diagnosis
          mirroir-mcp test                    # run all discovered skills
        """
        fputs(usage + "\n", stderr)
    }
}

/// Errors during test run resolution.
enum TestRunnerError: LocalizedError {
    case noSkillsFound(pattern: String)
    case ambiguousSkill(name: String, matches: String)
    case skillNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case .noSkillsFound(let pattern):
            return "No skills found matching pattern: \(pattern)"
        case .ambiguousSkill(let name, let matches):
            return "Ambiguous skill '\(name)'. Multiple matches: \(matches)"
        case .skillNotFound(let name):
            return "Skill '\(name)' not found"
        }
    }
}
