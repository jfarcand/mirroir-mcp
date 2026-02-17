// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Top-level orchestrator for the `mirroir test` CLI subcommand.
// ABOUTME: Parses CLI args, discovers scenarios, executes them, and reports results.

import Darwin
import Foundation
import HelperLib

/// Configuration parsed from CLI arguments.
struct TestRunConfig {
    let scenarioArgs: [String]
    let junitPath: String?
    let screenshotDir: String
    let timeoutSeconds: Int
    let verbose: Bool
    let dryRun: Bool
    let showHelp: Bool
}

/// Orchestrates scenario test execution from the CLI.
enum TestRunner {

    /// Parse CLI arguments and run tests. Returns exit code (0 = all pass, 1 = any fail).
    static func run(arguments: [String]) -> Int32 {
        let config = parseArguments(arguments)

        if config.showHelp {
            printUsage()
            return 0
        }

        // Resolve scenario files
        let scenarioFiles: [String]
        do {
            scenarioFiles = try resolveScenarioFiles(config.scenarioArgs)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }

        if scenarioFiles.isEmpty {
            fputs("No scenarios found.\n", stderr)
            fputs("Place .yaml files in .iphone-mirroir-mcp/scenarios/ or specify paths.\n", stderr)
            return 1
        }

        fputs("mirroir test: \(scenarioFiles.count) scenario(s) to run\n", stderr)

        // Parse all scenarios upfront to catch errors early
        var scenarios: [ScenarioDefinition] = []
        for filePath in scenarioFiles {
            do {
                let scenario = try ScenarioParser.parse(filePath: filePath)
                scenarios.append(scenario)
            } catch {
                fputs("Error parsing \(filePath): \(error.localizedDescription)\n", stderr)
                return 1
            }
        }

        // Initialize subsystems (skip for dry run — no system access needed)
        let bridge = MirroringBridge()
        let capture = ScreenCapture(bridge: bridge)
        let input = InputSimulation(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge)

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

        // Execute scenarios
        var allResults: [ConsoleReporter.ScenarioResult] = []

        for scenario in scenarios {
            let result = executeScenario(scenario: scenario, executor: executor,
                                         verbose: config.verbose)
            allResults.append(result)
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

    /// Execute a single scenario and return results.
    static func executeScenario(scenario: ScenarioDefinition,
                                executor: StepExecutor,
                                verbose: Bool) -> ConsoleReporter.ScenarioResult {
        let stepCount = scenario.steps.count
        ConsoleReporter.reportScenarioStart(
            name: scenario.name, filePath: scenario.filePath, stepCount: stepCount)

        let startTime = CFAbsoluteTimeGetCurrent()
        var stepResults: [StepResult] = []
        var stopOnFailure = false

        for (index, step) in scenario.steps.enumerated() {
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
                                          scenarioName: scenario.name)
            stepResults.append(result)
            ConsoleReporter.reportStep(index: index, total: stepCount,
                                       result: result, verbose: verbose)

            if result.status == .failed {
                stopOnFailure = true
            }
        }

        let totalDuration = CFAbsoluteTimeGetCurrent() - startTime
        let scenarioResult = ConsoleReporter.ScenarioResult(
            name: scenario.name,
            filePath: scenario.filePath,
            stepResults: stepResults,
            durationSeconds: totalDuration
        )
        ConsoleReporter.reportScenarioEnd(result: scenarioResult)
        return scenarioResult
    }

    // MARK: - Argument Parsing

    /// Parse CLI arguments into TestRunConfig.
    static func parseArguments(_ args: [String]) -> TestRunConfig {
        var scenarioArgs: [String] = []
        var junitPath: String?
        var screenshotDir = "./mirroir-test-results"
        var timeoutSeconds = 15
        var verbose = false
        var dryRun = false
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
            default:
                if !arg.hasPrefix("-") {
                    scenarioArgs.append(arg)
                }
            }
            i += 1
        }

        return TestRunConfig(
            scenarioArgs: scenarioArgs,
            junitPath: junitPath,
            screenshotDir: screenshotDir,
            timeoutSeconds: timeoutSeconds,
            verbose: verbose,
            dryRun: dryRun,
            showHelp: showHelp
        )
    }

    /// Resolve scenario arguments to file paths.
    /// If no args given, discovers all scenarios from default directories.
    static func resolveScenarioFiles(_ args: [String]) throws -> [String] {
        if args.isEmpty {
            // Discover all scenarios from scenario directories
            return discoverAllScenarioFiles()
        }

        var files: [String] = []
        let dirs = PermissionPolicy.scenarioDirs

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
                    throw TestRunnerError.noScenariosFound(pattern: arg)
                }
                files.append(contentsOf: expanded)
                continue
            }

            // Try to resolve as scenario name
            let (path, ambiguous) = IPhoneMirroirMCP.resolveScenario(name: arg, dirs: dirs)
            if let path = path {
                files.append(path)
            } else if !ambiguous.isEmpty {
                let matches = ambiguous.joined(separator: ", ")
                throw TestRunnerError.ambiguousScenario(name: arg, matches: matches)
            } else {
                throw TestRunnerError.scenarioNotFound(name: arg)
            }
        }

        return files
    }

    /// Discover all scenario YAML files from default directories.
    private static func discoverAllScenarioFiles() -> [String] {
        let dirs = PermissionPolicy.scenarioDirs
        var files: [String] = []
        var seenRelPaths = Set<String>()

        for dir in dirs {
            for relPath in IPhoneMirroirMCP.findYAMLFiles(in: dir) {
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
        Usage: iphone-mirroir-mcp test [options] [scenario...]

        Run scenario YAML files deterministically against iPhone Mirroring.

        Arguments:
          <scenario>          Scenario name or .yaml file path (multiple allowed)
                              If none specified, discovers all from scenario dirs

        Options:
          --junit <path>      Write JUnit XML report to <path>
          --screenshot-dir    Failure screenshot directory (default: ./mirroir-test-results/)
          --timeout <sec>     wait_for timeout in seconds (default: 15)
          --verbose, -v       Show detailed output
          --dry-run           Parse and validate without executing
          --help, -h          Show this help

        Examples:
          iphone-mirroir-mcp test check-about
          iphone-mirroir-mcp test apps/settings/check-about.yaml
          iphone-mirroir-mcp test --junit results.xml apps/settings/*.yaml
          iphone-mirroir-mcp test                    # run all discovered scenarios
        """
        fputs(usage + "\n", stderr)
    }
}

/// Errors during test run resolution.
enum TestRunnerError: LocalizedError {
    case noScenariosFound(pattern: String)
    case ambiguousScenario(name: String, matches: String)
    case scenarioNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case .noScenariosFound(let pattern):
            return "No scenarios found matching pattern: \(pattern)"
        case .ambiguousScenario(let name, let matches):
            return "Ambiguous scenario '\(name)'. Multiple matches: \(matches)"
        case .scenarioNotFound(let name):
            return "Scenario '\(name)' not found"
        }
    }
}
