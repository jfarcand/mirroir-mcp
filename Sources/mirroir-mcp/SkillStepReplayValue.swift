// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Serializes a SkillStep back to the raw value SkillParser.parseStep reads, the inverse of parsing.
// ABOUTME: A compiled step stores it as its label, so a SKILL.md's steps rebuild intact from its compiled file.

import Foundation

extension SkillStep {

    /// The raw value that `SkillParser.parseStep(key: typeKey, rawValue:)` turns back
    /// into this step, keeping every field: modifiers, timeouts, durations, both drag
    /// ends, the target selector map, a measure's action. Nil for a step with no value
    /// (`home`, `shake`), for a step the parser could not read, which has nothing to
    /// replay, and for a structured value holding both quote characters. A plain value stays bare, so a compiled label still reads as the
    /// element's text wherever it is matched against the screen.
    var replayValue: String? {
        if !hasStructuredReplayValue, let plain = plainValue {
            return Self.bare(plain)
        }
        switch self {
        case .waitFor(let label, .some(let timeoutSeconds)):
            return Self.quoted(label).map { "\($0) timeout: \(timeoutSeconds)" }
        case .longPress(let label, .some(let durationMs)):
            return Self.quoted(label).map { "\($0) duration: \(durationMs)" }
        case .drag(let fromLabel, let toLabel):
            guard let from = Self.quoted(fromLabel), let to = Self.quoted(toLabel) else { return nil }
            return "{ from: \(from), to: \(to) }"
        case .switchTarget(.ios(nil)):
            return "{ kind: ios }"
        case .switchTarget(.ios(.some(let app))):
            return Self.quoted(app).map { "{ kind: ios, app: \($0) }" }
        case .switchTarget(.macos(let name)):
            return Self.quoted(name).map { "{ kind: macos, name: \($0) }" }
        case .measure(let name, let action, let until, let maxSeconds):
            var parts: [String] = []
            if case .skipped = action {
                // No action was parsed; writing one back would invent a nested measure.
            } else {
                // A plain value is quoted exactly once, so a comma in it stays inside
                // it; a structured one (`"X" timeout: 5`, a map) already quotes its parts.
                // An action with no value (`home`) writes none.
                let value: String? = action.hasStructuredReplayValue
                    ? action.replayValue
                    : action.plainValue.map { Self.quoted($0) } ?? ""
                guard let value else { return nil }
                parts.append("\(action.typeKey): \(value)")
            }
            guard let until = Self.quoted(until), let name = Self.quoted(name) else { return nil }
            parts.append("until: \(until)")
            if let maxSeconds {
                parts.append("max: \(maxSeconds)")
            }
            parts.append("name: \(name)")
            return "{ " + parts.joined(separator: ", ") + " }"
        case .launch, .tap, .type, .swipe, .assertVisible, .assertNotVisible, .screenshot,
             .openURL, .resetApp, .setNetwork, .scrollTo, .waitFor, .longPress, .pressKey,
             .home, .shake, .skipped, .invalid:
            // Plain values return above; these have none.
            return nil
        }
    }

    /// The single value of a step whose replay value is one plain value, unescaped:
    /// the element, app, text, key (with `+modifiers`), direction, URL or mode. Nil for
    /// a structured step and for a step with no value.
    var plainValue: String? {
        switch self {
        case .launch(let value), .tap(let value), .type(let value), .swipe(let value),
             .assertVisible(let value), .assertNotVisible(let value), .screenshot(let value),
             .openURL(let value), .resetApp(let value), .setNetwork(let value):
            return value
        case .scrollTo(let label, _, _):
            return label
        case .pressKey(let key, let modifiers):
            return ([key] + modifiers).joined(separator: "+")
        case .waitFor(let label, _), .longPress(let label, _):
            return label
        case .drag, .switchTarget, .measure, .home, .shake, .skipped, .invalid:
            return nil
        }
    }

    /// Whether `replayValue` is more than one plain value: quoted parts with a suffix
    /// (a timeout, a duration) or a map (a drag, a target, a measure). A key with its
    /// modifiers is plain: `l+command`, and `++command` for the "+" key itself.
    var hasStructuredReplayValue: Bool {
        switch self {
        case .waitFor(_, let timeout): return timeout != nil
        case .longPress(_, let durationMs): return durationMs != nil
        case .drag, .switchTarget, .measure: return true
        default: return false
        }
    }

    /// This step with `transform` applied to each value it acts on (an element, app,
    /// text, key, URL, direction, network mode, a measure's `until` and action), leaving
    /// modifiers, timeouts, durations and the target selector as they are.
    func mappingValues(_ transform: (String) -> String) -> SkillStep {
        switch self {
        case .launch(let value): return .launch(appName: transform(value))
        case .tap(let value): return .tap(label: transform(value))
        case .type(let value): return .type(text: transform(value))
        case .swipe(let value): return .swipe(direction: transform(value))
        case .assertVisible(let value): return .assertVisible(label: transform(value))
        case .assertNotVisible(let value): return .assertNotVisible(label: transform(value))
        case .screenshot(let value): return .screenshot(label: transform(value))
        case .openURL(let value): return .openURL(url: transform(value))
        case .resetApp(let value): return .resetApp(appName: transform(value))
        case .setNetwork(let value): return .setNetwork(mode: transform(value))
        case .waitFor(let label, let timeout):
            return .waitFor(label: transform(label), timeoutSeconds: timeout)
        case .scrollTo(let label, let direction, let maxScrolls):
            return .scrollTo(label: transform(label), direction: direction, maxScrolls: maxScrolls)
        case .longPress(let label, let durationMs):
            return .longPress(label: transform(label), durationMs: durationMs)
        case .drag(let fromLabel, let toLabel):
            return .drag(fromLabel: transform(fromLabel), toLabel: transform(toLabel))
        case .measure(let name, let action, let until, let maxSeconds):
            return .measure(name: name, action: action.mappingValues(transform),
                            until: transform(until), maxSeconds: maxSeconds)
        case .pressKey(let key, let modifiers):
            return .pressKey(keyName: transform(key), modifiers: modifiers)
        case .home, .shake, .switchTarget, .skipped, .invalid:
            return self
        }
    }

    /// A value quoted for a structured replay value: in double quotes, or in single
    /// quotes when it holds a `"`, as mirroir-run writes it. Nil when it holds both, or
    /// a backslash the map splitter would read as escaping the closing quote: no quoting
    /// carries those through the parser intact.
    private static func quoted(_ value: String) -> String? {
        if value.hasSuffix("\\") || value.contains("\\\"") || value.contains("\\'") {
            return nil
        }
        switch (value.contains("\""), value.contains("'")) {
        case (false, _): return "\"\(value)\""
        case (true, false): return "'\(value)'"
        case (true, true): return nil
        }
    }

    /// A plain value as the parser reads it back: bare, unless the parser would strip
    /// quotes from it (a value wrapped in quotes, or a lone quote character), so it
    /// gets one more pair for the parser to remove.
    private static func bare(_ value: String) -> String {
        let stripped = (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        return stripped ? "\"\(value)\"" : value
    }
}
