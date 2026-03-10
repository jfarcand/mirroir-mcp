// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Value types used by BFSExplorer: frontier screens, path segments, and phase state.
// ABOUTME: Extracted from BFSExplorer to keep file sizes within the 500-line limit.

import Foundation

/// A screen in the BFS frontier queue waiting to be explored.
struct FrontierScreen: Sendable {
    /// Structural fingerprint identifying this screen.
    let fingerprint: String
    /// Element taps to replay from root to reach this screen.
    let pathFromRoot: [PathSegment]
    /// BFS depth (0 = root).
    let depth: Int
}

/// One step in the path from root to a frontier screen.
struct PathSegment: Sendable {
    /// Text of the element to tap.
    let elementText: String
    /// X coordinate of the element.
    let tapX: Double
    /// Y coordinate of the element.
    let tapY: Double
}

/// BFS explorer state machine phases.
enum BFSPhase {
    /// At root, ready to dequeue and process next frontier screen.
    case atRoot
    /// Navigating from root to a frontier screen by replaying path.
    case navigating(target: FrontierScreen, pathIndex: Int)
    /// At a frontier screen, exploring elements one by one.
    case exploring(screen: FrontierScreen)
    /// Navigating back to root after exploring a screen.
    case returning(depthRemaining: Int)
}

/// Tracks tap coordinates per screen to prevent tapping the same area repeatedly.
/// Uses a proximity radius to detect when a new tap target overlaps a previously tapped area.
struct TapAreaCache: Sendable {

    /// Minimum distance in points between two taps for them to be considered distinct areas.
    static let proximityRadius: Double = 30.0

    /// Recorded tap coordinates as (x, y) pairs.
    private var tappedPoints: [(x: Double, y: Double)] = []

    /// Record a tap at the given coordinates.
    mutating func record(x: Double, y: Double) {
        tappedPoints.append((x: x, y: y))
    }

    /// Check whether a point is within `proximityRadius` of any previously tapped coordinate.
    func wasAlreadyTapped(x: Double, y: Double) -> Bool {
        tappedPoints.contains { existing in
            let dx = existing.x - x
            let dy = existing.y - y
            return (dx * dx + dy * dy).squareRoot() < Self.proximityRadius
        }
    }

    /// Number of recorded tap points.
    var count: Int { tappedPoints.count }
}
