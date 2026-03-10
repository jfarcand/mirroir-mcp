// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds interesting navigation paths in a GraphSnapshot for multi-skill output.
// ABOUTME: Identifies leaf nodes, deep paths, and unique content paths via graph traversal.

import Foundation
import HelperLib

/// Finds interesting navigation paths in a GraphSnapshot.
/// Each path represents a distinct flow through the app that can become a SKILL.md.
enum GraphPathFinder {

    /// A named path through the navigation graph.
    struct NamedPath: Sendable {
        /// Human-readable name for this flow (derived from edge labels).
        let name: String
        /// Ordered sequence of edges from root to destination.
        let edges: [NavigationEdge]
    }

    /// Find all interesting paths in the graph, suitable for multi-skill generation.
    /// Returns paths to leaf nodes (screens with no outgoing edges) and
    /// screens at maximum depth.
    static func findInterestingPaths(in snapshot: GraphSnapshot) -> [NamedPath] {
        guard !snapshot.nodes.isEmpty else { return [] }

        // Build adjacency list: fingerprint -> [edges from that fingerprint]
        var adjacency: [String: [NavigationEdge]] = [:]
        for edge in snapshot.edges {
            adjacency[edge.fromFingerprint, default: []].append(edge)
        }

        // Find leaf nodes: nodes that appear as destinations but have no outgoing edges
        let leafFingerprints = findLeafNodes(snapshot: snapshot, adjacency: adjacency)

        // For each leaf, reconstruct the path from root
        var paths: [NamedPath] = []
        var seenLeaves = Set<String>()

        for leafFP in leafFingerprints {
            guard !seenLeaves.contains(leafFP) else { continue }
            seenLeaves.insert(leafFP)

            if let path = reconstructPath(
                from: snapshot.rootFingerprint, to: leafFP,
                adjacency: adjacency
            ) {
                let name = deriveName(from: path, snapshot: snapshot)
                paths.append(NamedPath(name: name, edges: path))
            }
        }

        // If no leaf paths found, create a single path from the longest chain
        if paths.isEmpty && !snapshot.edges.isEmpty {
            let longestPath = findLongestPath(
                from: snapshot.rootFingerprint, adjacency: adjacency
            )
            if !longestPath.isEmpty {
                let name = deriveName(from: longestPath, snapshot: snapshot)
                paths.append(NamedPath(name: name, edges: longestPath))
            }
        }

        return paths
    }

    /// Convert a graph path (edges) to a flat array of ExploredScreens.
    /// Produces the format expected by SkillMdGenerator.
    static func pathToExploredScreens(
        path: [NavigationEdge],
        snapshot: GraphSnapshot
    ) -> [ExploredScreen] {
        var screens: [ExploredScreen] = []

        // Start with the root node (first edge's source)
        if let firstEdge = path.first,
           let rootNode = snapshot.nodes[firstEdge.fromFingerprint] {
            screens.append(ExploredScreen(
                index: 0,
                elements: rootNode.elements,
                hints: rootNode.hints,
                actionType: nil,
                arrivedVia: nil,
                displayLabel: nil,
                screenshotBase64: rootNode.screenshotBase64
            ))
        }

        // Add each destination node along the path
        for (i, edge) in path.enumerated() {
            if let node = snapshot.nodes[edge.toFingerprint] {
                screens.append(ExploredScreen(
                    index: i + 1,
                    elements: node.elements,
                    hints: node.hints,
                    actionType: edge.actionType,
                    arrivedVia: edge.elementText,
                    displayLabel: edge.displayLabel,
                    screenshotBase64: node.screenshotBase64
                ))
            }
        }

        return screens
    }

    // MARK: - Private

    /// Find leaf nodes: screens with no outgoing forward edges, plus depth-capped nodes.
    /// Depth-capped nodes (at the graph's max depth) represent exploration boundaries
    /// and produce valid test paths even if they have outgoing edges.
    private static func findLeafNodes(
        snapshot: GraphSnapshot,
        adjacency: [String: [NavigationEdge]]
    ) -> [String] {
        var leaves: [String] = []
        let maxDepth = snapshot.nodes.values.map(\.depth).max() ?? 0

        for fp in snapshot.nodes.keys {
            guard fp != snapshot.rootFingerprint else { continue }
            let node = snapshot.nodes[fp]
            let outgoing = adjacency[fp] ?? []

            // True leaf: no outgoing forward edges
            let forwardEdges = outgoing.filter { edge in
                let targetDepth = snapshot.nodes[edge.toFingerprint]?.depth ?? 0
                let sourceDepth = node?.depth ?? 0
                return targetDepth > sourceDepth
            }
            let isTrueLeaf = forwardEdges.isEmpty

            // Depth-capped: at the maximum explored depth
            let isDepthCapped = (node?.depth ?? 0) == maxDepth && maxDepth > 0

            if isTrueLeaf || isDepthCapped {
                leaves.append(fp)
            }
        }

        // Sort by depth (deepest first) for more interesting paths first
        return leaves.sorted { lhs, rhs in
            (snapshot.nodes[lhs]?.depth ?? 0) > (snapshot.nodes[rhs]?.depth ?? 0)
        }
    }

    /// Reconstruct a path from source to target using BFS.
    private static func reconstructPath(
        from source: String,
        to target: String,
        adjacency: [String: [NavigationEdge]]
    ) -> [NavigationEdge]? {
        guard source != target else { return [] }

        var visited = Set<String>([source])
        var queue: [(fingerprint: String, path: [NavigationEdge])] = [(source, [])]

        while !queue.isEmpty {
            let (current, path) = queue.removeFirst()
            let edges = adjacency[current] ?? []

            for edge in edges {
                guard !visited.contains(edge.toFingerprint) else { continue }
                let extended = path + [edge]

                if edge.toFingerprint == target {
                    return extended
                }

                visited.insert(edge.toFingerprint)
                queue.append((edge.toFingerprint, extended))
            }
        }

        return nil
    }

    /// Find the longest non-cyclic path from a starting node.
    private static func findLongestPath(
        from start: String,
        adjacency: [String: [NavigationEdge]]
    ) -> [NavigationEdge] {
        var longest: [NavigationEdge] = []

        func dfs(current: String, path: [NavigationEdge], visited: Set<String>) {
            if path.count > longest.count {
                longest = path
            }
            for edge in adjacency[current] ?? [] {
                guard !visited.contains(edge.toFingerprint) else { continue }
                var nextVisited = visited
                nextVisited.insert(edge.toFingerprint)
                dfs(current: edge.toFingerprint, path: path + [edge], visited: nextVisited)
            }
        }

        dfs(current: start, path: [], visited: [start])
        return longest
    }

    /// Derive a human-readable name from a path's edge labels and leaf node content.
    /// Uses LandmarkPicker on the leaf node for more descriptive names when available.
    /// Short paths (≤2 labels) use full join; longer paths use "first to last" format.
    static func deriveName(
        from path: [NavigationEdge],
        snapshot: GraphSnapshot
    ) -> String {
        let labels = path.map(\.elementText).filter { !$0.isEmpty }
        if labels.isEmpty { return "exploration" }

        // Try landmark-based naming for longer paths
        if labels.count > 2, let lastEdge = path.last,
           let leafNode = snapshot.nodes[lastEdge.toFingerprint],
           let landmark = LandmarkPicker.pickLandmark(from: leafNode.elements) {
            let prefix = labels[0]
            return "\(prefix) to \(landmark)".lowercased()
        }

        if labels.count <= 2 {
            return labels.joined(separator: " > ").lowercased()
        }
        return "\(labels[0]) to \(labels[labels.count - 1])".lowercased()
    }
}
