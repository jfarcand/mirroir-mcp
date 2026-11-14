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
// ABOUTME: Dominator tree computation via the Lengauer-Tarjan algorithm.
// ABOUTME: Identifies gateway screens that all paths must traverse, enabling subtree pruning.

import Foundation

/// A screen that dominates multiple other screens, acting as a navigation gateway.
struct GatewayScreen: Sendable {
    /// Fingerprint of the gateway screen.
    let fingerprint: String
    /// Number of screens dominated by this gateway (not counting itself).
    let dominatedCount: Int
    /// Fingerprints of all screens in the subtree rooted at this gateway.
    let subtreeFingerprints: Set<String>
}

/// Lengauer-Tarjan dominator tree algorithm for navigation graph analysis.
/// Dominators identify "gateway" screens that all paths from root must traverse,
/// enabling subtree pruning: if a gateway is known, its entire subtree can be
/// skipped or prioritized as a unit.
enum DominatorTree {

    // MARK: - Dominator Computation (Lengauer-Tarjan)

    /// Compute the immediate dominator map using the Lengauer-Tarjan algorithm.
    /// Returns a dictionary mapping each fingerprint to its immediate dominator.
    /// The root fingerprint maps to itself.
    static func compute(snapshot: GraphSnapshot) -> [String: String] {
        let root = snapshot.rootFingerprint
        guard snapshot.nodes[root] != nil else { return [:] }

        // Step 1: DFS numbering
        var dfsOrder: [String] = []
        var dfsNumber: [String: Int] = [:]
        var dfsParent: [String: String] = [:]
        var visited = Set<String>()

        dfs(node: root, snapshot: snapshot, visited: &visited,
            dfsOrder: &dfsOrder, dfsNumber: &dfsNumber, dfsParent: &dfsParent)

        let n = dfsOrder.count
        guard n > 0 else { return [:] }

        // Build predecessor lists (reverse graph)
        var predecessors: [String: [String]] = [:]
        for edge in snapshot.edges {
            guard dfsNumber[edge.fromFingerprint] != nil,
                  dfsNumber[edge.toFingerprint] != nil else { continue }
            predecessors[edge.toFingerprint, default: []].append(edge.fromFingerprint)
        }
        // Deduplicate predecessors
        for (key, preds) in predecessors {
            predecessors[key] = Array(Set(preds))
        }

        // Step 2: Initialize semi-dominator and immediate dominator arrays
        var semi: [String: Int] = [:]  // semi-dominator DFS numbers
        var idom: [String: String] = [:]  // immediate dominators
        var ancestor: [String: String] = [:]  // union-find ancestor (absent key = forest root)
        var label: [String: String] = [:]  // union-find label (node with min semi)
        var bucket: [String: [String]] = [:]  // bucket for deferred idom computation

        for fp in dfsOrder {
            semi[fp] = dfsNumber[fp]
            // ancestor intentionally left absent for forest roots
            label[fp] = fp
        }

        // Step 3: Process vertices in reverse DFS order (skip root at index 0)
        for i in stride(from: n - 1, through: 1, by: -1) {
            let w = dfsOrder[i]

            // Compute semi-dominator
            for v in predecessors[w] ?? [] {
                let u = eval(v: v, ancestor: &ancestor, label: &label, semi: semi)
                let semiU = semi[u] ?? 0
                let semiW = semi[w] ?? 0
                if semiU < semiW {
                    semi[w] = semiU
                }
            }

            // Add w to bucket of semi-dominator vertex
            let semiVertex = dfsOrder[semi[w] ?? 0]
            bucket[semiVertex, default: []].append(w)

            // Link w to its DFS parent
            let parent = dfsParent[w] ?? root
            ancestor[w] = parent

            // Process bucket of parent
            for v in bucket[parent] ?? [] {
                let u = eval(v: v, ancestor: &ancestor, label: &label, semi: semi)
                let semiU = semi[u] ?? 0
                let semiV = semi[v] ?? 0
                if semiU < semiV {
                    idom[v] = u
                } else {
                    idom[v] = parent
                }
            }
            bucket[parent] = []
        }

        // Step 4: Adjust immediate dominators
        for i in 1..<n {
            let w = dfsOrder[i]
            let semiVertex = dfsOrder[semi[w] ?? 0]
            if idom[w] != semiVertex {
                idom[w] = idom[idom[w] ?? root] ?? root
            }
        }

        // Root dominates itself
        idom[root] = root

        return idom
    }

    // MARK: - Domination Queries

    /// Check if `dominator` dominates `target` in the dominator tree.
    /// A node dominates itself.
    static func dominates(_ dominator: String, _ target: String, idom: [String: String]) -> Bool {
        if dominator == target { return true }
        var current = target
        var visited = Set<String>()
        while let parent = idom[current], parent != current {
            if visited.contains(parent) { break }
            visited.insert(parent)
            if parent == dominator { return true }
            current = parent
        }
        return false
    }

    /// Compute the set of all fingerprints dominated by the given screen.
    /// Includes the screen itself.
    static func subtree(of fingerprint: String, idom: [String: String]) -> Set<String> {
        // Build children map from idom
        var children: [String: [String]] = [:]
        for (node, parent) in idom where node != parent {
            children[parent, default: []].append(node)
        }

        // BFS from the given fingerprint
        var result = Set<String>()
        var queue = [fingerprint]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            result.insert(current)
            for child in children[current] ?? [] {
                if !result.contains(child) {
                    queue.append(child)
                }
            }
        }
        return result
    }

    // MARK: - Gateway Detection

    /// Find screens that dominate more than one other screen (navigation gateways).
    /// Returns gateways sorted by dominated count descending.
    static func gateways(snapshot: GraphSnapshot) -> [GatewayScreen] {
        let idom = compute(snapshot: snapshot)
        guard !idom.isEmpty else { return [] }

        // Build children map from idom
        var children: [String: [String]] = [:]
        for (node, parent) in idom where node != parent {
            children[parent, default: []].append(node)
        }

        // Compute subtree for each node that has children
        var results: [GatewayScreen] = []
        for (fp, _) in children {
            let sub = subtree(of: fp, idom: idom)
            // dominatedCount excludes the node itself
            let dominated = sub.count - 1
            if dominated > 1 {
                results.append(GatewayScreen(
                    fingerprint: fp,
                    dominatedCount: dominated,
                    subtreeFingerprints: sub
                ))
            }
        }

        return results.sorted { $0.dominatedCount > $1.dominatedCount }
    }

    // MARK: - Private Helpers

    /// DFS traversal to compute DFS numbering and parent links.
    private static func dfs(
        node: String,
        snapshot: GraphSnapshot,
        visited: inout Set<String>,
        dfsOrder: inout [String],
        dfsNumber: inout [String: Int],
        dfsParent: inout [String: String]
    ) {
        guard visited.insert(node).inserted else { return }
        dfsNumber[node] = dfsOrder.count
        dfsOrder.append(node)

        let outEdges = snapshot.adjacency[node] ?? []
        var seenTargets = Set<String>()
        for edge in outEdges {
            let target = edge.toFingerprint
            guard snapshot.nodes[target] != nil else { continue }
            guard seenTargets.insert(target).inserted else { continue }
            if !visited.contains(target) {
                dfsParent[target] = node
                dfs(node: target, snapshot: snapshot, visited: &visited,
                    dfsOrder: &dfsOrder, dfsNumber: &dfsNumber, dfsParent: &dfsParent)
            }
        }
    }

    /// Union-find EVAL operation with path compression for Lengauer-Tarjan.
    /// Returns the node with minimum semi-dominator on the path to the tree root.
    /// A node without an ancestor entry is a forest root and returns its own label.
    private static func eval(
        v: String,
        ancestor: inout [String: String],
        label: inout [String: String],
        semi: [String: Int]
    ) -> String {
        guard let anc = ancestor[v] else {
            return label[v] ?? v
        }
        if ancestor[anc] != nil {
            compress(v: v, ancestor: &ancestor, label: &label, semi: semi)
        }
        return label[v] ?? v
    }

    /// Path compression for union-find, updating labels with minimum semi-dominator.
    private static func compress(
        v: String,
        ancestor: inout [String: String],
        label: inout [String: String],
        semi: [String: Int]
    ) {
        guard let anc = ancestor[v] else { return }
        guard ancestor[anc] != nil else { return }

        compress(v: anc, ancestor: &ancestor, label: &label, semi: semi)

        let labelAnc = label[anc] ?? anc
        let labelV = label[v] ?? v
        let semiLabelAnc = semi[labelAnc] ?? 0
        let semiLabelV = semi[labelV] ?? 0
        if semiLabelAnc < semiLabelV {
            label[v] = labelAnc
        }
        ancestor[v] = ancestor[anc] ?? anc
    }
}
