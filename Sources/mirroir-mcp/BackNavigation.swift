// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: press_back's logic: go back one screen with the target's own backtracker, then say what was sent
// ABOUTME: (chevron, fallback point or Cmd+[) and whether the screen changed, failing when it did not.

import Foundation
import HelperLib

/// Back navigation for the `press_back` tool.
///
/// It uses the target's backtracker, the one exploration uses: on iPhone
/// Mirroring a tap on the OCR-detected "<" chevron (or the target's fallback
/// point when OCR misses it), on a macOS app Cmd+[, which Mac apps implement
/// and iOS apps do not. The screen is read before and after, so a back press
/// that changed nothing is reported instead of passed off as success.
enum BackNavigation {

    /// Go back one screen on `ctx`'s target.
    static func pressBack(_ ctx: TargetContext) -> MCPToolResult {
        guard ctx.bridge.findProcess() != nil else {
            return .error("Target '\(ctx.name)' is not running")
        }
        if let refusal = ctx.input.ensureConnected(tag: "press_back") {
            return .error(refusal)
        }
        guard let before = ctx.ocrDescriber.describe() else {
            return .error(ScreenReadFailure.message(
                "Failed to capture/analyze screen.", targetName: ctx.name, state: ctx.bridge.getState()))
        }
        guard let info = ctx.bridge.getWindowInfo() else {
            return .error("Cannot determine window size for '\(ctx.name)'")
        }
        let zones = ctx.profile.layoutZones(ctx.bridge.getOrientation())
        let outcome = ctx.backtracker.tapBack(
            elements: before.elements, input: ctx.input,
            windowSize: info.size, fallback: zones.backButtonFallback)
        let after = outcome.issued ? ctx.ocrDescriber.describe()?.elements : nil
        return verdict(outcome, before: before.elements, after: after)
    }

    /// The reply for a back action, given the screen before it and after it
    /// (nil when the screen could not be read afterwards).
    ///
    /// The screen counts as unchanged only when its structural text is the
    /// same non-empty set before and after, so OCR noise reads as a change,
    /// never the other way round, and a text-less screen is left undecided.
    static func verdict(_ outcome: BackOutcome, before: [TapPoint], after: [TapPoint]?) -> MCPToolResult {
        if let error = outcome.error {
            // The input layer also refuses a tap it delivered when the session
            // stopped right after it, so this does not claim nothing was sent.
            return .error("Back (\(outcome.description)) did not complete: \(error)")
        }
        guard let after else {
            return .text("Pressed back: \(outcome.description). The screen could not be read "
                + "afterwards, so whether it changed is unknown; describe the screen.")
        }
        let beforeTexts = StructuralFingerprint.extractStructural(from: before)
        let afterTexts = StructuralFingerprint.extractStructural(from: after)
        if beforeTexts.isEmpty, afterTexts.isEmpty {
            // A screen with no text (a photo, a game, the camera) cannot show a change.
            return .text("Pressed back: \(outcome.description). Neither screen has text to compare, "
                + "so whether it changed is unknown; describe the screen.")
        }
        guard beforeTexts != afterTexts else {
            return .error("Pressed back (\(outcome.description)), but the screen did not change: "
                + "this screen may have no back control there. Describe the screen and choose "
                + "another way back.")
        }
        return .text("Pressed back: \(outcome.description). The screen changed.")
    }
}
