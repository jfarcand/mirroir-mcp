// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Global frontier scoring for cross-screen exploration prioritization.
// ABOUTME: Finds the highest-value unvisited element across ancestor screens in the backtrack stack.

import Foundation
import HelperLib

/// A candidate target from the global frontier: an unvisited element on an ancestor screen.
struct FrontierTarget: Sendable {
    /// Fingerprint of the screen containing the element.
    let fingerprint: String
    /// The unvisited element to explore.
    let element: TapPoint
    /// Computed frontier score (higher = more valuable).
    let score: Double
    /// DFS depth of the screen in the navigation graph.
    let depth: Int
}

/// Computes global frontier scores for cross-screen exploration prioritization.
/// Instead of always backtracking to the immediate parent, the explorer can jump
/// directly to the highest-value ancestor, prioritizing unexplored tabs and
/// shallow screens with many unvisited elements.
enum FrontierPlanner {

    /// Bonus per depth level closer to root (shallower screens get higher priority).
    static let depthBonusPerLevel: Double = 2.0

    /// Multiplier for novelty bonus (screens with fewer visited elements score higher).
    static let noveltyBonusMultiplier: Double = 1.5

    /// Flat bonus for elements on tabRoot screens (unexplored tabs are high-value).
    static let tabRootBonus: Double = 5.0

    /// Find the highest-value unvisited element across ancestor screens.
    ///
    /// Walks the backtrack stack (excluding the current screen) and scores each
    /// ancestor's unvisited elements. Returns the single best target across all
    /// ancestors, or nil if all ancestors are fully explored.
    ///
    /// - Parameters:
    ///   - graph: The navigation graph containing screen nodes and visited state.
    ///   - backtrackStack: The current DFS stack of screen fingerprints.
    ///   - screenHeight: Height of the target window for element scoring.
    /// - Returns: The highest-scoring frontier target, or nil if no unvisited elements remain.
    static func bestTarget(
        graph: NavigationGraph,
        backtrackStack: [String],
        screenHeight: Double
    ) -> FrontierTarget? {
        guard backtrackStack.count > 1 else { return nil }

        let maxDepth = backtrackStack.count - 1
        var bestTarget: FrontierTarget?

        // Walk ancestors (skip the current screen at the top of the stack)
        for i in 0..<(backtrackStack.count - 1) {
            let fp = backtrackStack[i]
            guard let node = graph.node(for: fp) else { continue }

            let unvisited = node.elements.filter { !node.visitedElements.contains($0.text) }
            guard !unvisited.isEmpty else { continue }

            let totalElements = max(node.elements.count, 1)
            let visitedRatio = Double(node.visitedElements.count) / Double(totalElements)
            let isTabRoot = node.screenType == .tabRoot

            for element in unvisited {
                let elementScore = baseElementScore(element, screenHeight: screenHeight)
                let score = computeFrontierScore(
                    elementScore: elementScore,
                    screenDepth: node.depth,
                    maxDepth: maxDepth,
                    visitedRatio: visitedRatio,
                    isTabRoot: isTabRoot
                )

                if bestTarget == nil || score > bestTarget!.score {
                    bestTarget = FrontierTarget(
                        fingerprint: fp,
                        element: element,
                        score: score,
                        depth: node.depth
                    )
                }
            }
        }

        return bestTarget
    }

    /// Compute the frontier score for a single element.
    ///
    /// Score = elementScore + depthBonus*(maxDepth-depth) + novelty*(1-visitedRatio) + tabRootBonus
    ///
    /// - Parameters:
    ///   - elementScore: Base score from the element itself (e.g. position, role).
    ///   - screenDepth: DFS depth of the screen containing the element.
    ///   - maxDepth: Current maximum depth in the backtrack stack.
    ///   - visitedRatio: Fraction of elements already visited on this screen (0.0–1.0).
    ///   - isTabRoot: Whether the screen is a tab root.
    /// - Returns: The computed frontier score.
    static func computeFrontierScore(
        elementScore: Double,
        screenDepth: Int,
        maxDepth: Int,
        visitedRatio: Double,
        isTabRoot: Bool
    ) -> Double {
        let depthBonus = depthBonusPerLevel * Double(maxDepth - screenDepth)
        let noveltyBonus = noveltyBonusMultiplier * (1.0 - visitedRatio)
        let tabBonus = isTabRoot ? tabRootBonus : 0.0
        return elementScore + depthBonus + noveltyBonus + tabBonus
    }

    // MARK: - Private

    /// Compute a base score for an element based on its position.
    /// Elements in the main content area score higher than status bar or edge elements.
    private static func baseElementScore(
        _ element: TapPoint, screenHeight: Double
    ) -> Double {
        // Prefer elements in the middle content zone
        let normalizedY = element.tapY / screenHeight
        if normalizedY < 0.1 || normalizedY > 0.9 {
            return 1.0
        }
        return 3.0
    }
}
