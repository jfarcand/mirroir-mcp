// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Helper methods for BFSExplorer: context escape, plan building, scroll support.
// ABOUTME: Split from BFSExplorer.swift to stay under the 500-line limit.

import Foundation
import HelperLib

extension BFSExplorer {

    /// Check if the explorer has left the target app and handle accordingly.
    /// Returns an ExploreStepResult to return early, or nil if still in-app.
    func handleContextEscape(
        elements: [TapPoint], input: InputProviding, describer: ScreenDescribing
    ) -> ExploreStepResult? {
        let check = ExplorerUtilities.verifyAppContext(
            elements: elements, screenHeight: windowSize.height,
            appName: appName, input: input, describer: describer)
        switch check {
        case .ok: return nil
        case .recovered:
            lock.lock(); isFinished = true; lock.unlock()
            return .finished(bundle: generateBundle())
        case .failed(let reason):
            lock.lock(); isFinished = true; lock.unlock()
            return .paused(reason: "Left app: \(reason)")
        }
    }

    /// Build a screen plan using component detection or legacy per-element classification.
    func buildScreenPlan(
        classified: [ClassifiedElement], visitedElements: Set<String>
    ) -> [RankedElement] {
        guard !componentDefinitions.isEmpty else {
            return ScreenPlanner.buildPlan(
                classified: classified, visitedElements: visitedElements,
                scoutResults: [:], screenHeight: windowSize.height)
        }
        let rawComponents = classifier?.classify(
            classified: classified, definitions: componentDefinitions,
            screenHeight: windowSize.height
        ) ?? ComponentDetector.detect(
            classified: classified, definitions: componentDefinitions,
            screenHeight: windowSize.height)
        let components = ComponentDetector.applyAbsorption(rawComponents)
        return ScreenPlanner.buildComponentPlan(
            components: components, visitedElements: visitedElements,
            scoutResults: [:], screenHeight: windowSize.height)
    }

    /// Attempt to scroll the current screen to reveal hidden elements.
    /// Returns a step result if scrolling revealed new elements, or nil to fall through.
    func performScrollIfAvailable(
        currentFP: String,
        input: InputProviding,
        describer: ScreenDescribing
    ) -> ExploreStepResult? {
        guard graph.scrollCount(for: currentFP) < budget.scrollLimit else { return nil }

        // Swipe up (scroll content down) from center of screen
        let centerX = windowSize.width / 2
        let fromY = windowSize.height * 0.75
        let toY = windowSize.height * 0.25
        _ = input.swipe(fromX: centerX, fromY: fromY, toX: centerX, toY: toY, durationMs: 300)

        usleep(EnvConfig.stepSettlingDelayMs * 1000)

        // OCR the new viewport
        guard let afterResult = describer.describe(skipOCR: false) else { return nil }

        let novelCount = graph.mergeScrolledElements(
            fingerprint: currentFP, newElements: afterResult.elements
        )
        graph.incrementScrollCount(for: currentFP)

        if novelCount > 0 {
            // New elements discovered — invalidate the plan so it rebuilds with them
            graph.clearScreenPlan(for: currentFP)
            return .continue(description: "Scrolled, found \(novelCount) new elements")
        }
        // No new elements — scroll exhaustion, fall through
        return nil
    }
}
