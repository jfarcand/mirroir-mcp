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
        // A Mac window has no Spotlight launcher, Home Screen or App Switcher
        // of the iPhone's, and the iOS shortcuts mean something else in a Mac app.
        operations: [],
        defaultStrategy: .desktop,
        layoutZones: { _ in desktopZones }
    )

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
        // A macOS app reports its own text exactly, so both describers gain
        // it. One decorator when they are the same describer.
        let describer = AccessibilityTreeDescriber(wrapping: describers.describer, bridge: bridge)
        let ocrDescriber = (describers.describer as AnyObject) === (describers.ocr as AnyObject)
            ? describer : AccessibilityTreeDescriber(wrapping: describers.ocr, bridge: bridge)
        return TargetContext(
            name: name,
            targetType: config?.type ?? configTypeName,
            bundleID: config?.bundleID,
            profile: profile,
            bridge: bridge,
            input: FocusObservingInput(
                wrapping: InputSimulation(bridge: bridge, cursorMode: profile.cursorMode,
                                          pasteVerifier: describers.ocr),
                bridge: bridge),
            capture: capture,
            describer: describer,
            ocrDescriber: ocrDescriber,
            recorder: ScreenRecorder(bridge: bridge),
            backtracker: KeyboardShortcutBacktracker.cmdBracket,
            lifecycle: MacOSAppLifecycle()
        )
    }
}
