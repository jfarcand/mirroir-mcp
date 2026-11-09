// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: TargetProfile — pure value type describing an automation target's capabilities, user-facing messages, and orientation-aware layout zones.
// ABOUTME: Per-target profile constants live in the target-specific file (IPhoneMirroringTarget, MacOSAppTarget, …).

import Foundation
import HelperLib

/// How tap coordinates and safe zones are interpreted for this target.
enum CoordinateSystem: String, Sendable {
    /// iOS-style viewport with a status bar at top and a tab bar / home indicator at bottom.
    /// Safe-zone stencils reject taps outside the app content area.
    case mobile
    /// Desktop window with arbitrary content layout. No mobile-specific safe zones.
    case desktop
}

/// Vertical safe-zone stencil for rejecting invalid tap targets.
/// Both bounds are fractions of the window height so the same config scales
/// across orientations (portrait 410×890 vs landscape 868×440).
struct SafeZoneConfig: Sendable {
    /// Minimum tap Y as a fraction of window height. Taps above this are rejected
    /// as "in status bar / status HUD zone".
    let minTapYFraction: Double
    /// Maximum tap Y as a fraction of window height. Taps below this are rejected
    /// unless the element is marked as breadth-navigation (tab bar).
    let maxTapYFraction: Double
}

/// Fallback canonical position for an OCR-detected back chevron that failed to
/// detect. Expressed as fractions of window width × height so the same config
/// scales across orientations.
struct BackButtonFallback: Sendable {
    let xFraction: Double
    let yFraction: Double
}

/// Layout zones that vary per target (and, for iPhone Mirroring, per orientation).
/// All fields are fractions of the current window dimensions — no absolute pixels.
struct LayoutZones: Sendable {
    /// Tap-acceptance stencil for the explorer.
    let safeZone: SafeZoneConfig
    /// Canonical back-button position used when OCR fails to detect a chevron.
    let backButtonFallback: BackButtonFallback
    /// Top-of-window fraction considered "status bar" for element classification.
    let statusBarZoneFraction: Double
    /// Top-of-window fraction considered "nav bar" for component matching.
    let navBarZoneFraction: Double
    /// Fraction above which elements are considered "tab bar" for edge classification.
    let tabBarZoneFraction: Double
}

/// Capability metadata describing how an automation target behaves.
///
/// Every behavioral branch that previously checked `targetType == "iphone-mirroring"`
/// or a shadow `isMobile: Bool` flag queries a field on this struct instead. Each
/// target module (IPhoneMirroringTarget, MacOSAppTarget, …) declares its own
/// profile constant — this file stays as a pure value type.
struct TargetProfile: Sendable {
    /// Stable target identifier used for telemetry and config-file lookup.
    /// Not used for runtime behavior branching.
    let name: String
    /// Human-readable name for error messages ("iPhone Mirroring", "Telegram").
    let displayName: String
    /// Coordinate-system interpretation for safe zones, tab bar detection, etc.
    let coordinateSystem: CoordinateSystem
    /// Cursor behavior for tap/swipe/drag actions.
    let cursorMode: CursorMode
    /// The operations that exist on this target. One it lacks is refused with
    /// `refusal(of:targetName:supportedOn:)`, never emulated.
    let operations: Set<TargetOperation>
    /// Default exploration strategy when no explicit override or recipe match applies.
    let defaultStrategy: StrategyChoice
    /// Orientation-aware layout zones. Accepts the current `DeviceOrientation`
    /// (from `WindowBridging.getOrientation()`) so targets that care (iPhone
    /// Mirroring) can return portrait vs landscape configurations. Targets that
    /// do not care (macOS apps) ignore the argument and return a single zone.
    let layoutZones: @Sendable (DeviceOrientation?) -> LayoutZones
}
