// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Adaptive fingerprint abstraction using CEGAR-style refinement.
// ABOUTME: Detects behavioral non-equivalence and refines fingerprints to distinguish screens.

import CryptoKit
import Foundation
import HelperLib

/// Adaptive state abstraction for navigation graph fingerprinting.
/// Detects when two screen captures produce the same fingerprint but have
/// different tappable elements, and refines the fingerprint to distinguish them.
/// Based on the APE/CEGAR pattern from ICSE 2019.
enum StateAbstraction {

    /// Refinement level for fingerprint computation. Higher levels include more
    /// distinguishing attributes in the hash, producing finer-grained screen identity.
    enum RefinementLevel: Int, Codable, Comparable, Sendable {
        /// Base: sorted structural text elements + icon count (current default).
        case structural = 0
        /// Adds nav bar title to the fingerprint.
        case titleRefined = 1
        /// Adds screen zone layout signature (which zones contain content).
        case zoneRefined = 2

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Overlap threshold below which two element sets are behaviorally different.
    /// Lower than structural similarity (0.8) because behavioral equivalence
    /// focuses on tappable actions, not visual similarity.
    static let behavioralThreshold: Double = 0.6

    /// Node count above which coarsening is triggered to prevent state explosion.
    static let coarseningThreshold: Int = 100

    // MARK: - Behavioral Equivalence

    /// Check whether new elements are behaviorally equivalent to an existing node.
    /// Two screens are behaviorally equivalent if their structural element sets
    /// overlap above the behavioral threshold (same tappable actions available).
    static func areBehaviorallyEquivalent(
        existingElements: [TapPoint],
        newElements: [TapPoint]
    ) -> Bool {
        let existingSet = StructuralFingerprint.extractStructural(from: existingElements)
        let newSet = StructuralFingerprint.extractStructural(from: newElements)
        return StructuralFingerprint.similarity(existingSet, newSet) >= behavioralThreshold
    }

    // MARK: - Refinement

    /// Determine the minimum refinement level that distinguishes two element sets.
    /// Returns nil if no refinement can distinguish them (identical behavior).
    static func findDistinguishingLevel(
        existingElements: [TapPoint],
        newElements: [TapPoint]
    ) -> RefinementLevel? {
        // Title refinement: different nav bar titles
        let existingTitle = StructuralFingerprint.extractNavBarTitle(from: existingElements)
        let newTitle = StructuralFingerprint.extractNavBarTitle(from: newElements)
        if existingTitle != newTitle && (existingTitle != nil || newTitle != nil) {
            return .titleRefined
        }

        // Zone refinement: different zone layout signatures
        let existingZones = zoneSignature(from: existingElements)
        let newZones = zoneSignature(from: newElements)
        if existingZones != newZones {
            return .zoneRefined
        }

        return nil
    }

    /// Compute a fingerprint with refinement attributes at the specified level.
    /// Each level adds more distinguishing attributes to the hash payload.
    static func computeRefinedFingerprint(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        level: RefinementLevel
    ) -> String {
        let structural = StructuralFingerprint.extractStructural(from: elements)
        let sorted = structural.sorted()
        let iconSignal = "icons:\(icons.count)"
        var components = sorted + [iconSignal]

        if level >= .titleRefined {
            let title = StructuralFingerprint.extractNavBarTitle(from: elements) ?? ""
            components.append("title:\(title)")
        }

        if level >= .zoneRefined {
            let zones = zoneSignature(from: elements)
            components.append("zones:\(zones)")
        }

        let payload = components.joined(separator: "|")
        let hash = SHA256.hash(data: Data(payload.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Zone Signature

    /// Compute a zone layout signature describing which screen zones contain content.
    /// Format: "N-C-T" where N=nav bar, C=content, T=tab bar (1 if present, 0 if empty).
    static func zoneSignature(from elements: [TapPoint]) -> String {
        let headerZone = StructuralFingerprint.headerZoneRange
        let tabBarMinY: Double = 750 // approximate for standard iOS screen

        var hasNavBar = false
        var hasContent = false
        var hasTabBar = false

        for el in elements {
            guard StructuralFingerprint.passesStructuralFilter(el) else { continue }
            if headerZone.contains(el.tapY) { hasNavBar = true }
            else if el.tapY >= tabBarMinY { hasTabBar = true }
            else { hasContent = true }
        }

        return "\(hasNavBar ? 1 : 0)-\(hasContent ? 1 : 0)-\(hasTabBar ? 1 : 0)"
    }

    // MARK: - Coarsening

    /// Identify pairs of nodes that can be merged (identical outgoing edge targets).
    /// Returns pairs of fingerprints where the second can be merged into the first.
    static func findMergeablePairs(
        nodes: [String: ScreenNode],
        edges: [NavigationEdge]
    ) -> [(keep: String, merge: String)] {
        // Build outgoing-edge signature for each node: sorted set of destination fingerprints
        var edgeSignatures: [String: String] = [:]
        for (fp, _) in nodes {
            let destinations = edges
                .filter { $0.fromFingerprint == fp }
                .map { $0.toFingerprint }
            let sig = Set(destinations).sorted().joined(separator: ",")
            edgeSignatures[fp] = sig
        }

        // Group nodes by identical edge signatures + same structural similarity
        var groups: [String: [String]] = [:]
        for (fp, sig) in edgeSignatures {
            groups[sig, default: []].append(fp)
        }

        var pairs: [(keep: String, merge: String)] = []
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted()
            let keep = sorted[0]
            for fp in sorted.dropFirst() {
                // Verify structural similarity before merging
                guard let keepNode = nodes[keep], let mergeNode = nodes[fp] else { continue }
                let sim = StructuralFingerprint.titleAwareSimilarity(
                    keepNode.elements, mergeNode.elements
                )
                if sim >= StructuralFingerprint.similarityThreshold {
                    pairs.append((keep: keep, merge: fp))
                }
            }
        }

        return pairs
    }
}
