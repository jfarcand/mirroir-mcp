// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Target composite protocol — bundles window bridge, input, OCR, back-nav, and lifecycle for one automation target.
// ABOUTME: Replaces the string-typed `targetType` polymorphism with a typed capability composition.

import Foundation
import HelperLib

/// Composite describing everything needed to automate one target (iPhone Mirroring
/// window, a native macOS app, a simulator, etc.).
///
/// A `Target` is built by composing:
/// - a `WindowBridging` (how to locate the window, activate it, detect state)
/// - an `InputProviding` (how to tap, swipe, type — CGEvent-based today)
/// - a `ScreenCapturing` + `ScreenDescribing` (how to see and interpret the window)
/// - a `Backtracking` (how to navigate one screen back)
/// - an `AppLifecycleHandling` (how to launch and force-quit the app)
/// - a `TargetProfile` (pure metadata driving behavioral decisions)
///
/// Call sites that previously branched on `ctx.targetType == "iphone-mirroring"`
/// should query `target.profile.X` (a specific capability bit) instead.
protocol Target: Sendable {
    /// Metadata describing this target's capabilities. Drives all behavioral branches.
    var profile: TargetProfile { get }
    /// Window discovery, activation, and state detection.
    var bridge: any WindowBridging { get }
    /// Tap, swipe, type, press-key input provider.
    var input: any InputProviding { get }
    /// Screenshot capture from the target window.
    var capture: any ScreenCapturing { get }
    /// Screen description the client asked for (`describe_screen`): local OCR,
    /// or the paid vision model when `screenDescriberMode` is `vision`.
    var describer: any ScreenDescribing { get }
    /// Always local OCR. Server-internal checks that merely look for known text
    /// (launch confirmation, back chevron, switcher card, scroll target) use
    /// this one, so bookkeeping never spends a vision call the client did not request.
    var ocrDescriber: any ScreenDescribing { get }
    /// Video recording of the target window.
    var recorder: any ScreenRecording { get }
    /// Strategy for returning to the previous screen (OCR chevron tap vs. keyboard shortcut).
    var backtracker: any Backtracking { get }
    /// Strategy for launching and force-quitting the app.
    var lifecycle: any AppLifecycleHandling { get }
}
