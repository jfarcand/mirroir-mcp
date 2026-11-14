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
// ABOUTME: Detects whether the iPhone is already showing the target app to skip redundant Spotlight launches.
// ABOUTME: Uses the persisted graph root node's OCR text as a fingerprint and matches via Jaccard similarity.

import Foundation
import HelperLib

/// Decides whether `launchApp` (Spotlight dance) is needed before exploration.
/// Skipping it when the user is already in the target app saves ~3s and avoids
/// a context flicker that interrupts whatever they were testing.
///
/// Detection strategy: compare current OCR element text against the persisted
/// graph root's element text. A high-similarity match implies we're already
/// foreground in the same root screen the explorer would land on after launch.
enum AppForegroundDetector {

    /// Minimum Jaccard similarity on text-only OCR elements to declare a match.
    /// Tuned conservatively — false positives skip a needed launch and break
    /// exploration; false negatives just keep the existing (slower) behavior.
    static let matchThreshold: Double = 0.5

    /// Outcome of a foreground check.
    enum Verdict: Equatable, Sendable {
        /// Current screen matches the persisted root → caller should skip launchApp.
        case alreadyForeground(similarity: Double)
        /// Spotlight overlay is visible → caller must launch normally.
        case spotlightVisible
        /// No graph file for this app yet → caller has no fingerprint to match against.
        case noPersistedGraph
        /// Graph exists but current screen doesn't resemble the root.
        case unmatched(similarity: Double)
    }

    /// Run detection against the persisted graph for `appName`.
    ///
    /// Matches the current screen against ANY node in the graph, not just the
    /// root: if the prior exploration left iPhone on a sub-screen, that screen
    /// is still inside the target app and a relaunch wastes time.
    ///
    /// - Parameters:
    ///   - elements: OCR elements from the current screen.
    ///   - appName: The app being explored. Used as the graph filename via `GraphPersistence`.
    /// - Returns: A `Verdict` the caller can dispatch on.
    static func detect(elements: [TapPoint], appName: String) -> Verdict {
        if SpotlightDetector.isSpotlightVisible(elements: elements) {
            return .spotlightVisible
        }
        guard let snapshot = GraphPersistence.load(bundleID: appName), !snapshot.nodes.isEmpty else {
            return .noPersistedGraph
        }
        var bestSimilarity = 0.0
        for node in snapshot.nodes.values {
            let similarity = jaccardSimilarity(current: elements, root: node.elements)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
            }
        }
        if bestSimilarity >= matchThreshold {
            return .alreadyForeground(similarity: bestSimilarity)
        }
        return .unmatched(similarity: bestSimilarity)
    }

    /// Similarity floor below which the current screen is treated as a FOREIGN
    /// app rather than a churned view of the target. The target's own screens
    /// always share some chrome tokens with the persisted graph even when feed
    /// content fully rotates; a different app (Mail, Messages) shares
    /// essentially none. Tapping into a foreign app is never acceptable — a
    /// failed pre-explore reset once left Mail foreground and the explorer
    /// tapped Instagram tab anchors into Mail's toolbar.
    static let foreignAppSimilarityFloor: Double = 0.05

    /// Whether the current screen looks like a DIFFERENT app than `appName`.
    /// Conservative on purpose: with no persisted graph there is nothing to
    /// compare against, so the screen is never declared foreign (first-ever
    /// explores must proceed). Spotlight is not foreign — it precedes launch.
    static func looksForeign(elements: [TapPoint], appName: String) -> Bool {
        switch detect(elements: elements, appName: appName) {
        case .unmatched(let similarity):
            return similarity < foreignAppSimilarityFloor
        case .alreadyForeground, .spotlightVisible, .noPersistedGraph:
            return false
        }
    }

    /// Jaccard similarity between two element sets, comparing normalized text.
    /// "icon" placeholders and empty strings are excluded — only meaningful labels count.
    static func jaccardSimilarity(current: [TapPoint], root: [TapPoint]) -> Double {
        let currentSet = textSet(from: current)
        let rootSet = textSet(from: root)
        let union = currentSet.union(rootSet)
        guard !union.isEmpty else { return 0.0 }
        let intersection = currentSet.intersection(rootSet)
        return Double(intersection.count) / Double(union.count)
    }

    private static func textSet(from points: [TapPoint]) -> Set<String> {
        var set: Set<String> = []
        for p in points {
            let normalized = p.text
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized != "icon" else { continue }
            set.insert(normalized)
        }
        return set
    }
}
