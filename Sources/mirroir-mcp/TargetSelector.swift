// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The `target:` step's selector — which configured target the following steps drive.
// ABOUTME: Parses the shared grammar's inline map (`{ kind: ios, app: … }`) and resolves it against the registry.

import Foundation

/// Which configured target a `target:` step switches to.
///
/// The shared scenario grammar spells a target as a map naming its kind — the
/// same shape mirroir-run parses — so one file reads the same on both sides.
/// The iPhone is `{ kind: ios }`; a desktop window configured in
/// `targets.json` is `{ kind: macos, name: "<name>" }`.
enum TargetSelector: Equatable, Sendable {
    /// The registry's iPhone Mirroring target. `app` names the app the steps
    /// drive; launching it is the scenario's own `launch:` step.
    case ios(app: String?)
    /// A desktop window target configured in `targets.json` under `name`.
    case macos(name: String)

    /// The selector as a scenario spells it.
    var displayName: String {
        switch self {
        case .ios(let app?): return "{ kind: ios, app: \"\(app)\" }"
        case .ios(nil): return "{ kind: ios }"
        case .macos(let name): return "{ kind: macos, name: \"\(name)\" }"
        }
    }

    /// The `app` or `name` the selector carries, if any.
    var labelValue: String? {
        switch self {
        case .ios(let app): return app
        case .macos(let name): return name
        }
    }

    /// Parse the value of a `target:` step.
    ///
    /// Only the inline map form is accepted. A bare name is refused with the
    /// map that replaces it, and a `kind` mirroir-mcp does not drive is refused
    /// by name — it belongs to mirroir-run.
    static func parse(_ raw: String) -> Result<TargetSelector, TargetSelectorError> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            return .failure(.notAMap(raw: trimmed))
        }
        let body = String(trimmed.dropFirst().dropLast())
        var fields: [String: String] = [:]
        for entry in splitTopLevel(body) {
            guard let colon = entry.firstIndex(of: ":") else {
                return .failure(.malformedEntry(entry: entry))
            }
            let key = entry[..<colon].trimmingCharacters(in: .whitespaces)
            let value = SkillParser.stripQuotes(
                entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            fields[key] = value
        }
        guard let kind = fields["kind"], !kind.isEmpty else {
            return .failure(.missingKind)
        }
        switch kind {
        case "ios":
            let app = fields["app"].flatMap { $0.isEmpty ? nil : $0 }
            return .success(.ios(app: app))
        case "macos":
            guard let name = fields["name"], !name.isEmpty else {
                return .failure(.macosWithoutName)
            }
            return .success(.macos(name: name))
        default:
            return .failure(.kindNotDrivenHere(kind: kind))
        }
    }

    /// Resolve the selector to a configured target.
    ///
    /// - Returns: the target, or the reason no configured target matches.
    func resolve(in registry: TargetRegistry) -> Result<TargetContext, TargetSelectorError> {
        switch self {
        case .ios:
            let phones = registry.allTargets.filter {
                $0.targetType == IPhoneMirroringTarget.configTypeName
            }
            guard let phone = phones.first else {
                return .failure(.noIPhoneTarget(configured: registry.allTargetNames))
            }
            return .success(phone)
        case .macos(let name):
            guard let target = registry.resolve(name) else {
                return .failure(.unknownTarget(name: name, configured: registry.allTargetNames))
            }
            guard target.targetType != IPhoneMirroringTarget.configTypeName else {
                return .failure(.nameIsTheIPhone(name: name))
            }
            return .success(target)
        }
    }

    /// Split a flow-map body on commas that sit outside double quotes.
    private static func splitTopLevel(_ body: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var previous: Character?
        for char in body {
            if char == "\"" && previous != "\\" {
                inQuotes.toggle()
            }
            if char == "," && !inQuotes {
                entries.append(current)
                current = ""
            } else {
                current.append(char)
            }
            previous = char
        }
        entries.append(current)
        return entries
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Why a `target:` value could not be parsed or resolved.
enum TargetSelectorError: LocalizedError, Equatable {
    /// The value is a bare name instead of the `{ kind: … }` map.
    case notAMap(raw: String)
    /// A map entry has no `key: value` separator.
    case malformedEntry(entry: String)
    /// The map names no `kind`.
    case missingKind
    /// `kind: macos` without the `targets.json` name of the window to drive.
    case macosWithoutName
    /// A surface mirroir-run drives, not mirroir-mcp.
    case kindNotDrivenHere(kind: String)
    /// `kind: ios`, but no iPhone Mirroring target is configured.
    case noIPhoneTarget(configured: [String])
    /// `kind: macos` names a target `targets.json` does not configure.
    case unknownTarget(name: String, configured: [String])
    /// `kind: macos` names the iPhone Mirroring target.
    case nameIsTheIPhone(name: String)

    var errorDescription: String? {
        switch self {
        case .notAMap(let raw):
            return "target: \(raw) is a bare name; spell the target as a map — " +
                "{ kind: ios } for the iPhone, { kind: macos, name: \"<targets.json name>\" } for a window"
        case .malformedEntry(let entry):
            return "target: map entry '\(entry)' is not `key: value`"
        case .missingKind:
            return "target: map declares no `kind`"
        case .macosWithoutName:
            return "target: { kind: macos } needs the `name` of the targets.json window to drive"
        case .kindNotDrivenHere(let kind):
            return "target: { kind: \(kind) } is not a surface mirroir-mcp drives; " +
                "web, process, and http scenarios run in mirroir-run"
        case .noIPhoneTarget(let configured):
            return "target: { kind: ios } — no iPhone Mirroring target is configured " +
                "(targets: \(configured.joined(separator: ", ")))"
        case .unknownTarget(let name, let configured):
            return "target: no target named '\(name)' (targets: \(configured.joined(separator: ", ")))"
        case .nameIsTheIPhone(let name):
            return "target: '\(name)' is the iPhone Mirroring target; select it with { kind: ios }"
        }
    }
}
