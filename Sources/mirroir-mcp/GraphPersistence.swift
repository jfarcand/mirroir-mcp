// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Saves and loads NavigationGraph state to disk for incremental exploration (Fastbot2 pattern).
// ABOUTME: Subsequent runs load the graph and skip known screens, focusing on unexplored edges.

import Foundation
import HelperLib

/// Serializable representation of a TapPoint for graph persistence.
/// Strips confidence (not useful across sessions) and pageY (viewport-specific).
struct SerializableTapPoint: Codable, Sendable {
    let text: String
    let tapX: Double
    let tapY: Double

    init(from tapPoint: TapPoint) {
        self.text = tapPoint.text
        self.tapX = tapPoint.tapX
        self.tapY = tapPoint.tapY
    }

    func toTapPoint() -> TapPoint {
        TapPoint(text: text, tapX: tapX, tapY: tapY, confidence: 0.9)
    }
}

/// Serializable representation of a DetectedIcon for graph persistence.
struct SerializableIcon: Codable, Sendable {
    let tapX: Double
    let tapY: Double
    let estimatedSize: Double

    init(from icon: IconDetector.DetectedIcon) {
        self.tapX = icon.tapX
        self.tapY = icon.tapY
        self.estimatedSize = icon.estimatedSize
    }

    func toDetectedIcon() -> IconDetector.DetectedIcon {
        IconDetector.DetectedIcon(tapX: tapX, tapY: tapY, estimatedSize: estimatedSize)
    }
}

/// Serializable screen node (excludes screenshotBase64 to keep file size small).
struct SerializableScreenNode: Codable, Sendable {
    let fingerprint: String
    let elements: [SerializableTapPoint]
    let icons: [SerializableIcon]
    let hints: [String]
    let depth: Int
    let screenType: String
    let visitedElements: [String]
    let navBarTitle: String?
    let isInfiniteScroll: Bool
    let scrollExhausted: Bool

    init(from node: ScreenNode) {
        self.fingerprint = node.fingerprint
        self.elements = node.elements.map { SerializableTapPoint(from: $0) }
        self.icons = node.icons.map { SerializableIcon(from: $0) }
        self.hints = node.hints
        self.depth = node.depth
        self.screenType = node.screenType.rawValue
        self.visitedElements = Array(node.visitedElements)
        self.navBarTitle = node.navBarTitle
        self.isInfiniteScroll = node.isInfiniteScroll
        self.scrollExhausted = node.scrollExhausted
    }

    func toScreenNode() -> ScreenNode {
        ScreenNode(
            fingerprint: fingerprint,
            elements: elements.map { $0.toTapPoint() },
            icons: icons.map { $0.toDetectedIcon() },
            hints: hints,
            depth: depth,
            screenType: ScreenType(rawValue: screenType) ?? .unknown,
            screenshotBase64: "",
            visitedElements: Set(visitedElements),
            navBarTitle: navBarTitle,
            isInfiniteScroll: isInfiniteScroll,
            scrollExhausted: scrollExhausted
        )
    }
}

/// Serializable navigation edge.
struct SerializableEdge: Codable, Sendable {
    let fromFingerprint: String
    let toFingerprint: String
    let actionType: String
    let elementText: String
    let displayLabel: String
    let edgeType: String

    init(from edge: NavigationEdge) {
        self.fromFingerprint = edge.fromFingerprint
        self.toFingerprint = edge.toFingerprint
        self.actionType = edge.actionType
        self.elementText = edge.elementText
        self.displayLabel = edge.displayLabel
        self.edgeType = edge.edgeType.rawValue
    }

    func toNavigationEdge() -> NavigationEdge {
        NavigationEdge(
            fromFingerprint: fromFingerprint,
            toFingerprint: toFingerprint,
            actionType: actionType,
            elementText: elementText,
            displayLabel: displayLabel,
            edgeType: EdgeType(rawValue: edgeType) ?? .push
        )
    }
}

/// Top-level serializable graph format for persistence.
struct SerializableGraph: Codable, Sendable {
    let version: Int
    let savedAt: Date
    let rootFingerprint: String
    let nodes: [SerializableScreenNode]
    let edges: [SerializableEdge]
    let deadEdges: [String]
    /// CEGAR refinement levels per fingerprint (optional for backward compatibility).
    let refinementLevels: [String: StateAbstraction.RefinementLevel]?

    /// Current format version. Bump when the schema changes.
    static let currentVersion = 1
}

/// Saves and loads NavigationGraph state to disk for incremental exploration.
/// Pure transformation: all static methods, no stored state.
enum GraphPersistence {

    /// Base directory for persisted graphs.
    static let graphsDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mirroir-mcp/graphs")
    }()

    /// Save a graph snapshot to disk.
    ///
    /// - Parameters:
    ///   - snapshot: The graph snapshot to persist.
    ///   - bundleID: The app's bundle identifier (used as filename).
    /// - Returns: The file URL where the graph was saved, or nil on failure.
    @discardableResult
    static func save(snapshot: GraphSnapshot, bundleID: String) -> URL? {
        let fileURL = graphURL(for: bundleID)

        let serializable = SerializableGraph(
            version: SerializableGraph.currentVersion,
            savedAt: Date(),
            rootFingerprint: snapshot.rootFingerprint,
            nodes: snapshot.nodes.values.map { SerializableScreenNode(from: $0) },
            edges: snapshot.edges.map { SerializableEdge(from: $0) },
            deadEdges: Array(snapshot.deadEdges),
            refinementLevels: snapshot.refinementLevels.isEmpty ? nil : snapshot.refinementLevels
        )

        do {
            try FileManager.default.createDirectory(
                at: graphsDirectory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(serializable)
            try data.write(to: fileURL, options: .atomic)
            DebugLog.log("persistence", "Saved graph for \(bundleID): " +
                "\(snapshot.nodes.count) nodes, \(snapshot.edges.count) edges → \(fileURL.path)")
            return fileURL
        } catch {
            DebugLog.log("persistence", "Failed to save graph for \(bundleID): \(error)")
            return nil
        }
    }

    /// Load a previously saved graph from disk.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: A loaded GraphSnapshot, or nil if no graph exists or decoding fails.
    static func load(bundleID: String) -> GraphSnapshot? {
        let fileURL = graphURL(for: bundleID)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            DebugLog.log("persistence", "No persisted graph for \(bundleID)")
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let serializable = try decoder.decode(SerializableGraph.self, from: data)

            guard serializable.version == SerializableGraph.currentVersion else {
                DebugLog.log("persistence", "Stale graph version \(serializable.version) " +
                    "for \(bundleID), expected \(SerializableGraph.currentVersion)")
                return nil
            }

            var nodes: [String: ScreenNode] = [:]
            for node in serializable.nodes {
                let screenNode = node.toScreenNode()
                nodes[screenNode.fingerprint] = screenNode
            }

            let snapshot = GraphSnapshot(
                nodes: nodes,
                edges: serializable.edges.map { $0.toNavigationEdge() },
                rootFingerprint: serializable.rootFingerprint,
                deadEdges: Set(serializable.deadEdges),
                recoveryEvents: [],
                refinementLevels: serializable.refinementLevels ?? [:]
            )

            DebugLog.log("persistence", "Loaded graph for \(bundleID): " +
                "\(nodes.count) nodes, \(serializable.edges.count) edges " +
                "(saved \(serializable.savedAt))")
            return snapshot
        } catch {
            DebugLog.log("persistence", "Failed to load graph for \(bundleID): \(error)")
            return nil
        }
    }

    /// Delete the persisted graph for an app.
    ///
    /// - Parameter bundleID: The app's bundle identifier.
    /// - Returns: true if the file was deleted, false if it didn't exist or deletion failed.
    @discardableResult
    static func delete(bundleID: String) -> Bool {
        let fileURL = graphURL(for: bundleID)
        do {
            try FileManager.default.removeItem(at: fileURL)
            DebugLog.log("persistence", "Deleted graph for \(bundleID)")
            return true
        } catch {
            return false
        }
    }

    /// Check if a persisted graph exists for an app.
    static func exists(bundleID: String) -> Bool {
        FileManager.default.fileExists(atPath: graphURL(for: bundleID).path)
    }

    // MARK: - Helpers

    /// Build the file URL for a given bundle ID.
    /// Sanitizes the bundle ID to be a safe filename.
    static func graphURL(for bundleID: String) -> URL {
        let safeName = bundleID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return graphsDirectory.appendingPathComponent("\(safeName).json")
    }
}
