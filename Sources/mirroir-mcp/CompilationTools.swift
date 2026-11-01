// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers MCP tools for AI-driven skill compilation (record_step, save_compiled).
// ABOUTME: Derives hints from the steps the AI reports; save_compiled delegates to SaveCompiledHandler.

import Foundation
import HelperLib

extension MirroirMCP {
    /// Register record_step and save_compiled on `session`, the one get_skill marks
    /// a skill's start screen on.
    static func registerCompilationTools(
        server: MCPServer,
        registry: TargetRegistry,
        session: CompilationSession
    ) {
        registerRecordStepTool(server: server, session: session, registry: registry)
        registerSaveCompiledTool(server: server, session: session, registry: registry)
    }

    // MARK: - record_step

    private static func registerRecordStepTool(
        server: MCPServer,
        session: CompilationSession,
        registry: TargetRegistry
    ) {
        server.registerTool(MCPToolDefinition(
            name: "record_step",
            description: """
                Record a compiled step during AI-driven skill execution. \
                Call this right after each skill step, once the step is done, with the \
                step index, type, label, and any observed data (coordinates, timing, \
                scroll count); the screen it leaves is read as the next step's start. \
                For a tap with coordinates and no label, the screen the tap led to is \
                recorded, and replay fails the tap unless it reaches that screen. A \
                destination with too little text to recognize, or a tap that left the \
                screen unchanged, is refused. \
                The server accumulates steps for later saving via save_compiled.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "step_index": .object([
                        "type": .string("integer"),
                        "description": .string("Step index in the skill (0-based)"),
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Step type (tap, wait_for, launch, type, press_key, swipe, " +
                            "scroll_to, assert_visible, assert_not_visible, home, open_url, " +
                            "shake, reset_app, set_network, screenshot, long_press, drag, " +
                            "target, measure)"),
                    ]),
                    "label": .object([
                        "type": .string("string"),
                        "description": .string(
                            "The step's value, written as the skill step's value, which replay " +
                            "rebuilds the step from: the element to tap, wait for or assert, the " +
                            "app to launch or reset, the text to type, the key to press " +
                            "(\"l+command\" with modifiers), the swipe direction, the URL, the " +
                            "network mode, `\"Element\" duration: 1000` for long_press, " +
                            "`{ from: \"A\", to: \"B\" }` for drag, `{ kind: ios, app: \"Notes\" }` " +
                            "for target, `{ tap: \"Login\", until: \"Dashboard\", max: 5, " +
                            "name: \"login_time\" }` for measure. Omit for home and shake. " +
                            "save_compiled stores a value the skill takes from `${VAR}` as that " +
                            "placeholder, so secrets stay out of the compiled file."),
                    ]),
                    "tap_x": .object([
                        "type": .string("number"),
                        "description": .string("Tap X coordinate from describe_screen. Optional."),
                    ]),
                    "tap_y": .object([
                        "type": .string("number"),
                        "description": .string("Tap Y coordinate from describe_screen. Optional."),
                    ]),
                    "match_strategy": .object([
                        "type": .string("string"),
                        "description": .string("How the element was matched (exact, contains, etc.). Optional."),
                    ]),
                    "elapsed_ms": .object([
                        "type": .string("integer"),
                        "description": .string("Time waited in milliseconds before an assert_visible / assert_not_visible passed. Optional."),
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
                guard stepIndex >= 0 else {
                    return .error("step_index must be 0 or more, got \(stepIndex)")
                }
                guard let recordedType = args["type"]?.asString() else {
                    return .error("Missing required parameter: type (string)")
                }

                let label = args["label"]?.asString()
                // Replay rebuilds the step from type and label. A step done with a tool
                // that has no skill step type (press_back, double_tap, ...) is still
                // recorded, so an MCP compile completes, but `mirroir test` cannot replay
                // it and refuses the skill with this reason.
                let parsed = SkillParser.parseStep(key: recordedType, rawValue: label ?? "")
                let replayNote = InvalidStepGate.unreadable(parsed).map {
                    " Note: `mirroir test` cannot replay this step (\($0.reason))."
                } ?? ""
                // Store the canonical type (an alias such as press_home becomes home),
                // so hints and replay agree on what the step is.
                let stepType = parsed.typeKey
                let tapX = args["tap_x"]?.asNumber()
                let tapY = args["tap_y"]?.asNumber()
                let matchStrategy = args["match_strategy"]?.asString()
                let elapsedMs = args["elapsed_ms"]?.asInt()
                let scrollCount = args["scroll_count"]?.asInt()
                let scrollDirection = args["scroll_direction"]?.asString()

                // The screen this step left on display is kept for the next step to
                // start from. A tap by coordinates alone has no label for replay to
                // check, so that screen is also the destination replay must reach.
                let coordinateOnlyTap = stepType == "tap" && (label ?? "").isEmpty
                    && tapX != nil && tapY != nil
                let arrival: ScreenFingerprint?
                switch ArrivalCheck.observe(stepIndex: stepIndex,
                                            coordinateOnlyTap: coordinateOnlyTap,
                                            session: session, target: registry.activeTarget) {
                case .success(let fingerprint): arrival = fingerprint
                case .failure(let refusal): return .error(refusal.reason)
                }
                let hints = deriveHints(
                    type: stepType, tapX: tapX, tapY: tapY,
                    matchStrategy: matchStrategy,
                    elapsedMs: elapsedMs, scrollCount: scrollCount,
                    scrollDirection: scrollDirection, arrival: arrival)

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
                return .text("Recorded step \(stepIndex): \(stepType) '\(label ?? "")' (\(actionDesc))"
                    + replayNote)
            }
        ))
    }

    // MARK: - save_compiled

    /// The target's current screen, from one local OCR call: its fingerprint and
    /// its elements. Always OCR: it is bookkeeping, not a description the client
    /// asked for, so it never spends a vision call.
    static func captureScreen(target: any Target) -> CompiledScreenRead? {
        guard let screen = target.ocrDescriber.describe() else { return nil }
        return CompiledScreenRead(
            fingerprint: StructuralFingerprint.buildScreenFingerprint(
                elements: screen.elements, icons: screen.icons),
            elements: screen.elements)
    }

    private static func registerSaveCompiledTool(
        server: MCPServer,
        session: CompilationSession,
        registry: TargetRegistry
    ) {
        server.registerTool(MCPToolDefinition(
            name: "save_compiled",
            description: """
                Save the accumulated compiled steps as a .compiled.json file next to \
                the source skill file. Call this after all record_step calls are done. \
                The file fingerprints the screen get_skill saw before step 1, so call \
                get_skill before running the first step. With emit=true, the same walk \
                is also written as a runnable .mirroir/apps/<app>/ iOS scenario in the \
                consumer repo; its app is the one the skill's opening launch: names. \
                Clears the compilation session afterward.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "skill_name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Skill name or path to resolve (e.g. 'check-about' or 'apps/settings/check-about')"),
                    ]),
                    "emit": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "When true, also write the compiled walk into the consumer repo as a " +
                            ".mirroir/apps/<app>/scenarios/<skill>.ios.yaml scenario (target: " +
                            "{ kind: ios }, reset_app then launch of the app the skill launches, " +
                            "a wait_for on each screen a tap reaches), plus SAMPLE.md, the " +
                            "mirroir.yaml plan entry and drift defaults. The skill must open " +
                            "with launch: (after any target: / reset_app:). No .compiled.json " +
                            "is written into .mirroir/: the runner replays the scenario live. " +
                            "A walk the scenario cannot carry is refused by step."),
                    ]),
                    "output_dir": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Consumer repo root the emit=true tree is written under " +
                            "(<output_dir>/.mirroir/apps/<app>/). Defaults to walking up from " +
                            "the working directory; emitting into ~/.mirroir is refused."),
                    ]),
                ]),
                "required": .array([.string("skill_name")]),
            ],
            handler: { args in
                SaveCompiledHandler.handle(
                    args: args, session: session, target: registry.activeTarget)
            }
        ))
    }

    /// Mark on `session` the screen `skillPath` starts from, read by local OCR on
    /// `target`, when get_skill serves it before any step is recorded. A kind:game
    /// skill is never compiled, so it needs none.
    static func markSkillStart(
        skillPath: String, content: String, session: CompilationSession, target: any Target
    ) {
        guard SkillParser.headerKind(from: content) != "game" else { return }
        session.markStart(skillPath: skillPath) {
            captureScreen(target: target)
        }
    }

    // MARK: - Hint Derivation

    /// The label save_compiled writes for a recorded step: each value the skill takes
    /// from a `${VAR}` in `source` is swapped back for that placeholder. A step that
    /// rebuilds whole is rewritten field by field into its replay value; any other
    /// label is kept as recorded, with a whole-value match still swapped.
    static func storedLabel(_ label: String, type: String, source: String) -> String {
        let parsed = SkillParser.parseStep(key: type, rawValue: label)
        guard recordProblem(parsed) == nil,
              InvalidStepGate.unreadable(parsed) == nil,
              let rewritten = parsed
                .mappingValues({ envPlaceholder(resolvingTo: $0, in: source) ?? $0 })
                .replayValue else {
            return envPlaceholder(resolvingTo: label, in: source) ?? label
        }
        return rewritten
    }

    /// What keeps recorded steps from replaying as a SKILL.md, one line per step:
    /// each must rebuild, from its type and label, into a step that can run.
    /// A tap recorded by coordinates alone needs no label: it replays from its hint.
    static func skillMdReplayProblems(_ steps: [CompiledStep]) -> [String] {
        steps.compactMap { step in
            let parsed = SkillParser.parseStep(key: step.type, rawValue: step.label ?? "")
            if case .tap(let label) = parsed, label.isEmpty,
               step.hints?.compiledAction == .tap, step.hints?.tapX != nil, step.hints?.tapY != nil {
                return nil
            }
            return recordProblem(parsed).map { "step \(step.index) (\(step.type)): \($0)" }
        }
    }

    /// Why a recorded step cannot be replayed, or nil when it can: the parser could not
    /// read it, or a measure has no action to run or no element to wait for.
    static func recordProblem(_ step: SkillStep) -> String? {
        switch step {
        case .invalid(_, let reason):
            // A type with no skill step: recorded for the MCP side, refused by
            // `mirroir test` with its reason. Re-recording cannot change it. Any
            // other invalid value (a malformed target selector) can be recorded again.
            return reason == SkillParser.unknownStepTypeReason ? nil : reason
        case .skipped(let stepType, let reason):
            // An AI-only step is recorded without hints; any other skipped step is a
            // value the parser could not use (e.g. a drag without from/to).
            return SkillParser.aiOnlyStepTypes.contains(stepType) ? nil : reason
        case .launch(let value), .tap(let value), .type(let value), .swipe(let value),
             .waitFor(let value, _), .assertVisible(let value), .assertNotVisible(let value),
             .openURL(let value), .resetApp(let value), .setNetwork(let value),
             .scrollTo(let value, _, _), .longPress(let value, _):
            return value.isEmpty
                ? "a \(step.typeKey) step needs its value in `label` (the element, app, text, ...)"
                : nil
        case .pressKey(let key, _):
            return key.isEmpty ? "a press_key step needs the key in `label`" : nil
        case .drag(let fromLabel, let toLabel):
            return fromLabel.isEmpty || toLabel.isEmpty
                ? "a drag needs both ends, `{ from: \"A\", to: \"B\" }`" : nil
        case .measure(_, let action, let until, _):
            if case .skipped = action {
                return "a measure needs an action, e.g. `{ tap: \"Login\", until: \"Dashboard\" }`"
            }
            if until.isEmpty {
                return "a measure needs `until:`, the element that ends it"
            }
            return recordProblem(action).map { "its action: \($0)" }
        default:
            return nil
        }
    }

    /// Derive compiled hints from the step type and observed data.
    /// Returns nil for AI-only steps that cannot be compiled.
    static func deriveHints(
        type: String,
        tapX: Double?,
        tapY: Double?,
        matchStrategy: String?,
        elapsedMs: Int?,
        scrollCount: Int?,
        scrollDirection: String?,
        arrival: ScreenFingerprint? = nil
    ) -> StepHints? {
        switch type {
        case "tap":
            if let x = tapX, let y = tapY {
                return .tap(
                    x: x, y: y,
                    strategy: matchStrategy ?? "unknown", arrival: arrival)
            }
            // Tap without coordinates: replay it live, finding the element by OCR.
            // A sleep would report the step passed without tapping anything.
            return .passthrough()

        case "wait_for":
            // Replayed live: polls the screen until the element shows or its timeout
            // passes. A recorded delay would pass without looking.
            return .passthrough()

        case "assert_visible", "assert_not_visible":
            return .assertion(delayMs: elapsedMs ?? 500)

        case "scroll_to":
            let count = scrollCount ?? 1
            let direction = scrollDirection ?? "up"
            return .scrollSequence(count: count, direction: direction)

        case "launch", "type", "press_key", "swipe", "home", "open_url",
             "shake", "reset_app", "set_network", "screenshot", "target", "switch_target",
             "long_press", "drag":
            return .passthrough()

        case "measure":
            // Replayed live: a sleep would pass without running the action or the check.
            return .passthrough()

        default:
            return nil
        }
    }
}
