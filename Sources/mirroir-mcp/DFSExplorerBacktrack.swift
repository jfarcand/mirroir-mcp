// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Back navigation methods for DFSExplorer: tap back button, verify backtrack, fast-backtrack.
// ABOUTME: Extracted from DFSExplorer.swift to keep files under the 500-line limit.

import Foundation
import HelperLib

extension DFSExplorer {

    // MARK: - Back Navigation Constants

    /// Fraction of window width for the canonical back button X position.
    /// iOS UINavigationBar back buttons sit at roughly 11% from the left edge.
    static let backButtonXFraction = 0.112

    /// Fraction of window height for the canonical back button Y position.
    /// iOS UINavigationBar back buttons sit at roughly 13.5% from the top.
    static let backButtonYFraction = 0.135

    // MARK: - Back Button Tap

    /// Find and tap the "<" back button on the current screen.
    /// iPhone Mirroring does not support iOS edge-swipe-back gestures (neither
    /// scroll wheel nor touch-drag triggers UIScreenEdgePanGestureRecognizer).
    /// Tapping the OCR-detected back chevron is the only reliable backtrack method.
    ///
    /// First attempts to find the "<" chevron via OCR elements. If OCR misses the
    /// back button (which happens on some screen types), falls back to tapping at
    /// the canonical iOS navigation bar back button position.
    ///
    /// - Parameters:
    ///   - elements: OCR elements from the current screen (avoids redundant OCR call).
    ///   - input: Input provider for tap actions.
    /// - Returns: `true` if a back button was found and tapped (always true with fallback).
    func tapBackButton(elements: [TapPoint], input: InputProviding) -> Bool {
        let topZone = windowSize.height * NavigationHintDetector.topZoneFraction
        if let backButton = elements.first(where: { element in
            let trimmed = element.text.trimmingCharacters(in: .whitespaces)
            return NavigationHintDetector.backChevronPatterns.contains(trimmed)
                && element.tapY <= topZone
        }) {
            _ = input.tap(x: backButton.tapX, y: backButton.tapY)
            usleep(EnvConfig.stepSettlingDelayMs * 1000)
            return true
        }

        // OCR sometimes fails to detect the "<" chevron, but the back button is
        // at a predictable position in the iOS navigation bar. Tap there as fallback.
        let fallbackX = windowSize.width * Self.backButtonXFraction
        let fallbackY = windowSize.height * Self.backButtonYFraction
        _ = input.tap(x: fallbackX, y: fallbackY)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)
        return true
    }

    // MARK: - Backtrack with Verification

    /// Backtrack from the current screen to its parent, verifying the result.
    ///
    /// Decides which backtrack method to use (back button tap, press home, or none),
    /// executes it, then verifies the screen actually changed to the expected parent
    /// using OCR + structural similarity. Retries once on mismatch.
    func performBacktrack<S: ExplorationStrategy>(
        currentFP: String,
        input: InputProviding,
        describer: ScreenDescribing,
        strategy: S.Type,
        hints: [String],
        elements: [TapPoint]
    ) -> ExploreStepResult {
        lock.lock()
        let stackDepth = backtrackStack.count
        lock.unlock()

        // Can't backtrack past root
        guard stackDepth > 1 else {
            lock.lock()
            isFinished = true
            lock.unlock()
            return .finished(bundle: generateBundle())
        }

        // Frontier-aware backtrack: check if a shallower ancestor has higher-value
        // unvisited elements than the immediate parent. If so, backtrack directly there.
        if let frontierResult = performFrontierBacktrackIfNeeded(
            stackDepth: stackDepth, input: input, describer: describer, elements: elements
        ) {
            return frontierResult
        }

        // Check if the incoming edge tells us how to backtrack
        let incomingEdge = graph.incomingEdge(to: currentFP)
        let edgeBasedBacktrack = incomingEdge.map { edge -> Bool in
            switch edge.edgeType {
            case .modal:
                // Dismiss modal: find Close/Done/Cancel button and tap it
                if let dismissTarget = EdgeClassifier.findDismissTarget(
                    elements: elements, screenHeight: windowSize.height
                ) {
                    _ = input.tap(x: dismissTarget.tapX, y: dismissTarget.tapY)
                    usleep(EnvConfig.stepSettlingDelayMs * 1000)
                    return true
                }
                // Fall through to default backtracking if no dismiss button found
                return false
            case .tab:
                // Tab switch: find the original tab element and tap it
                if let sourceNode = graph.node(for: incomingEdge?.fromFingerprint ?? "") {
                    let tabBarZone = windowSize.height * EdgeClassifier.tabBarZoneFraction
                    if let tabElement = sourceNode.elements.first(where: { $0.tapY >= tabBarZone }) {
                        _ = input.tap(x: tabElement.tapX, y: tabElement.tapY)
                        usleep(EnvConfig.stepSettlingDelayMs * 1000)
                        return true
                    }
                }
                return false
            case .dead:
                // Dead end: press Home to escape
                _ = input.pressKey(keyName: "h", modifiers: ["command", "shift"])
                usleep(EnvConfig.stepSettlingDelayMs * 1000)
                return true
            case .push, .same:
                return false
            }
        } ?? false

        if !edgeBasedBacktrack {
            let backtrackAction = strategy.backtrackMethod(
                currentHints: hints, depth: stackDepth - 1
            )

            // Execute backtrack action by tapping the "<" back button.
            // iPhone Mirroring does not support iOS edge-swipe-back gestures,
            // so tapping the OCR-detected back chevron is the only reliable method.
            // tapBackButton always succeeds (falls back to canonical position if OCR misses the chevron).
            switch backtrackAction {
            case .pressBack, .tapBack:
                _ = tapBackButton(elements: elements, input: input)
            case .pressHome:
                _ = input.pressKey(keyName: "h", modifiers: ["command", "shift"])
            case .none:
                lock.lock()
                isFinished = true
                lock.unlock()
                return .finished(bundle: generateBundle())
            }
        }

        lock.lock()
        let fromFP = backtrackStack.removeLast()
        let expectedParentFP = backtrackStack.last ?? graph.rootFingerprint
        actionsOnCurrentScreen = 0
        lock.unlock()

        // Verify the backtrack actually reached the expected parent screen.
        // If tapBackButton missed or hit the wrong element, the graph would desync
        // from the physical screen, causing duplicate node creation on subsequent taps.
        let resolvedParentFP = verifyBacktrack(
            expectedFP: expectedParentFP, fromFP: fromFP,
            elements: elements, input: input, describer: describer
        )

        graph.setCurrentFingerprint(resolvedParentFP)

        return .backtracked(from: fromFP, to: resolvedParentFP)
    }

    // MARK: - Backtrack Verification

    /// Verify that a backtrack action reached the expected parent screen.
    ///
    /// OCRs the current screen after tapping back and checks whether it matches
    /// the expected parent node using structural similarity. If the screen doesn't
    /// match, retries the back tap once. If still mismatched, uses `findMatchingNode`
    /// to identify the actual screen and correct the backtrack stack.
    ///
    /// - Parameters:
    ///   - expectedFP: The fingerprint of the screen we expect to land on.
    ///   - fromFP: The fingerprint of the screen we're backtracking from.
    ///   - elements: OCR elements from before the backtrack (for retry).
    ///   - input: Input provider for tap actions.
    ///   - describer: Screen describer for OCR.
    /// - Returns: The fingerprint of the screen we actually landed on.
    func verifyBacktrack(
        expectedFP: String,
        fromFP: String,
        elements: [TapPoint],
        input: InputProviding,
        describer: ScreenDescribing
    ) -> String {
        guard let afterResult = describer.describe(skipOCR: false) else {
            // OCR failed — trust the expected parent as fallback
            return expectedFP
        }

        // Check if we landed on the expected parent
        if let expectedNode = graph.node(for: expectedFP),
           StructuralFingerprint.areEquivalentTitleAware(expectedNode.elements, afterResult.elements) {
            return expectedFP
        }

        // Mismatch: retry the back tap once with fresh OCR elements
        _ = tapBackButton(elements: afterResult.elements, input: input)

        guard let retryResult = describer.describe(skipOCR: false) else {
            return expectedFP
        }

        if let expectedNode = graph.node(for: expectedFP),
           StructuralFingerprint.areEquivalentTitleAware(expectedNode.elements, retryResult.elements) {
            return expectedFP
        }

        // Still mismatched — identify where we actually are
        if let matchedFP = graph.findMatchingNode(elements: retryResult.elements) {
            // Correct the backtrack stack to reflect actual position
            lock.lock()
            if let idx = backtrackStack.lastIndex(of: matchedFP) {
                // Pop stack down to the matched node
                while backtrackStack.count > idx + 1 {
                    backtrackStack.removeLast()
                }
            }
            lock.unlock()
            return matchedFP
        }

        // No known node matches — trust the expected parent as best guess
        return expectedFP
    }

    // MARK: - Frontier-Aware Backtrack

    /// Frontier-aware backtrack that jumps to the best ancestor with unvisited elements.
    /// Uses `FrontierPlanner` to score all ancestors and their unvisited elements,
    /// then navigates directly to the highest-value one.
    ///
    /// Triggers when:
    /// 1. Stack depth > 2 (at least 2 levels above root)
    /// 2. A frontier target exists that is shallower than the immediate parent
    ///
    /// Subsumes the previous fast-backtrack-to-root behavior by generalizing it:
    /// tabRoot screens naturally score higher due to the tabRootBonus.
    func performFrontierBacktrackIfNeeded(
        stackDepth: Int,
        input: InputProviding,
        describer: ScreenDescribing,
        elements: [TapPoint]
    ) -> ExploreStepResult? {
        guard stackDepth > 2 else { return nil }

        lock.lock()
        let stack = backtrackStack
        lock.unlock()

        guard let target = FrontierPlanner.bestTarget(
            graph: graph, backtrackStack: stack, screenHeight: windowSize.height
        ) else {
            return nil
        }

        // Only jump if the frontier target is shallower than the immediate parent
        let parentDepth = graph.node(for: stack[stack.count - 2])?.depth ?? (stackDepth - 2)
        guard target.depth < parentDepth else { return nil }

        // Calculate how many levels to backtrack
        guard let targetIndex = stack.firstIndex(of: target.fingerprint) else { return nil }
        let stepsBack = stack.count - 1 - targetIndex

        var currentElements = elements
        for _ in 0..<stepsBack {
            guard tapBackButton(elements: currentElements, input: input) else { break }
            if let result = describer.describe(skipOCR: false) {
                currentElements = result.elements
            }
        }

        lock.lock()
        let previousFP = backtrackStack.last ?? ""
        // Pop stack down to the target
        while backtrackStack.count > targetIndex + 1 {
            backtrackStack.removeLast()
        }
        actionsOnCurrentScreen = 0
        lock.unlock()

        graph.setCurrentFingerprint(target.fingerprint)

        return .backtracked(from: previousFP, to: target.fingerprint)
    }
}
