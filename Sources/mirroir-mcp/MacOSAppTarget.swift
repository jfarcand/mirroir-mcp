// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Self-contained target module for native macOS apps (Telegram, Claude Desktop, Chrome, etc.).
// ABOUTME: Owns its profile, legacy config-type strings, and TargetContext builder using GenericWindowBridge.

import Foundation
import HelperLib

/// Self-contained bundle for native macOS app targets. Declares its config-type
/// names (current "macos-app" and legacy "generic-window"), its profile constant,
/// and the `build` factory used by the TargetKind registry.
enum MacOSAppTarget {
    /// Canonical config-type string for new `targets.json` entries.
    static let configTypeName = "macos-app"
    /// Legacy config-type string kept for backward compatibility with existing
    /// `targets.json` files that predate the self-contained target restructure.
    static let legacyConfigTypeName = "generic-window"

    /// Layout zones for a macOS-app target. Desktop windows have no mobile-style
    /// safe zone; the entire window is tappable. Orientation-invariant.
    static let desktopZones = LayoutZones(
        safeZone: SafeZoneConfig(minTapYFraction: 0.0, maxTapYFraction: 1.0),
        backButtonFallback: BackButtonFallback(xFraction: 0.02, yFraction: 0.05),
        statusBarZoneFraction: 0.0,
        navBarZoneFraction: 0.06,
        tabBarZoneFraction: 0.94
    )

    /// The capability profile for every macOS-app target.
    static let profile = TargetProfile(
        name: configTypeName,
        displayName: "macOS App",
        coordinateSystem: .desktop,
        cursorMode: .preserving,
        supportsKeyboardShortcuts: true,
        supportsDirectURLOpen: true,
        urlOpenUnsupportedMessage: nil,
        defaultStrategy: .desktop,
        layoutZones: { _ in desktopZones }
    )

    /// Capabilities exposed by `list_targets` for this target.
    /// macOS apps do not expose iPhone-Mirroring-specific menu actions.
    static let capabilities: Set<TargetCapability> = []

    /// Build a fully-wired TargetContext for a macOS app.
    static func build(config: TargetConfig?, name: String) -> TargetContext {
        let bridge = GenericWindowBridge(
            targetName: name,
            bundleID: config?.bundleID ?? "",
            processName: config?.processName,
            windowTitleContains: config?.windowTitleContains
        )
        let capture = ScreenCapture(bridge: bridge)
        let describers = MirroirMCP.buildDescribers(
            bridge: bridge, capture: capture,
            isMobile: profile.coordinateSystem == .mobile
        )
        return TargetContext(
            name: name,
            targetType: config?.type ?? configTypeName,
            bundleID: config?.bundleID,
            profile: profile,
            bridge: bridge,
            input: InputSimulation(bridge: bridge, cursorMode: profile.cursorMode,
                                   pasteVerifier: describers.ocr),
            capture: capture,
            describer: describers.describer,
            ocrDescriber: describers.ocr,
            recorder: ScreenRecorder(bridge: bridge),
            backtracker: KeyboardShortcutBacktracker.cmdBracket,
            lifecycle: MacOSAppLifecycle(),
            capabilities: capabilities
        )
    }
}
