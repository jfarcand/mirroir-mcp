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
// ABOUTME: Strongly connected component detection via Tarjan's algorithm for room-level reasoning.
// ABOUTME: Condensation DAG collapses SCCs into single nodes, enabling topological exploration ordering.

import Foundation

/// A node in the condensation DAG representing a single SCC (a "room" of mutually-reachable screens).
struct SCCNode: Sendable {
    /// Index of this SCC in the condensation DAG's node array.
    let index: Int
    /// Fingerprints of all screens in this SCC.
    let fingerprints: [String]
    /// Whether every screen in this SCC has been fully explored (all elements visited).
    let isFullyExplored: Bool
}

/// Directed acyclic graph where each node is a strongly connected component from the original graph.
struct CondensationDAG: Sendable {
    /// SCC nodes indexed by their `index` field.
    let nodes: [SCCNode]
    /// Directed edges between SCCs (from SCC index to SCC index).
    let edges: [(from: Int, to: Int)]
}

/// Tarjan's SCC algorithm and condensation DAG construction for navigation graph analysis.
/// Identifies "rooms" — groups of screens that are all mutually reachable — enabling
/// topological ordering of exploration and room-level progress tracking.
enum GraphAnalyzer {

    // MARK: - Tarjan's SCC Algorithm

    /// Compute strongly connected components using Tarjan's algorithm.
    /// Returns SCCs as arrays of fingerprints. Each SCC contains fingerprints
    /// of screens that are all mutually reachable via navigation edges.
    /// SCCs are returned in reverse topological order (leaves first).
    static func computeSCCs(snapshot: GraphSnapshot) -> [[String]] {
        let fingerprints = Array(snapshot.nodes.keys).sorted()
        guard !fingerprints.isEmpty else { return [] }

        var index = 0
        var stack: [String] = []
        var onStack = Set<String>()
        var indices: [String: Int] = [:]
        var lowlinks: [String: Int] = [:]
        var result: [[String]] = []

        func strongconnect(_ v: String) {
            indices[v] = index
            lowlinks[v] = index
            index += 1
            stack.append(v)
            onStack.insert(v)

            // Consider successors of v
            let outEdges = snapshot.adjacency[v] ?? []
            // Deduplicate targets to avoid processing the same successor multiple times
            var seenTargets = Set<String>()
            for edge in outEdges {
                let w = edge.toFingerprint
                guard snapshot.nodes[w] != nil else { continue }
                guard seenTargets.insert(w).inserted else { continue }

                if indices[w] == nil {
                    // Successor w has not yet been visited; recurse
                    strongconnect(w)
                    lowlinks[v] = min(lowlinks[v] ?? 0, lowlinks[w] ?? 0)
                } else if onStack.contains(w) {
                    // Successor w is on stack and hence in the current SCC
                    lowlinks[v] = min(lowlinks[v] ?? 0, indices[w] ?? 0)
                }
            }

            // If v is a root node, pop the stack and generate an SCC
            if lowlinks[v] == indices[v] {
                var scc: [String] = []
                while true {
                    let w = stack.removeLast()
                    onStack.remove(w)
                    scc.append(w)
                    if w == v { break }
                }
                result.append(scc.sorted())
            }
        }

        for fp in fingerprints {
            if indices[fp] == nil {
                strongconnect(fp)
            }
        }

        return result
    }

    // MARK: - Condensation DAG

    /// Build a condensation DAG where each node is an SCC from the original graph.
    /// The DAG preserves inter-SCC edges while collapsing intra-SCC edges.
    static func condense(snapshot: GraphSnapshot, sccs: [[String]]) -> CondensationDAG {
        // Map each fingerprint to its SCC index
        var fpToSCCIndex: [String: Int] = [:]
        for (sccIdx, scc) in sccs.enumerated() {
            for fp in scc {
                fpToSCCIndex[fp] = sccIdx
            }
        }

        // Build SCC nodes with exploration status
        let sccNodes = sccs.enumerated().map { (sccIdx, fps) -> SCCNode in
            let fullyExplored = fps.allSatisfy { fp in
                guard let node = snapshot.nodes[fp] else { return false }
                let allVisited = node.elements.allSatisfy { node.visitedElements.contains($0.text) }
                return allVisited
            }
            return SCCNode(index: sccIdx, fingerprints: fps, isFullyExplored: fullyExplored)
        }

        // Build inter-SCC edges (deduplicated)
        var edgeSet = Set<String>()
        var dagEdges: [(from: Int, to: Int)] = []
        for edge in snapshot.edges {
            guard let fromSCC = fpToSCCIndex[edge.fromFingerprint],
                  let toSCC = fpToSCCIndex[edge.toFingerprint],
                  fromSCC != toSCC else { continue }
            let key = "\(fromSCC):\(toSCC)"
            if edgeSet.insert(key).inserted {
                dagEdges.append((from: fromSCC, to: toSCC))
            }
        }

        return CondensationDAG(nodes: sccNodes, edges: dagEdges)
    }

    // MARK: - Room Summary

    /// Compute SCCs and return a human-readable summary of the navigation "rooms".
    /// Example: "3 rooms: Home tab (5 screens), Search (3 screens), Profile (2 screens)"
    static func roomSummary(snapshot: GraphSnapshot) -> String {
        let sccs = computeSCCs(snapshot: snapshot)
        guard !sccs.isEmpty else { return "0 rooms" }

        let roomDescriptions = sccs.map { scc -> (String, Int) in
            let label = roomLabel(scc: scc, snapshot: snapshot)
            return (label, scc.count)
        }

        // Sort by screen count descending for readability
        let sorted = roomDescriptions.sorted { $0.1 > $1.1 }
        let roomCount = sorted.count
        let descriptions = sorted.map { (label, count) in
            "\(label) (\(count) \(count == 1 ? "screen" : "screens"))"
        }

        return "\(roomCount) \(roomCount == 1 ? "room" : "rooms"): \(descriptions.joined(separator: ", "))"
    }

    // MARK: - Private Helpers

    /// Derive a human-readable label for an SCC using the nav bar title of its shallowest screen.
    private static func roomLabel(scc: [String], snapshot: GraphSnapshot) -> String {
        // Find the screen with the lowest depth (shallowest) in the SCC
        let shallowest = scc
            .compactMap { fp -> (String, ScreenNode)? in
                guard let node = snapshot.nodes[fp] else { return nil }
                return (fp, node)
            }
            .min(by: { $0.1.depth < $1.1.depth })

        if let title = shallowest?.1.navBarTitle, !title.isEmpty {
            return title
        }

        // Fall back to the first element text of the shallowest screen
        if let firstElement = shallowest?.1.elements.first?.text, !firstElement.isEmpty {
            return firstElement
        }

        // Last resort: truncated fingerprint
        if let fp = shallowest?.0 {
            return String(fp.prefix(8))
        }

        return "unknown"
    }
}
