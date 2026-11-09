// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Turns the text a macOS app reports through its accessibility tree into tap points, and merges them with text read from pixels.
// ABOUTME: Pure: the tree is read elsewhere (AccessibilityTextReading) and arrives here as values.

import CoreGraphics
import Foundation
import HelperLib

/// One element of a window's accessibility tree that carries text.
struct AccessibilityTextNode: Sendable, Equatable {
    /// The element's title, else its string value, else its description.
    let text: String
    /// Its frame in window-local points, clipped to what its ancestors show.
    let frame: CGRect
    /// Its AX role, e.g. `AXButton`.
    let role: String
    /// Index, in the snapshot, of the nearest ancestor that carries text too;
    /// nil when no ancestor does.
    let container: Int?

    init(text: String, frame: CGRect, role: String, container: Int? = nil) {
        self.text = text
        self.frame = frame
        self.role = role
        self.container = container
    }
}

/// The text nodes of one window, as read in one pass.
struct AccessibilityTextSnapshot: Sendable, Equatable {
    let nodes: [AccessibilityTextNode]
    /// The walk stopped at its node limit, so the list may be incomplete.
    let truncated: Bool
}

/// Why a window's accessibility tree could not be read.
struct AccessibilityTextUnreadable: Error, Equatable, Sendable {
    let reason: String
}

/// Text from the accessibility tree, as tap points.
///
/// A macOS app reports its own text exactly, with each element's frame; OCR
/// reads the same text from pixels and can misread it. Both are listed, each
/// marked with where it came from, and a pixel reading is dropped when the
/// tree already reports that text at that place.
enum AccessibilityTreeText {

    /// The confidence of text the OS itself reported.
    static let treeConfidence: Float = 1.0

    /// Longest text that is still a label. A text area reports everything it
    /// holds as one value (a terminal, its whole scrollback): that is content,
    /// read line by line from pixels, not a label to tap.
    static let maxLabelLength = 200

    /// How close a node's frame may come to the window's, in points, before
    /// it is taken for the window's own label.
    static let windowFrameTolerance: CGFloat = 4

    /// The nodes that are labels of something the user can see and tap, as
    /// measured on real apps:
    /// - not a container: a node whose descendant carries text names a region
    ///   (a browser, a list), and its centre is not where that name is drawn;
    /// - not the window's own label: a node as large as the window (the single
    ///   group an app exposes when its content has no tree);
    /// - one line, of label length;
    /// - with a frame, whose centre is inside the window.
    static func labels(in snapshot: AccessibilityTextSnapshot, windowSize: CGSize) -> [AccessibilityTextNode] {
        let window = CGRect(origin: .zero, size: windowSize)
        let containers = Set(snapshot.nodes.compactMap(\.container))
        return snapshot.nodes.enumerated().compactMap { index, node in
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !containers.contains(index), !text.isEmpty, text.count <= maxLabelLength,
                  !text.contains(where: \.isNewline),
                  node.frame.width > 0, node.frame.height > 0,
                  window.contains(CGPoint(x: node.frame.midX, y: node.frame.midY)),
                  !coversTheWindow(node.frame, window) else { return nil }
            return AccessibilityTextNode(text: text, frame: node.frame, role: node.role)
        }
    }

    private static func coversTheWindow(_ frame: CGRect, _ window: CGRect) -> Bool {
        abs(frame.minX - window.minX) <= windowFrameTolerance
            && abs(frame.minY - window.minY) <= windowFrameTolerance
            && abs(frame.width - window.width) <= windowFrameTolerance
            && abs(frame.height - window.height) <= windowFrameTolerance
    }

    /// One tap point per label, at its frame's centre, marked `.tree`.
    static func tapPoints(from snapshot: AccessibilityTextSnapshot, windowSize: CGSize) -> [TapPoint] {
        labels(in: snapshot, windowSize: windowSize).map { node in
            TapPoint(text: node.text, tapX: node.frame.midX, tapY: node.frame.midY,
                     confidence: treeConfidence, source: .tree)
        }
    }

    /// The tree's tap points, plus every pixel-read element the tree does not
    /// already report: one whose tap point lies inside a node's frame, and
    /// whose text contains that node's text or is contained in it, is the
    /// same text read twice, and the exact copy is kept.
    static func merge(snapshot: AccessibilityTextSnapshot, pixels: [TapPoint], windowSize: CGSize) -> [TapPoint] {
        let nodes = labels(in: snapshot, windowSize: windowSize)
        let kept = pixels.filter { element in
            let point = CGPoint(x: element.tapX, y: element.tapY)
            let text = fold(element.text)
            return !nodes.contains { node in
                let reported = fold(node.text)
                return !text.isEmpty && !reported.isEmpty && node.frame.contains(point)
                    && (reported.contains(text) || text.contains(reported))
            }
        }
        return nodes.map { node in
            TapPoint(text: node.text, tapX: node.frame.midX, tapY: node.frame.midY,
                     confidence: treeConfidence, source: .tree)
        } + kept
    }

    /// Text reduced for comparison: no case, no accents, no surrounding space.
    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
