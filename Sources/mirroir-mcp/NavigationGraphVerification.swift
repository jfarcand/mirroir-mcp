// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Scroll support, dead edge tracking, recovery event logging, and node matching for NavigationGraph.
// ABOUTME: Extracted from NavigationGraph.swift to keep files under the 500-line limit.

import Foundation
import HelperLib

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
            navBarTitle: node.navBarTitle
        )
        return novel.count
    }

    /// Get the number of scroll actions performed on a screen.
    func scrollCount(for fingerprint: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return scrollCounts[fingerprint, default: 0]
    }

    /// Increment the scroll count for a screen.
    func incrementScrollCount(for fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        scrollCounts[fingerprint, default: 0] += 1
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

    // MARK: - Dead Edge Tracking

    /// Mark an edge as dead (tap had no effect on the screen).
    /// Dead edges are excluded from future exploration plans.
    ///
    /// - Parameters:
    ///   - fromFingerprint: The screen where the dead tap occurred.
    ///   - elementText: The element text that was tapped.
    func markEdgeDead(fromFingerprint: String, elementText: String) {
        lock.lock()
        defer { lock.unlock() }
        deadEdges.insert("\(fromFingerprint):\(elementText)")
    }

    /// Check if an edge has been marked as dead.
    func isEdgeDead(fromFingerprint: String, elementText: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deadEdges.contains("\(fromFingerprint):\(elementText)")
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

    /// Find a node with similar structural elements using title-aware similarity.
    /// Iterates in sorted key order for deterministic matching across runs.
    func findMatchingNode(elements: [TapPoint]) -> String? {
        for (fp, node) in nodes.sorted(by: { $0.key < $1.key }) {
            let sim = StructuralFingerprint.titleAwareSimilarity(elements, node.elements)
            if sim >= StructuralFingerprint.similarityThreshold {
                return fp
            }
        }
        return nil
    }

    // MARK: - CEGAR Coarsening

    /// Merge redundant nodes when state count exceeds the coarsening threshold.
    /// Two nodes are mergeable when they have identical outgoing edge targets
    /// and pass structural similarity. The second node is removed and all edges
    /// pointing to it are redirected to the first.
    func coarsenIfNeeded() {
        lock.lock()
        guard nodes.count > StateAbstraction.coarseningThreshold else {
            lock.unlock()
            return
        }
        let currentNodes = nodes
        let currentEdges = edges
        lock.unlock()

        let pairs = StateAbstraction.findMergeablePairs(
            nodes: currentNodes, edges: currentEdges
        )
        guard !pairs.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        for pair in pairs {
            guard nodes[pair.merge] != nil else { continue }
            nodes.removeValue(forKey: pair.merge)
            // Redirect edges pointing to the merged node
            edges = edges.map { edge in
                var e = edge
                if edge.toFingerprint == pair.merge {
                    e = NavigationEdge(
                        fromFingerprint: edge.fromFingerprint,
                        toFingerprint: pair.keep,
                        actionType: edge.actionType,
                        elementText: edge.elementText,
                        displayLabel: edge.displayLabel,
                        edgeType: edge.edgeType
                    )
                }
                return e
            }
            if currentFP == pair.merge { currentFP = pair.keep }
            DebugLog.log("graph", "CEGAR coarsen: merged \(pair.merge.prefix(8)) → \(pair.keep.prefix(8))")
        }
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
