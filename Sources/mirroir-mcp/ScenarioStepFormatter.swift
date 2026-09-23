// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Formats a linear iOS exploration capture into a mirroir-run SkillStep scenario (YAML).
// ABOUTME: Pure transformation — emits target/launch/tap/... steps + a cross-surface baseline; no side effects.

import Foundation
import HelperLib

/// Renders a linear exploration capture into a `mirroir-run` SkillStep scenario
/// on the iOS surface, plus the cross-surface baseline text for that flow.
///
/// The emitted YAML is written in the shared step grammar, but it declares
/// `target: { kind: ios }` — a surface mirroir-run has no executor for, so the
/// runner refuses it by name rather than planning it. It is a faithful record of
/// the captured walk and the anchor a paired web capture is compared against via
/// `cross_surface:`.
enum ScenarioStepFormatter {

    /// Errors raised when a capture cannot be rendered faithfully.
    enum FormatError: LocalizedError, Equatable {
        /// The capture recorded an action type the scenario grammar has no step for.
        case unsupportedAction(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedAction(let action):
                return "captured action_type \"\(action)\" has no scenario step; " +
                    "refusing to record it as a different action"
            }
        }
    }

    /// Build the full `<flow>.ios.yaml` scenario document for `screens`.
    /// The first screen is the launch; each subsequent screen contributes the
    /// action that reached it. A destination landmark assertion is appended.
    ///
    /// - Throws: `FormatError.unsupportedAction` when a screen was reached by an
    ///   action the scenario grammar cannot express.
    static func scenarioYAML(name: String, appName: String, screens: [ExploredScreen]) throws -> String {
        var steps: [String] = [
            "  - target: { kind: ios, app: \(yamlScalar(appName)) }",
            "  - launch: \(yamlScalar(appName))",
        ]
        for screen in screens.dropFirst() {
            if let line = try stepLine(screen: screen) {
                steps.append(line)
            }
        }
        if let landmark = landmark(in: screens.last?.elements ?? []) {
            steps.append("  - assert_visible: \(yamlScalar(landmark))")
        }
        return "version: 1\nname: \(yamlScalar(name))\nsteps:\n" + steps.joined(separator: "\n") + "\n"
    }

    /// The cross-surface oracle: whitespace-joined OCR text of the destination
    /// screen — the equivalence landmark a paired web capture is diffed against.
    static func baseline(screens: [ExploredScreen]) -> String {
        let tokens = (screens.last?.elements ?? [])
            .map(\.text)
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ") + "\n"
    }

    /// Build the `<flow>.parity.yaml` cross-surface gate: pairs the iOS baseline
    /// (emitted here) with a web baseline (produced by the web leg). The runner
    /// compares the two files by Jaccard similarity; the step fails closed until
    /// the web capture exists. This gate declares no `target:`, so unlike the iOS
    /// walk it does validate with `mirroir-run --validate`.
    static func crossSurfaceYAML(name: String, flow: String) -> String {
        let lines = [
            "version: 1",
            "name: \(yamlScalar(name + " — cross-surface parity"))",
            "steps:",
            "  - cross_surface:",
            "      response_files:",
            "        - \"${MIRROIR_SAMPLE_DIR}/baselines/\(flow).web.txt\"",
            "        - \"${MIRROIR_SAMPLE_DIR}/baselines/\(flow).ios.txt\"",
            "      min_similarity: 0.5",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    /// Actions whose value names an on-screen element. The recorded label came
    /// from OCR, so it is cleaned, checked against the exclusion list, and
    /// matched to the element's exact casing on the screen it acted on.
    private static let elementActions: Set<String> = [
        "tap", "long_press", "scroll_to", "assert_visible",
    ]

    /// Actions whose value is carried verbatim: typed text, a key, a swipe
    /// direction, a URL, a note, a screenshot name, or a label asserted ABSENT
    /// (which by definition is not on the screen to be matched against).
    private static let literalActions: Set<String> = [
        "type", "press_key", "swipe", "open_url", "remember", "screenshot",
        "assert_not_visible",
    ]

    /// Map one explored screen's action into a single SkillStep YAML node.
    /// Returns nil when the recorded value is empty or excluded (skipped, not
    /// invented).
    ///
    /// - Throws: `FormatError.unsupportedAction` for an action type the
    ///   scenario grammar has no step for — writing it as some other verb would
    ///   record a walk that never happened.
    private static func stepLine(screen: ExploredScreen) throws -> String? {
        let action = screen.actionType ?? "tap"
        if action == "press_home" {
            return "  - home:"
        }
        if elementActions.contains(action) {
            guard let rawLabel = screen.displayLabel ?? screen.arrivedVia, !rawLabel.isEmpty else {
                return nil
            }
            let clean = ActionStepFormatter.cleanLabel(rawLabel)
            guard !clean.isEmpty, !ActionStepFormatter.isExcludedLabel(clean) else { return nil }
            let label = ActionStepFormatter.resolveLabel(arrivedVia: clean, elements: screen.elements)
            return "  - \(action): \(yamlScalar(label))"
        }
        if literalActions.contains(action) {
            guard let value = screen.arrivedVia, !value.isEmpty else { return nil }
            return "  - \(action): \(yamlScalar(value))"
        }
        throw FormatError.unsupportedAction(action)
    }

    /// Pick the destination landmark to assert: the longest non-excluded label
    /// on the final screen (prominence-by-length, mirroring `LandmarkPicker`).
    private static func landmark(in elements: [TapPoint]) -> String? {
        elements
            .map { ActionStepFormatter.cleanLabel($0.text) }
            .filter { $0.count >= 3 && !ActionStepFormatter.isExcludedLabel($0) }
            .max(by: { $0.count < $1.count })
    }

    /// Quote a value as a double-quoted YAML scalar, escaping `"`, `\`, and newlines.
    private static func yamlScalar(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.append(c)
            }
        }
        return out + "\""
    }
}
