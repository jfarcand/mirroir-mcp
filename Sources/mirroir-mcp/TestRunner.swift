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
    /// Allow steps with real-world consequences to execute. Off by default so a
    /// skill cannot send, delete, or buy anything without an explicit say-so.
    let confirmDestructive: Bool
    /// Write the run as a Playwright JSON-reporter document here — the shape
    /// mirroir-run already ingests for its web leg.
    let reportJSONPath: String?
    /// Attach each skill's final-screen OCR text to that report under this
    /// `cross_surface` key, for a paired surface to be compared against.
    let captureKey: String?
    let showHelp: Bool
}

/// Orchestrates skill test execution from the CLI.
enum TestRunner {

    /// Exit code for arguments the command refuses (an unknown flag, say), as
    /// distinct from 1, a run that executed and failed.
    static let usageExitCode: Int32 = 2

    /// Parse CLI arguments and run tests. Returns exit code (0 = all pass, 1 = any
    /// fail, 2 = refused arguments).
    static func run(arguments: [String]) -> Int32 {
        let config: TestRunConfig
        do {
            config = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return usageExitCode
        }

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
            fputs("Place skills in .mirroir-mcp/skills/ or specify paths.\n", stderr)
            return 1
        }

        fputs("mirroir test: \(skillFiles.count) skill(s) to run\n", stderr)

        // Parse all skills upfront to catch errors early
        var skills: [SkillDefinition] = []
        for filePath in skillFiles {
            do {
                let skill = try SkillFileLoader.load(filePath: filePath)
                if skill.kind == "game" {
                    fputs("Skipping \(skill.name): kind:game is model-interpreted — "
                        + "never replayed by the runner.\n", stderr)
                    continue
                }
                skills.append(skill)
            } catch {
                fputs("Error loading \(filePath): \(error.localizedDescription)\n", stderr)
                return 1
            }
        }

        if skills.isEmpty {
            fputs("No replayable skills: every skill given is kind:game.\n", stderr)
            return 1
        }

        if let refusal = InvalidStepGate.refuse(skills: skills) {
            return refusal
        }

        if let refusal = DestructiveStepGate.refuse(
            skills: skills, dryRun: config.dryRun, confirmed: config.confirmDestructive) {
            return refusal
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

        // The registry resolves `target:` steps; without it the first one fails.
        // Live and compiled-passthrough executors share it.
        let registry = MirroirMCP.buildTargetRegistry()
        let executor = StepExecutor(
            bridge: bridge, input: input,
            describer: describer, capture: capture,
            config: executorConfig,
            registry: registry
        )

        // Load compiled skills if available. Only read: a test run never writes one.
        var compiledMap: [String: CompiledSkill] = [:]
        if !config.noCompiled {
            let windowInfo = bridge.getWindowInfo()
            compiledMap = freshCompiledSkills(
                for: skills,
                windowWidth: windowInfo.map { Double($0.size.width) } ?? 0,
                windowHeight: windowInfo.map { Double($0.size.height) } ?? 0)
        }

        // Execute skills
        var allResults: [ConsoleReporter.SkillResult] = []
        var screenCaptures: [Int: String] = [:]
        var totalCompiledSteps = 0
        var totalNormalSteps = 0

        for skill in skills {
            let result: ConsoleReporter.SkillResult
            if let compiled = compiledMap[skill.filePath] {
                let compiledExecutor = CompiledStepExecutor(
                    bridge: bridge, input: input,
                    describer: describer, capture: capture,
                    config: executorConfig,
                    registry: registry
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
            if config.captureKey != nil, !config.dryRun,
               let screen = executor.describer.describe() {
                screenCaptures[allResults.count] =
                    ScenarioStepFormatter.screenText(elements: screen.elements)
            }
            allResults.append(result)
        }

        if totalCompiledSteps > 0 {
            fputs("\nCompiled: \(totalCompiledSteps) step(s) OCR-free, \(totalNormalSteps) normal\n", stderr)
        }

        // Print summary
        ConsoleReporter.reportSummary(
            results: allResults, captures: CaptureStats.shared.snapshot())

        // Write JUnit XML if requested
        if let junitPath = config.junitPath {
            do {
                try JUnitReporter.writeXML(results: allResults, to: junitPath)
                fputs("\nJUnit XML written to: \(junitPath)\n", stderr)
            } catch {
                fputs("\nWarning: Failed to write JUnit XML: \(error.localizedDescription)\n", stderr)
            }
        }

        // The JSON report is a contract a caller reads for the verdict, so
        // failing to write it fails the run rather than warning.
        if let reportPath = config.reportJSONPath {
            do {
                try PlaywrightReportWriter.write(
                    results: allResults, screenCaptures: screenCaptures,
                    captureKey: config.captureKey, to: reportPath)
                fputs("\nJSON report written to: \(reportPath)\n", stderr)
            } catch {
                fputs("\nError: failed to write JSON report: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }

        // Exit code
        return allResults.allSatisfy(\.passed) ? 0 : 1
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
}
