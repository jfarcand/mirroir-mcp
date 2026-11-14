/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Post-backtrack verification, modal recovery, and plateau advisory for BFS exploration.
// ABOUTME: Detects when the explorer is lost and attempts recovery before cascading errors.

import Foundation
import HelperLib

/// Result of post-backtrack position verification.
enum BacktrackVerification {
    /// Successfully returned to the expected screen.
    case verified
    /// Returned to a different known screen — graph state corrected.
    case corrected(fingerprint: String)
    /// A .tab return landed on the tab root with a churned fingerprint —
    /// tab-bar evidence on the first post-return OCR confirms root.
    case tabRootDrift
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
    ///
    /// `edgeType` is the classified type of the edge being reversed. For `.tab`
    /// edges, fingerprint drift on the landed screen is checked on the FIRST
    /// OCR — before any recovery taps, which would themselves navigate into
    /// content on chevron-less tab roots (their blind fallback lands in the
    /// stories row).
    func verifyBacktrack(
        expectedFP: String,
        afterElements: [TapPoint],
        describer: ScreenDescribing,
        input: InputProviding,
        edgeType: EdgeType? = nil
    ) -> BacktrackVerification {
        // OCR the screen after backtrack
        guard let result = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) else {
            DebugLog.log("bfs", "backtrack-verify: OCR failed after back tap")
            return .lost
        }

        // Check if we landed on the expected screen.
        // Two-tier check: Jaccard similarity first (fast, strict), then viewport containment
        // (handles scrolled viewports where Jaccard fails because the viewport is a subset
        // of the full calibrated element set).
        if let expectedNode = graph.node(for: expectedFP) {
            if StructuralFingerprint.areEquivalentTitleAware(expectedNode.elements, result.elements) {
                return .verified
            }
            if StructuralFingerprint.viewportContainedIn(
                viewport: result.elements, reference: expectedNode.elements
            ) {
                DebugLog.log("bfs", "backtrack-verify: viewport contained in expected screen (containment match)")
                return .verified
            }
        }

        let ocrTexts = result.elements.map { "\($0.text)@(\(Int($0.tapX)),\(Int($0.tapY)))" }
        DebugLog.log("bfs", "backtrack-verify: screen mismatch — " +
            "\(result.elements.count) elements: \(ocrTexts.joined(separator: ", "))")

        // Tab-return drift: feed content churns between visits, so a .tab
        // return can land on the tab root with a changed fingerprint. Accept
        // tab-bar evidence (hint present, no back chevron) on this first
        // post-return OCR, before any recovery taps run. A concrete structural
        // match to a KNOWN non-root screen overrides the band evidence — a tab
        // bar is visible on every tab screen, so the evidence cannot
        // discriminate which tab is showing.
        if edgeType == .tab, BFSTabReturn.showsTabRootEvidence(hints: result.hints) {
            let knownMatch = graph.findMatchingNode(elements: result.elements)
            if knownMatch == nil || knownMatch == graph.rootFingerprint {
                DebugLog.log("bfs", "backtrack-verify: tab-return drift — " +
                    "tab-bar evidence on landed screen confirms root")
                return .tabRootDrift
            }
            DebugLog.log("bfs", "backtrack-verify: tab-bar evidence present but screen " +
                "matches known non-root \(knownMatch.map { String($0.prefix(8)) } ?? "") — not root")
        }

        // Recovery 1: Try dismissing a modal (X, Close, Done in top 30% zone).
        // App Store modal sheets place the X at ~25% height, so 20% is too narrow.
        // Two-pass: prefer explicit text matches ("x", "close", "done") over generic
        // YOLO "icon" labels, which can collide with status bar icons.
        let topZone = windowSize.height * 0.30
        let rightHalf = windowSize.width * 0.5
        let statusBarCutoff = windowSize.height * 0.12
        let dismissButton: TapPoint? = {
            // Pass 1: explicit dismiss text (highest confidence)
            if let textMatch = result.elements.first(where: { el in
                guard el.tapY <= topZone else { return false }
                let text = el.text.trimmingCharacters(in: .whitespaces).lowercased()
                return Self.modalDismissPatterns.contains(text)
            }) { return textMatch }
            // Pass 2: YOLO "icon" in top-right, below the status bar
            return result.elements.first(where: { el in
                guard el.tapY <= topZone && el.tapY >= statusBarCutoff else { return false }
                let text = el.text.trimmingCharacters(in: .whitespaces).lowercased()
                return text == "icon" && el.tapX >= rightHalf
            })
        }()
        if let dismissButton {
            DebugLog.log("bfs", "backtrack-verify: tapping dismiss \"\(dismissButton.text)\" " +
                "at (\(Int(dismissButton.tapX)),\(Int(dismissButton.tapY)))")
            _ = input.tap(x: dismissButton.tapX, y: dismissButton.tapY)
            usleep(EnvConfig.stepSettlingDelayMs * 1000)

            if let afterDismiss = ExplorerUtilities.dismissAlertIfPresent(
                describer: describer, input: input
            ) {
                if let expectedNode = graph.node(for: expectedFP),
                   (StructuralFingerprint.areEquivalentTitleAware(
                       expectedNode.elements, afterDismiss.elements
                   ) || StructuralFingerprint.viewportContainedIn(
                       viewport: afterDismiss.elements, reference: expectedNode.elements
                   )) {
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
        backtracker.tapBack(
            elements: result.elements, input: input, windowSize: windowSize,
            fallback: currentLayoutZones.backButtonFallback
        )

        guard let retryResult = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) else {
            return .lost
        }

        if let expectedNode = graph.node(for: expectedFP),
           (StructuralFingerprint.areEquivalentTitleAware(
               expectedNode.elements, retryResult.elements
           ) || StructuralFingerprint.viewportContainedIn(
               viewport: retryResult.elements, reference: expectedNode.elements
           )) {
            DebugLog.log("bfs", "backtrack-verify: retry succeeded")
            return .verified
        }

        // Recovery 3: Match against any known screen
        if let matchedFP = graph.findMatchingNode(elements: retryResult.elements) {
            DebugLog.log("bfs", "backtrack-verify: landed on known screen \(matchedFP.prefix(8))")
            return .corrected(fingerprint: matchedFP)
        }

        // Recovery 4: Try a third back tap for multi-level detail hierarchies.
        // Some screens (e.g. Health > Activité) have 2+ levels of navigation
        // that require multiple back taps to reach the parent.
        let retryTexts = retryResult.elements.map { $0.text }.joined(separator: ", ")
        DebugLog.log("bfs", "backtrack-verify: still lost after 2 backs — trying 3rd back " +
            "(current: \(retryTexts.prefix(100)))")
        backtracker.tapBack(
            elements: retryResult.elements, input: input, windowSize: windowSize,
            fallback: currentLayoutZones.backButtonFallback
        )
        guard let thirdResult = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) else {
            DebugLog.log("bfs", "backtrack-verify: LOST — OCR failed on 3rd attempt")
            return .lost
        }
        if let expectedNode = graph.node(for: expectedFP),
           (StructuralFingerprint.areEquivalentTitleAware(
               expectedNode.elements, thirdResult.elements
           ) || StructuralFingerprint.viewportContainedIn(
               viewport: thirdResult.elements, reference: expectedNode.elements
           )) {
            DebugLog.log("bfs", "backtrack-verify: 3rd back succeeded!")
            return .verified
        }
        if let matchedFP = graph.findMatchingNode(elements: thirdResult.elements) {
            DebugLog.log("bfs", "backtrack-verify: 3rd back → known screen \(matchedFP.prefix(8))")
            return .corrected(fingerprint: matchedFP)
        }

        DebugLog.log("bfs", "backtrack-verify: LOST — unknown screen after 3 recovery attempts")
        return .lost
    }

    /// Tap back and verify the result. Returns an ExploreStepResult if the explorer
    /// is lost (should stop exploring), or nil if backtrack succeeded.
    /// `edgeType` is the classified type of the edge being reversed: `.tab`
    /// edges return home by tapping the app's root tab instead of the chevron.
    func tapBackAndVerify(
        expectedFP: String,
        afterElements: [TapPoint],
        describer: ScreenDescribing,
        input: InputProviding,
        edgeType: EdgeType? = nil
    ) -> ExploreStepResult? {
        // Tab edges reverse by tapping the app's root tab — the tab bar is
        // visible on the current screen, while icon-only tab roots (Instagram)
        // have no back chevron and the blind fallback tap would land in
        // content. Falls back to tapBack when no root-tab target resolves.
        let tabReturned = edgeType == .tab && BFSTabReturn.tapRootTab(
            appDescription: session.currentAppDescription,
            elements: afterElements,
            icons: graph.node(for: graph.currentFingerprint)?.icons ?? [],
            windowSize: windowSize, input: input
        )
        if !tabReturned {
            backtracker.tapBack(
                elements: afterElements, input: input, windowSize: windowSize,
                fallback: currentLayoutZones.backButtonFallback
            )
        }

        let verification = verifyBacktrack(
            expectedFP: expectedFP, afterElements: afterElements,
            describer: describer, input: input, edgeType: edgeType
        )

        switch verification {
        case .verified:
            graph.setCurrentFingerprint(expectedFP)
            return nil

        case .tabRootDrift:
            // The drift was accepted on the first post-return OCR (inside
            // verifyBacktrack, before any recovery taps could navigate away).
            return acceptTabReturnAtRoot(expectedFP: expectedFP)

        case .corrected(let actualFP):
            graph.setCurrentFingerprint(actualFP)
            DebugLog.log("bfs", "backtrack corrected: expected \(expectedFP.prefix(8)) " +
                "→ actual \(actualFP.prefix(8))")
            // If we landed back on the root screen, that's recoverable — the explorer
            // can continue from root. But if we landed on a non-root screen that isn't
            // the expected parent, continuing would tap elements on the wrong screen.
            if actualFP != graph.rootFingerprint && actualFP != expectedFP {
                // Landed on a different known screen — try in-app tap-back to root,
                // falling back to Spotlight only if that can't reach root. A .tab
                // edge gets no special treatment here: a concrete structural match
                // to a known non-root screen is affirmative evidence of NOT being
                // at root, so only a genuine reposition can recover.
                DebugLog.log("bfs", "backtrack corrected to non-root screen — returning to root for \(appName)")
                _ = AppRootNavigator.resetToRoot(
                    appName: appName,
                    rootElements: graph.node(for: graph.rootFingerprint)?.elements,
                    input: input, describer: describer, backtracker: backtracker,
                    windowSize: windowSize,
                    backButtonFallback: currentLayoutZones.backButtonFallback
                )
                graph.setCurrentFingerprint(graph.rootFingerprint)
                frontierManager.phase = .atRoot
                return .continue(description: "Backtrack landed on wrong screen — returned to root")
            }
            return nil

        case .lost:
            // Stuck/modal state — try in-app tap-back recovery before Spotlight.
            DebugLog.log("bfs", "LOST — returning to root for \(appName) to recover")
            _ = AppRootNavigator.resetToRoot(
                appName: appName,
                rootElements: graph.node(for: graph.rootFingerprint)?.elements,
                input: input, describer: describer, backtracker: backtracker,
                windowSize: windowSize,
                backButtonFallback: currentLayoutZones.backButtonFallback
            )
            graph.setCurrentFingerprint(graph.rootFingerprint)
            // If we were exploring root, stay in exploring phase to continue the plan.
            // Don't switch to .atRoot which would dequeue frontier children.
            if expectedFP != graph.rootFingerprint {
                frontierManager.phase = .atRoot
            }
            DebugLog.log("bfs", "recovered — phase=\(frontierManager.phase)")
            graph.appendRecoveryEvent(PostActionVerifier.buildEvent(
                category: .backtrackFailed,
                screenFingerprint: expectedFP,
                description: "Lost after backtrack — relaunched app to recover"
            ))
            return .continue(description: "Lost after backtrack — relaunched app, continuing")
        }
    }

    /// Accept a drifted .tab return as being at root: tab-bar evidence stands
    /// in for fingerprint equality because feed content churns between visits.
    /// Returns nil (backtrack succeeded) when the expected screen is the root;
    /// otherwise repositions the explorer at root and continues from there.
    private func acceptTabReturnAtRoot(expectedFP: String) -> ExploreStepResult? {
        DebugLog.log("bfs", "tab return: fingerprint drift accepted — tab-bar evidence confirms root")
        graph.setCurrentFingerprint(graph.rootFingerprint)
        guard expectedFP != graph.rootFingerprint else { return nil }
        frontierManager.phase = .atRoot
        return .continue(description: "Tab return drifted — tab-bar evidence confirms root, continuing from root")
    }

    // MARK: - Accessors

    /// Whether the exploration has completed.
    var completed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    var stats: (nodeCount: Int, edgeCount: Int, actionCount: Int, elapsedSeconds: Int) {
        lock.lock(); defer { lock.unlock() }
        return (graph.nodeCount, graph.edgeCount, actionCount, Int(Date().timeIntervalSince(startTime)))
    }

    // MARK: - Bundle Generation

    func generateBundle() -> SkillBundle {
        let recipeMatch = session.currentRecipeMatch
        let appDesc = session.currentAppDescription
        guard let data = session.finalize() else {
            return SkillBundle(appName: "", skills: [], manifest: nil)
        }
        return SkillBundleGenerator.generate(
            appName: data.appName, goal: data.goal,
            snapshot: data.graphSnapshot, allScreens: data.screens,
            recipeMatch: recipeMatch, appDescription: appDesc
        )
    }

    // MARK: - Q-Value Boost

    /// Apply learned Q-value boosts to a plan if the graph has persisted edge data.
    /// Returns the original plan unchanged if no Q-values are available.
    func applyQBoostIfAvailable(plan: [RankedElement], fingerprint: String) -> [RankedElement] {
        guard let navGraph = graph as? NavigationGraph else { return plan }
        let qValues = Dictionary(
            (navGraph.adjacency[fingerprint] ?? []).map { ($0.displayLabel, $0.qValue) },
            uniquingKeysWith: { _, last in last }
        )
        return ScreenPlanner.applyQBoost(plan: plan, qValues: qValues)
    }

    // MARK: - Plateau Advisory

    /// Maximum advisor attempts per screen before giving up.
    static let maxAdvisorAttemptsPerScreen = 2

    /// Ask the AI advisor for guidance when the plan is exhausted and coverage
    /// has plateaued. Returns nil if no advisor is configured, we're not in
    /// plateau phase, the advisor has no actionable suggestion, or max attempts
    /// on this screen have been reached.
    func tryPlateauAdvisor(
        fingerprint: String,
        screenshotBase64: String,
        viewportElements: [TapPoint],
        input: InputProviding
    ) -> ExploreStepResult? {
        guard coverageMonitor.currentPhase == .plateau, let advisor = advisor else {
            return nil
        }
        // Limit advisor attempts per screen to prevent infinite loops
        let advisorKey = "advisor:\(fingerprint)"
        let attempts = (graph.node(for: fingerprint)?.visitedElements
            .filter { $0.hasPrefix("advisor:") }.count) ?? 0
        guard attempts < Self.maxAdvisorAttemptsPerScreen else {
            DebugLog.log("bfs", "plateau advisor: max attempts (\(Self.maxAdvisorAttemptsPerScreen)) reached for \(fingerprint.prefix(8))")
            return nil
        }
        let visited = graph.node(for: fingerprint)?.visitedElements ?? []
        let suggestions = advisor.suggest(
            screenshotBase64: screenshotBase64,
            elements: viewportElements,
            visitedElements: visited,
            exploredScreenCount: graph.nodeCount
        )
        coverageMonitor.recordLLMAction()
        // Track advisor attempt regardless of outcome
        graph.markElementVisited(fingerprint: fingerprint, elementText: advisorKey)
        guard let suggestion = suggestions.first,
              let target = viewportElements.first(where: { $0.text == suggestion.elementText }) else {
            return nil
        }
        DebugLog.log("bfs", "plateau advisor: \"\(suggestion.elementText)\" " +
            "(\(suggestion.reasoning), confidence=\(suggestion.confidence))")
        graph.markElementVisited(fingerprint: fingerprint, elementText: target.text)
        _ = input.tap(x: target.tapX, y: target.tapY)
        usleep(EnvConfig.stepSettlingDelayMs * 1000)
        lock.lock(); actionCount += 1; lock.unlock()
        frontierManager.incrementActionsOnCurrentScreen()
        return .continue(
            description: "Plateau advisor: tapped \"\(suggestion.elementText)\""
        )
    }
}
