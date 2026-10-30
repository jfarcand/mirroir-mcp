// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decides whether a coordinate-only tap reached the screen it reached when recorded.
// ABOUTME: Records that screen at record_step and compares it at replay; screens too bare to tell apart are refused.

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

    /// The settled screen a coordinate-only tap led to — on screen now, since
    /// `record_step` follows the action — or why replay could not check it.
    static func record(
        stepIndex: Int, session: CompilationSession, target: any Target
    ) -> Result<ScreenFingerprint, ArrivalRefusal> {
        if let later = session.recordedSteps.map(\.index).max(), later > stepIndex {
            return .failure(ArrivalRefusal(reason:
                "Step \(later) is already recorded, so the screen on display is not the one " +
                "coordinate-only tap \(stepIndex) led to. Record it right after the tap."))
        }
        guard let screen = target.ocrDescriber.describe(
                settleTimeoutUs: EnvConfig.frameSettleTimeoutUs) else {
            return .failure(ArrivalRefusal(reason:
                "Could not read the screen this coordinate-only tap led to, so replay could " +
                "not check it. Call record_step again once the screen has settled."))
        }
        let fingerprint = StructuralFingerprint.buildScreenFingerprint(
            elements: screen.elements, icons: screen.icons)
        guard ArrivalCheck.isCheckable(fingerprint) else {
            return .failure(ArrivalRefusal(reason:
                "The screen this coordinate-only tap led to shows fewer than " +
                "\(EnvConfig.compiledTapArrivalMinTexts) readable labels, so replay could not " +
                "tell it from another screen. Tap a labeled element instead."))
        }
        return .success(fingerprint)
    }
}
