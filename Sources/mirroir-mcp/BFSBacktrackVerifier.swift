// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Post-backtrack position verification and modal recovery for BFS exploration.
// ABOUTME: Detects when the explorer is lost and attempts recovery before cascading errors.

import Foundation
import HelperLib

/// Result of post-backtrack position verification.
enum BacktrackVerification {
    /// Successfully returned to the expected screen.
    case verified
    /// Returned to a different known screen — graph state corrected.
    case corrected(fingerprint: String)
    /// Explorer is lost — could not identify current screen after recovery attempts.
    case lost
}

extension BFSExplorer {

    // MARK: - Post-Backtrack Verification

    /// Modal dismiss patterns for recovery when the explorer is stuck on a modal sheet.
    /// Includes English and French patterns for iOS Health/Santé app compatibility.
    static let modalDismissPatterns: Set<String> = {
        var patterns = ElementClassifier.dismissCharacters
        patterns.formUnion(MobileAppStrategy.modalDismissPatterns)
        patterns.formUnion(["fermer", "annuler", "terminé"])
        return patterns
    }()

    /// Verify the explorer returned to the expected screen after tapping back.
    /// If the screen doesn't match, attempts recovery in sequence:
    /// 1. Dismiss modal (X, Close, Done, Fermer, Annuler) in top zone
    /// 2. Retry tapBackButton
    /// 3. Match against all known screens to correct graph state
    ///
    /// Prevents cascading errors when the explorer gets stuck on an unexpected
    /// screen (modal articles, deep sub-views, system sheets).
    func verifyBacktrack(
        expectedFP: String,
        afterElements: [TapPoint],
        describer: ScreenDescribing,
        input: InputProviding
    ) -> BacktrackVerification {
        // OCR the screen after backtrack
        guard let result = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) else {
            DebugLog.log("bfs", "backtrack-verify: OCR failed after back tap")
            return .lost
        }

        // Check if we landed on the expected screen
        if let expectedNode = graph.node(for: expectedFP),
           StructuralFingerprint.areEquivalentTitleAware(expectedNode.elements, result.elements) {
            return .verified
        }

        let ocrTexts = result.elements.map { "\($0.text)@(\(Int($0.tapX)),\(Int($0.tapY)))" }
        DebugLog.log("bfs", "backtrack-verify: screen mismatch — " +
            "\(result.elements.count) elements: \(ocrTexts.joined(separator: ", "))")

        // Recovery 1: Try dismissing a modal (X, Close, Done in top 30% zone).
        // App Store modal sheets place the X at ~25% height, so 20% is too narrow.
        let topZone = windowSize.height * 0.30
        if let dismissButton = result.elements.first(where: { el in
            el.tapY <= topZone
            && Self.modalDismissPatterns.contains(
                el.text.trimmingCharacters(in: .whitespaces).lowercased()
            )
        }) {
            DebugLog.log("bfs", "backtrack-verify: tapping dismiss \"\(dismissButton.text)\" " +
                "at (\(Int(dismissButton.tapX)),\(Int(dismissButton.tapY)))")
            _ = input.tap(x: dismissButton.tapX, y: dismissButton.tapY)
            usleep(EnvConfig.stepSettlingDelayMs * 1000)

            if let afterDismiss = ExplorerUtilities.dismissAlertIfPresent(
                describer: describer, input: input
            ) {
                if let expectedNode = graph.node(for: expectedFP),
                   StructuralFingerprint.areEquivalentTitleAware(
                       expectedNode.elements, afterDismiss.elements
                   ) {
                    DebugLog.log("bfs", "backtrack-verify: modal dismiss recovered to expected screen")
                    return .verified
                }
                // Modal dismissed but landed on a different known screen
                if let matchedFP = graph.findMatchingNode(elements: afterDismiss.elements) {
                    DebugLog.log("bfs", "backtrack-verify: modal dismiss → known screen \(matchedFP.prefix(8))")
                    return .corrected(fingerprint: matchedFP)
                }
            }
        }

        // Recovery 2: Retry back button with fresh elements
        DebugLog.log("bfs", "backtrack-verify: retrying back button")
        ExplorerUtilities.tapBackButton(
            elements: result.elements, input: input, windowSize: windowSize
        )

        guard let retryResult = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) else {
            return .lost
        }

        if let expectedNode = graph.node(for: expectedFP),
           StructuralFingerprint.areEquivalentTitleAware(
               expectedNode.elements, retryResult.elements
           ) {
            DebugLog.log("bfs", "backtrack-verify: retry succeeded")
            return .verified
        }

        // Recovery 3: Match against any known screen
        if let matchedFP = graph.findMatchingNode(elements: retryResult.elements) {
            DebugLog.log("bfs", "backtrack-verify: landed on known screen \(matchedFP.prefix(8))")
            return .corrected(fingerprint: matchedFP)
        }

        DebugLog.log("bfs", "backtrack-verify: LOST — unknown screen after 2 recovery attempts")
        return .lost
    }

    /// Tap back and verify the result. Returns an ExploreStepResult if the explorer
    /// is lost (should stop exploring), or nil if backtrack succeeded.
    func tapBackAndVerify(
        expectedFP: String,
        afterElements: [TapPoint],
        describer: ScreenDescribing,
        input: InputProviding
    ) -> ExploreStepResult? {
        ExplorerUtilities.tapBackButton(
            elements: afterElements, input: input, windowSize: windowSize
        )

        let verification = verifyBacktrack(
            expectedFP: expectedFP, afterElements: afterElements,
            describer: describer, input: input
        )

        switch verification {
        case .verified:
            graph.setCurrentFingerprint(expectedFP)
            return nil

        case .corrected(let actualFP):
            graph.setCurrentFingerprint(actualFP)
            DebugLog.log("bfs", "backtrack corrected: expected \(expectedFP.prefix(8)) " +
                "→ actual \(actualFP.prefix(8))")
            return nil

        case .lost:
            lock.lock(); isFinished = true; lock.unlock()
            return .finished(bundle: generateBundle())
        }
    }
}
