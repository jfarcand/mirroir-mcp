// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Self-contained target module for real iPhone control via macOS iPhone Mirroring.
// ABOUTME: Owns its profile, legacy config-type strings, target-specific guidance, and TargetContext builder.

import Foundation
import HelperLib

/// Self-contained bundle for the iPhone-Mirroring target. Declares its config-type
/// name, its profile constant (including user-facing error messages), and the
/// `build` factory used by the TargetKind registry. Adding iPhone-specific
/// behavior means editing this file — no other target is affected.
enum IPhoneMirroringTarget {
    /// Config-type string emitted in `targets.json`.
    static let configTypeName = "iphone-mirroring"

    /// Layout zones for a portrait iPhone Mirroring window (standard 410×890).
    /// The status bar sits at the top ~9% of the window; the home indicator /
    /// tab bar at the bottom ~5%; the back chevron at ~(11.2%, 13.5%).
    static let portraitZones = LayoutZones(
        safeZone: SafeZoneConfig(minTapYFraction: 0.09, maxTapYFraction: 0.95),
        backButtonFallback: BackButtonFallback(xFraction: 0.112, yFraction: 0.135),
        statusBarZoneFraction: 0.10,
        navBarZoneFraction: 0.12,
        tabBarZoneFraction: 0.85
    )

    /// Layout zones for a landscape iPhone Mirroring window (standard 868×440).
    /// The iOS landscape status bar is thin (~32pt of ~440pt ≈ 7%) or absent on
    /// full-bleed apps; the back chevron (when present) sits near the top-left
    /// corner at roughly the same X fraction but a smaller Y fraction because
    /// the viewport is shorter.
    static let landscapeZones = LayoutZones(
        safeZone: SafeZoneConfig(minTapYFraction: 0.04, maxTapYFraction: 0.96),
        backButtonFallback: BackButtonFallback(xFraction: 0.057, yFraction: 0.10),
        statusBarZoneFraction: 0.05,
        navBarZoneFraction: 0.08,
        tabBarZoneFraction: 0.88
    )

    /// The capability profile for every iPhone-Mirroring target.
    static let profile = TargetProfile(
        name: configTypeName,
        displayName: "iPhone Mirroring",
        coordinateSystem: .mobile,
        cursorMode: .direct,
        supportsKeyboardShortcuts: false,
        supportsDirectURLOpen: false,
        urlOpenUnsupportedMessage:
            "open_url is not supported for iPhone Mirroring targets. "
            + "Keyboard shortcuts (Cmd+L) do not work through iPhone Mirroring. "
            + "To navigate in Safari: launch Safari, tap the address bar, "
            + "use type_text to enter the URL, then press_key(key: \"return\").",
        defaultStrategy: .mobile,
        layoutZones: { orientation in
            orientation == .landscape ? landscapeZones : portraitZones
        }
    )

    /// Capabilities exposed by `list_targets` for this target.
    static let capabilities: Set<TargetCapability> = [
        .menuActions, .spotlight, .home, .appSwitcher,
    ]

    /// Build a fully-wired TargetContext for iPhone Mirroring.
    static func build(config: TargetConfig?, name: String = "iphone") -> TargetContext {
        let bridge = MirroringBridge(targetName: name, bundleID: config?.bundleID)
        let capture = ScreenCapture(bridge: bridge)
        let describers = MirroirMCP.buildDescribers(
            bridge: bridge, capture: capture,
            isMobile: profile.coordinateSystem == .mobile
        )
        return TargetContext(
            name: name,
            targetType: configTypeName,
            bundleID: config?.bundleID,
            profile: profile,
            bridge: bridge,
            input: InputSimulation(bridge: bridge, cursorMode: profile.cursorMode),
            capture: capture,
            describer: describers.describer,
            ocrDescriber: describers.ocr,
            recorder: ScreenRecorder(bridge: bridge),
            backtracker: OCRChevronBacktracker(),
            lifecycle: MirroringAppLifecycle(),
            capabilities: capabilities
        )
    }
}
