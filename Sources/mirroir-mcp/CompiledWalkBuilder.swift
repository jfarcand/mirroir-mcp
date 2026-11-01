// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Turns a save_compiled session (recorded steps + the screen read after each) into a walk.
// ABOUTME: Pure transformation — feeds the .mirroir/ emitter the same [ExploredScreen] generate_skill does.

import Foundation
import HelperLib

/// Maps the steps an AI-driven compile recorded, and the screen `record_step`
/// read after each, onto the linear `[ExploredScreen]` walk
/// `MirroirAppTreeEmitter` renders, so `save_compiled emit=true` shares the
/// scenario formatter and its refusals with `generate_skill` and `record`.
///
/// The walk's leading `target` / `reset_app` / `launch` steps are its
/// opening: the formatter writes that opening itself, from the app the
/// `launch:` names. The walk then starts on the screen read after the last
/// opening step, and each later step is the action that reached the screen
/// read after it.
enum CompiledWalkBuilder {

    /// Why a compiled session cannot become a walk.
    enum WalkError: LocalizedError, Equatable {
        /// The skill does not open with a `launch:` (after any `target` /
        /// `reset_app`), so the walk has no app and no known start screen.
        case noLaunchPrologue
        /// An opening step drives a different app than the opening `launch:`.
        case foreignPrologueApp(step: Int, app: String, launchedApp: String)
        /// The screen after `step` was not read, so the walk has a gap.
        case screenNotRead(step: Int)
        /// A step's value carries something the scenario step cannot.
        case unsupportedValue(step: Int, type: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .noLaunchPrologue:
                return "the skill does not open with a launch: step (after any target: / " +
                    "reset_app:), so the scenario has no app to reset and launch; add one and " +
                    "compile again"
            case .foreignPrologueApp(let step, let app, let launchedApp):
                return "step \(step) drives \"\(app)\" but the skill launches \"\(launchedApp)\"; " +
                    "a scenario's opening drives one app"
            case .screenNotRead(let step):
                return "the screen after step \(step) was not read, so the walk cannot show " +
                    "what that step reached; call record_step for it again once the screen settles"
            case .unsupportedValue(let step, let type, let reason):
                return "step \(step) (\(type)): \(reason)"
            }
        }
    }

    /// The step types a scenario's opening is made of.
    private static let openingTypes: Set<String> = ["target", "reset_app", "launch"]

    /// The app the compiled walk drives and its emitter flow named `flowName`.
    ///
    /// - Parameters:
    ///   - steps: the recorded steps, one per index in step order.
    ///   - elementsAfter: the elements of the screen read after each step, by index.
    /// - Throws: `WalkError` when the walk has no launch opening, an opening
    ///   step names another app, a screen was not read, or a value cannot be
    ///   carried. AI-only and unsupported steps pass through for the formatter
    ///   to refuse by name.
    static func flow(
        flowName: String, steps: [CompiledStep], elementsAfter: [Int: [TapPoint]]
    ) throws -> (appName: String, flow: MirroirAppTreeEmitter.Flow) {
        let parsed = steps.map { SkillParser.parseStep(key: $0.type, rawValue: $0.label ?? "") }
        let opening = Array(parsed.prefix { openingTypes.contains($0.typeKey) })
        let appName = try openingApp(opening, steps: steps)
        // openingApp found a launch, so the opening holds at least one step.
        let lastOpening = steps[opening.count - 1].index
        guard let startElements = elementsAfter[lastOpening] else {
            throw WalkError.screenNotRead(step: lastOpening)
        }
        var screens = [ExploredScreen(
            index: 0, elements: startElements, hints: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "")]
        for (step, skillStep) in zip(steps, parsed).dropFirst(opening.count) {
            guard let elements = elementsAfter[step.index] else {
                throw WalkError.screenNotRead(step: step.index)
            }
            let action = try action(for: skillStep, step: step.index)
            screens.append(ExploredScreen(
                index: screens.count, elements: elements, hints: [],
                actionType: action.type, arrivedVia: action.value, screenshotBase64: ""))
        }
        return (appName, MirroirAppTreeEmitter.Flow(name: flowName, screens: screens))
    }

    /// The app the opening's `launch:` names, checked against every other
    /// app the opening drives.
    private static func openingApp(_ opening: [SkillStep], steps: [CompiledStep]) throws -> String {
        guard let launchedApp = opening.lazy.compactMap({ step -> String? in
            if case .launch(let app) = step, !app.isEmpty { return app }
            return nil
        }).first else {
            throw WalkError.noLaunchPrologue
        }
        for (step, skillStep) in zip(steps, opening) {
            let app: String?
            switch skillStep {
            case .launch(let name), .resetApp(let name): app = name
            case .switchTarget(.ios(let name)): app = name
            case .switchTarget(.macos(let name)): app = name
            default: app = nil
            }
            if let app, app != launchedApp {
                throw WalkError.foreignPrologueApp(step: step.index, app: app, launchedApp: launchedApp)
            }
        }
        return launchedApp
    }

    /// The walk action type and value a recorded step maps to. Element and
    /// literal steps keep their value; a long press keeps only its label and a
    /// key press writes its modifiers inline (`l+command`). Any other step
    /// keeps its type key, which the formatter writes or refuses by name.
    private static func action(for step: SkillStep, step index: Int) throws -> (type: String, value: String?) {
        switch step {
        case .tap(let value), .type(let value), .swipe(let value), .assertVisible(let value),
             .assertNotVisible(let value), .screenshot(let value), .openURL(let value):
            return (step.typeKey, value)
        case .longPress(let label, _), .scrollTo(let label, _, _):
            return (step.typeKey, label)
        case .waitFor(let label, nil):
            return (step.typeKey, label)
        case .waitFor(_, .some(let timeout)):
            throw WalkError.unsupportedValue(
                step: index, type: step.typeKey,
                reason: "a scenario wait_for carries no timeout, so a \(timeout)s wait cannot be " +
                    "emitted as recorded")
        case .pressKey(let key, let modifiers):
            return (step.typeKey, ([key] + modifiers).joined(separator: "+"))
        case .home:
            return ("press_home", nil)
        default:
            return (step.typeKey, nil)
        }
    }
}
