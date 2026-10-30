// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Scroll support, dead edge tracking, recovery event logging, and node matching for NavigationGraph.
// ABOUTME: Extracted from NavigationGraph.swift to keep files under the 500-line limit.

import Foundation
import HelperLib

/// Immutable export of the navigation graph state for downstream consumers.
struct GraphSnapshot: Sendable {
    /// All screen nodes keyed by fingerprint.
    let nodes: [String: ScreenNode]
    /// All navigation edges in discovery order.
    let edges: [NavigationEdge]
    /// Adjacency list for O(1) outgoing edge lookup.
    let adjacency: [String: [NavigationEdge]]
    /// Fingerprint of the root (first) screen.
    let rootFingerprint: String
    /// Edges that produced dead taps (no screen change), as "fromFP:elementText" keys.
    let deadEdges: Set<String>
    /// Recovery events logged during exploration.
    let recoveryEvents: [RecoveryEvent]
    /// CEGAR refinement levels per fingerprint.
    var refinementLevels: [String: StateAbstraction.RefinementLevel] = [:]
}

/// An action that can be taken to backtrack in the navigation stack.
enum BacktrackAction: Sendable {
    /// Send Cmd+[ keyboard shortcut (works for desktop apps, not iPhone Mirroring).
    case pressBack
    /// Press the home button to return to app root.
    case pressHome
    /// Tap the "<" back button in the iOS navigation bar.
    case tapBack
    /// No backtracking needed or possible.
    case none
}

extension NavigationGraph {

    // MARK: - Scroll Support

    /// Merge scrolled elements into a screen node using composite key dedup. Returns novel count.
    /// Composite key = text + quantized X, preventing false dedup of same-text elements
    /// at different horizontal positions (e.g., multiple "icon" labels).
    func mergeScrolledElements(fingerprint: String, newElements: [TapPoint]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[fingerprint] else { return 0 }
        // Simple composite key dedup — no pageY proximity check here because
        // elements arrive without scroll-adjusted pageY. The sophisticated
        // pageY proximity dedup lives in OverlapDeduplicator.merge() which
        // CalibrationScroller uses with properly tracked scroll offsets.
        let existingKeys = Set(node.elements.map { OverlapDeduplicator.compositeKey($0) })
        let novel = newElements.filter { !existingKeys.contains(OverlapDeduplicator.compositeKey($0)) }
        guard !novel.isEmpty else { return 0 }
        var updatedElements = node.elements
        updatedElements.append(contentsOf: novel)
        nodes[fingerprint] = ScreenNode(
            fingerprint: node.fingerprint,
            elements: updatedElements,
            icons: node.icons,
            hints: node.hints,
            depth: node.depth,
            screenType: node.screenType,
            screenshotBase64: node.screenshotBase64,
            visitedElements: node.visitedElements,
            navBarTitle: node.navBarTitle,
            visualHash: node.visualHash,
            scrolledElementCount: node.scrolledElementCount + novel.count
        )
        return novel.count
    }

    /// Get the number of scroll actions performed on a screen.
    func scrollCount(for fingerprint: String) -> Int {
        perScreen.scrollCount(for: fingerprint)
    }

    /// Increment the scroll count for a screen.
    func incrementScrollCount(for fingerprint: String) {
        perScreen.incrementScrollCount(for: fingerprint)
    }

    /// Mark a screen as having infinite scroll (content never exhausts).
    func markInfiniteScroll(fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        nodes[fingerprint]?.isInfiniteScroll = true
    }

    /// Mark a screen as scroll-exhausted (all content has been revealed).
    func markScrollExhausted(fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        nodes[fingerprint]?.scrollExhausted = true
    }

    /// Check if a screen has been marked as having infinite scroll.
    func isInfiniteScroll(fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodes[fingerprint]?.isInfiniteScroll ?? false
    }

    /// Check if a screen has been marked as scroll-exhausted.
    func isScrollExhausted(fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodes[fingerprint]?.scrollExhausted ?? false
    }

    // MARK: - Q-Value Updates (Fastbot2 Pattern)

    /// Reward factor added to Q-value when an edge leads to a new screen.
    static let qReward: Double = 1.0
    /// Decay factor applied to Q-value when an edge leads to a revisited screen.
    static let qDecay: Double = 0.9

    /// Update Q-value for the most recent edge from a screen after observing the outcome.
    /// Called after `recordTransition` to learn from each action's result.
    /// Matches on displayLabel (the clean component label) since the BFS explorer
    /// passes displayLabel as the key for Q-updates and dead-edge marks.
    func updateQValue(fromFingerprint: String, displayLabel: String, result: TransitionResult) {
        lock.lock()
        defer { lock.unlock() }

        // Find the edge to update by displayLabel
        guard var edgeList = adjacency[fromFingerprint],
              let idx = edgeList.lastIndex(where: { $0.displayLabel == displayLabel }) else {
            return
        }

        var edge = edgeList[idx]
        switch result {
        case .newScreen:
            edge.qValue += Self.qReward
        case .revisited:
            edge.qValue *= Self.qDecay
        case .duplicate:
            edge.qValue = 0
        }

        edgeList[idx] = edge
        adjacency[fromFingerprint] = edgeList

        // Keep the flat edges array in sync
        if let flatIdx = edges.lastIndex(where: {
            $0.fromFingerprint == fromFingerprint && $0.displayLabel == displayLabel
        }) {
            edges[flatIdx] = edge
        }
    }

    /// Get the Q-value for a specific edge, or the optimistic default if no edge exists.
    func qValue(fromFingerprint: String, displayLabel: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return adjacency[fromFingerprint]?
            .last(where: { $0.displayLabel == displayLabel })?.qValue ?? 1.0
    }

    // MARK: - Dead Edge Tracking

    /// Mark an edge as dead (tap had no effect on the screen).
    /// Dead edges are excluded from future exploration plans.
    ///
    /// - Parameters:
    ///   - fromFingerprint: The screen where the dead tap occurred.
    ///   - displayLabel: The display label of the element that was tapped.
    func markEdgeDead(fromFingerprint: String, displayLabel: String) {
        lock.lock()
        defer { lock.unlock() }
        deadEdges.insert("\(fromFingerprint):\(displayLabel)")
    }

    /// Check if an edge has been marked as dead.
    func isEdgeDead(fromFingerprint: String, displayLabel: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deadEdges.contains("\(fromFingerprint):\(displayLabel)")
    }

    /// Number of dead edges recorded.
    var deadEdgeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deadEdges.count
    }

    // MARK: - Recovery Event Logging

    /// Append a recovery event for post-hoc diagnosis.
    func appendRecoveryEvent(_ event: RecoveryEvent) {
        lock.lock()
        defer { lock.unlock() }
        recoveryEvents.append(event)
    }

    /// Get all recovery events logged during exploration.
    var allRecoveryEvents: [RecoveryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recoveryEvents
    }

    // MARK: - Node Matching

    /// Borderline similarity range where visual hash acts as tiebreaker.
    /// Below this range, screens are considered different regardless of visual hash.
    private static let borderlineLow: Double = 0.7
    /// Above the standard threshold, screens match without needing visual hash.
    private static let borderlineHigh: Double = 0.85

    /// Find a node with similar structural elements using title-aware similarity.
    /// Iterates in sorted key order for deterministic matching across runs.
    func findMatchingNode(elements: [TapPoint]) -> String? {
        findMatchingNode(elements: elements, visualHash: nil)
    }

    /// Find a node with similar structural elements, using visual hash as a tiebreaker
    /// when Jaccard similarity falls in the borderline range (0.7-0.85).
    /// When both the existing node and the query have visual hashes within the
    /// similarity threshold, borderline Jaccard matches are accepted as revisits.
    func findMatchingNode(elements: [TapPoint], visualHash: UInt64?) -> String? {
        for (fp, node) in nodes.sorted(by: { $0.key < $1.key }) {
            let sim = StructuralFingerprint.titleAwareSimilarity(elements, node.elements)
            if sim >= StructuralFingerprint.similarityThreshold {
                return fp
            }
            // Borderline range: use visual hash as tiebreaker
            if sim >= Self.borderlineLow && sim < Self.borderlineHigh,
               let queryHash = visualHash, queryHash != 0,
               let nodeHash = node.visualHash, nodeHash != 0 {
                let hammingDist = VisualFingerprint.distance(queryHash, nodeHash)
                if hammingDist <= VisualFingerprint.similarityThreshold {
                    return fp
                }
            }
        }
        return nil
    }

    /// Find a node matching the viewport using both Jaccard similarity and containment.
    /// Containment catches the case where a viewport (~40 elements) is a subset of a
    /// calibrated full-page set (~90 elements) — Jaccard fails because the union is large.
    /// Iterates in sorted key order for deterministic matching across runs.
    func findMatchingNodeWithContainment(elements: [TapPoint]) -> String? {
        if let fp = findMatchingNode(elements: elements) {
            return fp
        }
        for (fp, node) in nodes.sorted(by: { $0.key < $1.key }) {
            if StructuralFingerprint.viewportContainedIn(
                viewport: elements, reference: node.elements
            ) {
                return fp
            }
        }
        return nil
    }
}
