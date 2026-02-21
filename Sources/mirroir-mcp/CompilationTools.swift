// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers MCP tools for AI-driven scenario compilation (record_step, save_compiled).
// ABOUTME: Accumulates step data reported by the AI during scenario execution and writes .compiled.json.

import Foundation
import HelperLib

/// Accumulates compiled steps reported by the AI during scenario execution.
/// Thread-safe via NSLock. Session persists across MCP calls (survives context compaction).
final class CompilationSession: @unchecked Sendable {
    private var steps: [CompiledStep] = []
    private let lock = NSLock()

    /// Record a compiled step.
    func record(_ step: CompiledStep) {
        lock.lock()
        defer { lock.unlock() }
        steps.append(step)
    }

    /// Return all accumulated steps and clear the session.
    func finalizeAndClear() -> [CompiledStep] {
        lock.lock()
        defer { lock.unlock() }
        let result = steps
        steps = []
        return result
    }

    /// Number of steps recorded so far.
    var stepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return steps.count
    }
}

extension MirroirMCP {
    static func registerCompilationTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        let session = CompilationSession()

        registerRecordStepTool(server: server, session: session)
        registerSaveCompiledTool(server: server, session: session, registry: registry)
    }

    // MARK: - record_step

    private static func registerRecordStepTool(
        server: MCPServer,
        session: CompilationSession
    ) {
        server.registerTool(MCPToolDefinition(
            name: "record_step",
            description: """
                Record a compiled step during AI-driven scenario execution. \
                Call this after each scenario step with the step index, type, label, \
                and any observed data (coordinates, timing, scroll count). \
                The server accumulates steps for later saving via save_compiled.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "step_index": .object([
                        "type": .string("integer"),
                        "description": .string("Step index in the scenario (0-based)"),
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Step type (tap, wait_for, launch, type, press_key, swipe, " +
                            "scroll_to, assert_visible, assert_not_visible, home, open_url, " +
                            "shake, reset_app, set_network, screenshot, switch_target, measure)"),
                    ]),
                    "label": .object([
                        "type": .string("string"),
                        "description": .string("Human-readable label from the step. Optional."),
                    ]),
                    "tap_x": .object([
                        "type": .string("number"),
                        "description": .string("Tap X coordinate from describe_screen. Optional."),
                    ]),
                    "tap_y": .object([
                        "type": .string("number"),
                        "description": .string("Tap Y coordinate from describe_screen. Optional."),
                    ]),
                    "confidence": .object([
                        "type": .string("number"),
                        "description": .string("OCR match confidence (0.0-1.0). Optional."),
                    ]),
                    "match_strategy": .object([
                        "type": .string("string"),
                        "description": .string("How the element was matched (exact, contains, etc.). Optional."),
                    ]),
                    "elapsed_ms": .object([
                        "type": .string("integer"),
                        "description": .string("Time waited in milliseconds (for wait_for, assert, measure). Optional."),
                    ]),
                    "scroll_count": .object([
                        "type": .string("integer"),
                        "description": .string("Number of scrolls performed (for scroll_to). Optional."),
                    ]),
                    "scroll_direction": .object([
                        "type": .string("string"),
                        "description": .string("Scroll direction: up, down, left, right (for scroll_to). Optional."),
                    ]),
                ]),
                "required": .array([.string("step_index"), .string("type")]),
            ],
            handler: { args in
                guard let stepIndex = args["step_index"]?.asInt() else {
                    return .error("Missing required parameter: step_index (integer)")
                }
                guard let stepType = args["type"]?.asString() else {
                    return .error("Missing required parameter: type (string)")
                }

                let label = args["label"]?.asString()
                let tapX = args["tap_x"]?.asNumber()
                let tapY = args["tap_y"]?.asNumber()
                let confidence = args["confidence"]?.asNumber().map { Float($0) }
                let matchStrategy = args["match_strategy"]?.asString()
                let elapsedMs = args["elapsed_ms"]?.asInt()
                let scrollCount = args["scroll_count"]?.asInt()
                let scrollDirection = args["scroll_direction"]?.asString()

                let hints = deriveHints(
                    type: stepType, tapX: tapX, tapY: tapY,
                    confidence: confidence, matchStrategy: matchStrategy,
                    elapsedMs: elapsedMs, scrollCount: scrollCount,
                    scrollDirection: scrollDirection)

                let step = CompiledStep(
                    index: stepIndex, type: stepType,
                    label: label, hints: hints)
                session.record(step)

                let actionDesc: String
                if let hints {
                    actionDesc = hints.compiledAction.rawValue
                } else {
                    actionDesc = "AI-only (no hints)"
                }
                return .text("Recorded step \(stepIndex): \(stepType) '\(label ?? "")' (\(actionDesc))")
            }
        ))
    }

    // MARK: - save_compiled

    private static func registerSaveCompiledTool(
        server: MCPServer,
        session: CompilationSession,
        registry: TargetRegistry
    ) {
        server.registerTool(MCPToolDefinition(
            name: "save_compiled",
            description: """
                Save the accumulated compiled steps as a .compiled.json file next to \
                the source scenario file. Call this after all record_step calls are done. \
                Clears the compilation session afterward.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "scenario_name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Scenario name or path to resolve (e.g. 'check-about' or 'apps/settings/check-about')"),
                    ]),
                ]),
                "required": .array([.string("scenario_name")]),
            ],
            handler: { args in
                guard let scenarioName = args["scenario_name"]?.asString() else {
                    return .error("Missing required parameter: scenario_name (string)")
                }

                let stepCount = session.stepCount
                if stepCount == 0 {
                    return .error("No steps recorded. Call record_step before save_compiled.")
                }

                // Resolve scenario path
                let dirs = PermissionPolicy.scenarioDirs
                let (resolvedPath, ambiguous) = resolveScenario(name: scenarioName, dirs: dirs)

                guard let scenarioPath = resolvedPath else {
                    if !ambiguous.isEmpty {
                        let matches = ambiguous.map { "  - \($0)" }.joined(separator: "\n")
                        return .error(
                            "Ambiguous scenario name '\(scenarioName)':\n\(matches)")
                    }
                    return .error("Scenario '\(scenarioName)' not found")
                }

                // Compute source hash
                let sourceHash: String
                do {
                    sourceHash = try CompiledScenarioIO.sha256(of: scenarioPath)
                } catch {
                    return .error("Failed to hash scenario file: \(error.localizedDescription)")
                }

                // Get window dimensions from active target
                let target = registry.activeTarget
                let windowInfo = target.bridge.getWindowInfo()
                let windowWidth = windowInfo.map { Double($0.size.width) } ?? 0
                let windowHeight = windowInfo.map { Double($0.size.height) } ?? 0
                let orientation = target.bridge.getOrientation()?.rawValue ?? "unknown"

                // Build compiled scenario
                let steps = session.finalizeAndClear()
                let compiled = CompiledScenario(
                    version: CompiledScenario.currentVersion,
                    source: SourceInfo(
                        sha256: sourceHash,
                        compiledAt: ISO8601DateFormatter().string(from: Date())
                    ),
                    device: DeviceInfo(
                        windowWidth: windowWidth,
                        windowHeight: windowHeight,
                        orientation: orientation
                    ),
                    steps: steps
                )

                // Check if compiled file already exists
                let compiledPath = CompiledScenarioIO.compiledPath(for: scenarioPath)
                let alreadyExists = FileManager.default.fileExists(atPath: compiledPath)

                // Write the compiled file
                do {
                    try CompiledScenarioIO.save(compiled, for: scenarioPath)
                } catch {
                    return .error("Failed to write compiled file: \(error.localizedDescription)")
                }

                let compiledSteps = steps.filter { $0.hints != nil }.count
                let passthroughSteps = steps.filter { $0.hints?.compiledAction == .passthrough }.count
                let aiOnlySteps = steps.filter { $0.hints == nil }.count

                var response = "Saved \(compiledPath)\n"
                response += "Steps: \(steps.count) total, \(compiledSteps) compiled, "
                response += "\(passthroughSteps) passthrough, \(aiOnlySteps) AI-only"

                if alreadyExists {
                    response += "\nWarning: overwrote existing compiled file"
                }

                return .text(response)
            }
        ))
    }

    // MARK: - Hint Derivation

    /// Derive compiled hints from the step type and observed data.
    /// Returns nil for AI-only steps that cannot be compiled.
    static func deriveHints(
        type: String,
        tapX: Double?,
        tapY: Double?,
        confidence: Float?,
        matchStrategy: String?,
        elapsedMs: Int?,
        scrollCount: Int?,
        scrollDirection: String?
    ) -> StepHints? {
        switch type {
        case "tap":
            if let x = tapX, let y = tapY {
                return .tap(
                    x: x, y: y,
                    confidence: confidence ?? 0.0,
                    strategy: matchStrategy ?? "unknown")
            }
            // Tap without coordinates — treat as sleep if we have timing
            if let ms = elapsedMs {
                return .sleep(delayMs: ms)
            }
            return nil

        case "wait_for", "assert_visible", "assert_not_visible":
            return .sleep(delayMs: elapsedMs ?? 500)

        case "scroll_to":
            let count = scrollCount ?? 1
            let direction = scrollDirection ?? "up"
            return .scrollSequence(count: count, direction: direction)

        case "launch", "type", "press_key", "swipe", "home", "open_url",
             "shake", "reset_app", "set_network", "screenshot", "switch_target":
            return .passthrough()

        case "measure":
            return .sleep(delayMs: elapsedMs ?? 1000)

        default:
            return nil
        }
    }
}
