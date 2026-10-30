// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Central registry mapping config-type strings to self-contained target builders.
// ABOUTME: Adding a new target kind (Android via ADB, iOS Simulator, …) = one new *Target.swift file + one line here.

import Foundation
import HelperLib

/// Registry of target builders keyed by config-type string (the `type` field in
/// `targets.json`). Each target module declares its own config-type names and a
/// `build` factory — this file only wires them up.
enum TargetKind {
    /// A factory that produces a fully-wired `TargetContext` from an optional
    /// `TargetConfig` and a target name. Targets that predate explicit config
    /// accept a `nil` config for default initialization.
    typealias Builder = @Sendable (_ config: TargetConfig?, _ name: String) -> TargetContext

    /// All registered target builders. Keys are the config-type strings accepted
    /// in `targets.json`. A single target may register multiple aliases (e.g.
    /// macOS-app has the canonical "macos-app" plus legacy "generic-window").
    static let builders: [String: Builder] = [
        IPhoneMirroringTarget.configTypeName: IPhoneMirroringTarget.build,
        MacOSAppTarget.configTypeName: MacOSAppTarget.build,
        MacOSAppTarget.legacyConfigTypeName: MacOSAppTarget.build,
    ]

    /// Profile lookup by config-type string. Used by `StrategyDetector` and
    /// other read-only sites that need the profile without building a full
    /// target. Unknown types fall back to the macOS-app profile (conservative —
    /// no iOS-only safe-zones applied to unfamiliar targets).
    static let profiles: [String: TargetProfile] = [
        IPhoneMirroringTarget.configTypeName: IPhoneMirroringTarget.profile,
        MacOSAppTarget.configTypeName: MacOSAppTarget.profile,
        MacOSAppTarget.legacyConfigTypeName: MacOSAppTarget.profile,
    ]

    /// Look up a profile by legacy config-type string. Returns the macOS-app
    /// profile for unknown values so call sites can treat the result as
    /// non-optional.
    static func profile(for configType: String) -> TargetProfile {
        profiles[configType] ?? MacOSAppTarget.profile
    }

    /// Build a `TargetContext` from a parsed `TargetConfig`, or `nil` if the
    /// config-type string is unknown.
    static func build(config: TargetConfig, name: String) -> TargetContext? {
        builders[config.type].map { $0(config, name) }
    }
}
