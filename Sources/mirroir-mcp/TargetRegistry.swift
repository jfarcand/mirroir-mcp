// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Multi-target registry that tracks all configured window targets.
// ABOUTME: Maintains an active target and resolves per-call target overrides.

import Foundation
import HelperLib
import os

/// All subsystems needed to interact with a single target. Conforms to `Target`
/// so callers can use the capability-composition API (`ctx.profile.X`,
/// `ctx.backtracker.tapBack(...)`) without threading through a separate type.
struct TargetContext: Target, Sendable {
    let name: String
    /// Stable legacy identifier ("iphone-mirroring" / "generic-window") kept for
    /// config-file compatibility and telemetry. All runtime behavior should query
    /// `profile.*` instead of comparing this string.
    let targetType: String
    let bundleID: String?
    let profile: TargetProfile
    let bridge: any WindowBridging
    let input: any InputProviding
    let capture: any ScreenCapturing
    let describer: any ScreenDescribing
    let ocrDescriber: any ScreenDescribing
    let recorder: any ScreenRecording
    let backtracker: any Backtracking
    let lifecycle: any AppLifecycleHandling

    /// Canonical initializer: callers provide every capability explicitly.
    init(
        name: String,
        targetType: String,
        bundleID: String?,
        profile: TargetProfile,
        bridge: any WindowBridging,
        input: any InputProviding,
        capture: any ScreenCapturing,
        describer: any ScreenDescribing,
        ocrDescriber: any ScreenDescribing,
        recorder: any ScreenRecording,
        backtracker: any Backtracking,
        lifecycle: any AppLifecycleHandling
    ) {
        self.name = name
        self.targetType = targetType
        self.bundleID = bundleID
        self.profile = profile
        self.bridge = bridge
        self.input = input
        self.capture = capture
        self.describer = describer
        self.ocrDescriber = ocrDescriber
        self.recorder = recorder
        self.backtracker = backtracker
        self.lifecycle = lifecycle
    }

    /// Legacy initializer for existing call sites (tests and targets constructed
    /// outside the `TargetKind` registry). Infers `profile`, `backtracker`, and
    /// `lifecycle` from the `targetType` string by asking `TargetKind` for the
    /// matching profile. New code should use the canonical initializer or the
    /// per-target `build()` factories directly. `ocrDescriber` is the
    /// `describer` itself unless the caller supplies a separate one.
    init(
        name: String,
        targetType: String,
        bundleID: String?,
        bridge: any WindowBridging,
        input: any InputProviding,
        capture: any ScreenCapturing,
        describer: any ScreenDescribing,
        ocrDescriber: (any ScreenDescribing)? = nil,
        recorder: any ScreenRecording
    ) {
        let profile = TargetKind.profile(for: targetType)
        let backtracker: any Backtracking = profile.coordinateSystem == .mobile
            ? OCRChevronBacktracker()
            : KeyboardShortcutBacktracker.cmdBracket
        let lifecycle: any AppLifecycleHandling = profile.coordinateSystem == .mobile
            ? MirroringAppLifecycle()
            : MacOSAppLifecycle()
        self.init(
            name: name, targetType: targetType, bundleID: bundleID,
            profile: profile, bridge: bridge, input: input,
            capture: capture, describer: describer,
            ocrDescriber: ocrDescriber ?? describer, recorder: recorder,
            backtracker: backtracker, lifecycle: lifecycle
        )
    }
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

    /// Resolve a target for a tool that exists only on some targets. A target
    /// that lacks `operation` gets the refusal as its error, before the
    /// handler sends anything.
    func resolveForTool(
        _ args: [String: JSONValue], requiring operation: TargetOperation
    ) -> (TargetContext?, MCPToolResult?) {
        let (ctx, error) = resolveForTool(args)
        guard let ctx else { return (nil, error) }
        if let refusal = refusal(of: operation, on: ctx.profile, named: ctx.name) {
            return (nil, .error(refusal))
        }
        return (ctx, nil)
    }

    /// Why `operation` is refused on a target with `profile`, naming the
    /// configured targets that have it; nil when the target has it.
    func refusal(of operation: TargetOperation, on profile: TargetProfile, named name: String) -> String? {
        profile.refusal(
            of: operation, targetName: name,
            supportedOn: allTargets.filter { $0.profile.supports(operation) }.map(\.name))
    }
}
