// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decides whether a coordinate-only tap reached the screen it reached when recorded.
// ABOUTME: Records each step's screen at record_step; a tap to a bare or unchanged screen is refused.

import HelperLib

/// The check a tap recorded by coordinates alone (an icon with no text) gets
/// instead of a label: the screen it reaches must match the one it reached when
/// recorded. Only multi-character structural texts count — single characters
/// are mostly keyboard keys, which would swamp the few labels that identify a
/// screen — and a screen with fewer than `compiledTapArrivalMinTexts` of them
/// cannot prove anything, so it is refused rather than matched.
enum ArrivalCheck {

    /// The texts two screens are compared on.
    static func comparableTexts(_ fingerprint: ScreenFingerprint) -> Set<String> {
        Set(fingerprint.structuralTexts.filter { $0.count > 1 })
    }

    /// Whether `fingerprint` holds enough text to tell its screen from another.
    static func isCheckable(_ fingerprint: ScreenFingerprint) -> Bool {
        comparableTexts(fingerprint).count >= EnvConfig.compiledTapArrivalMinTexts
    }

    /// Jaccard similarity of the two screens' comparable texts (0.0–1.0).
    static func similarity(_ lhs: ScreenFingerprint, _ rhs: ScreenFingerprint) -> Double {
        let left = comparableTexts(lhs)
        let right = comparableTexts(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return StructuralFingerprint.similarity(left, right)
    }

    /// Whether `reached` is the screen `arrival` recorded.
    static func matches(_ arrival: ScreenFingerprint, _ reached: ScreenFingerprint) -> Bool {
        similarity(arrival, reached) >= StructuralFingerprint.similarityThreshold
    }

    // MARK: - Recording

    /// Why a coordinate-only tap's destination could not be recorded.
    struct ArrivalRefusal: Error {
        let reason: String
    }

    /// Read the settled screen a step left on display — on screen now, since
    /// `record_step` follows the action — and keep it as the screen the next
    /// step starts from. For a coordinate-only tap it is also the destination
    /// replay must reach, returned on success; any other step returns nil.
    /// A tap is refused when replay could not check it: a later step is already
    /// recorded, its destination is unreadable or too bare, or the screen before
    /// it is unknown or unchanged (the tap did nothing).
    static func observe(
        stepIndex: Int, coordinateOnlyTap: Bool,
        session: CompilationSession, target: any Target
    ) -> Result<ScreenFingerprint?, ArrivalRefusal> {
        if coordinateOnlyTap, let later = session.recordedSteps.map(\.index).max(), later > stepIndex {
            return .failure(ArrivalRefusal(reason:
                "Step \(later) is already recorded, so the screen on display is not the one " +
                "coordinate-only tap \(stepIndex) led to. Record it right after the tap."))
        }
        let fingerprint = target.ocrDescriber.describe(
            settleTimeoutUs: EnvConfig.frameSettleTimeoutUs).map {
                StructuralFingerprint.buildScreenFingerprint(elements: $0.elements, icons: $0.icons)
            }
        guard coordinateOnlyTap else {
            session.noteScreen(fingerprint, after: stepIndex)
            return .success(nil)
        }
        guard let fingerprint else {
            return .failure(ArrivalRefusal(reason:
                "Could not read the screen this coordinate-only tap led to, so replay could " +
                "not check it. Call record_step again once the screen has settled."))
        }
        guard isCheckable(fingerprint) else {
            return .failure(ArrivalRefusal(reason:
                "The screen this coordinate-only tap led to shows fewer than " +
                "\(EnvConfig.compiledTapArrivalMinTexts) readable labels, so replay could not " +
                "tell it from another screen. Tap a labeled element instead."))
        }
        guard let before = session.screenBefore(step: stepIndex) else {
            let source = stepIndex == 0
                ? "get_skill did not read the start screen. Call get_skill before the first step"
                : "the screen after step \(stepIndex - 1) was not read. Go back to that screen, " +
                  "call record_step for step \(stepIndex - 1) again"
            return .failure(ArrivalRefusal(reason:
                "Cannot tell whether coordinate-only tap \(stepIndex) changed the screen: " +
                "\(source), then redo the tap and record it."))
        }
        guard !matches(fingerprint, before) else {
            return .failure(ArrivalRefusal(reason:
                "Coordinate-only tap \(stepIndex) did not change the screen (similarity " +
                "\(String(format: "%.2f", similarity(fingerprint, before))) with the screen before it), " +
                "so replay could never prove it. Tap again until the screen changes, then " +
                "call record_step."))
        }
        session.noteScreen(fingerprint, after: stepIndex)
        return .success(fingerprint)
    }
}
