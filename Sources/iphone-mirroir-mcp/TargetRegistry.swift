// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Multi-target registry that tracks all configured window targets.
// ABOUTME: Maintains an active target and resolves per-call target overrides.

import Foundation
import HelperLib
import os

/// Capabilities that may or may not be available for a given target type.
/// Exposed in list_targets output so AI clients know which tools work on each target.
/// Runtime gating uses protocol conformance (e.g. `as? MenuActionCapable`).
enum TargetCapability: String, Sendable, Codable {
    case menuActions
    case spotlight
    case home
    case appSwitcher
}

/// All subsystems needed to interact with a single target.
struct TargetContext: Sendable {
    let name: String
    let bridge: any WindowBridging
    let input: any InputProviding
    let capture: any ScreenCapturing
    let describer: any ScreenDescribing
    let recorder: any ScreenRecording
    let capabilities: Set<TargetCapability>
}

/// Registry of all configured targets with an active-target model.
///
/// Thread-safe: the active target name is protected by an unfair lock.
/// The targets dictionary is immutable after construction.
final class TargetRegistry: @unchecked Sendable {
    private let targets: [String: TargetContext]
    private let lock = OSAllocatedUnfairLock(initialState: "")

    init(targets: [String: TargetContext], defaultName: String) {
        precondition(!targets.isEmpty, "TargetRegistry requires at least one target")
        precondition(
            targets[defaultName] != nil,
            "TargetRegistry default '\(defaultName)' not found in targets: \(targets.keys.sorted())"
        )
        self.targets = targets
        self.lock.withLock { $0 = defaultName }
    }

    /// Resolve a target by name. If name is nil, returns the active target.
    func resolve(_ name: String? = nil) -> TargetContext? {
        let resolved = name ?? lock.withLock { $0 }
        return targets[resolved]
    }

    /// Switch the active target. Returns false if the name is unknown.
    func switchActive(to name: String) -> Bool {
        guard targets[name] != nil else { return false }
        lock.withLock { $0 = name }
        return true
    }

    /// The currently active target context.
    var activeTarget: TargetContext {
        let name = lock.withLock { $0 }
        // The active target name is always valid — set only via switchActive
        // which guards against unknown names, or via init which is caller-validated.
        return targets[name]!  // swiftlint:disable:this force_unwrapping
    }

    /// Name of the currently active target.
    var activeTargetName: String {
        lock.withLock { $0 }
    }

    /// All configured targets.
    var allTargets: [TargetContext] {
        targets.values.sorted { $0.name < $1.name }
    }

    /// All configured target names.
    var allTargetNames: [String] {
        targets.keys.sorted()
    }

    /// Number of configured targets.
    var count: Int {
        targets.count
    }

    /// Resolve a target from MCP tool args, returning an error result on failure.
    /// Eliminates the resolve+guard boilerplate repeated across tool handlers.
    func resolveForTool(_ args: [String: JSONValue]) -> (TargetContext?, MCPToolResult?) {
        if let ctx = resolve(args["target"]?.asString()) {
            return (ctx, nil)
        }
        return (nil, .error("Unknown target '\(args["target"]?.asString() ?? "")'"))
    }
}
