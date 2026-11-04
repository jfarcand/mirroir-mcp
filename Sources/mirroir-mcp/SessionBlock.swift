// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Describes a blocked mirroring session by quoting the window's own words and naming the move that frees it.
// ABOUTME: Pure classification over an AX snapshot; the refusal text every input and status path reports.

import ApplicationServices
import Foundation

/// A blocked session: what the window says and what frees it.
struct SessionBlock: Sendable, Equatable {
    /// The interstitial's words in reading order: static text as written,
    /// buttons in brackets (`[Try Again]`).
    let quoted: [String]
    /// The move that frees the session.
    let move: SessionBlockMove

    /// What the window says, as one sentence fragment.
    var said: String {
        if move == .reopenMirroring { return "nothing Accessibility can read" }
        return quoted.isEmpty
            ? "an interruption with no text"
            : quoted.map { $0.hasPrefix("[") ? $0 : "“\($0)”" }.joined(separator: " ")
    }

    /// The refusal for an action that was not sent because of this block.
    func refusal(targetName: String) -> String {
        "'\(targetName)' is not accepting input. The window says: \(said). "
            + "\(move.advice) No input was sent."
    }
}

/// Reads a paused mirroring window into a `SessionBlock` (pure transformation).
enum SessionBlockClassifier {

    /// Labels quoted from one window, at most this many: an interstitial
    /// says what it needs in its first few lines.
    static let maxQuotedLabels = 6

    /// The block a paused `window` shows. A window Accessibility cannot read
    /// needs iPhone Mirroring reopened. A text field in the overlay or an
    /// attached sheet is a credential prompt whatever its words say;
    /// otherwise the words pick the move, and words nothing matches leave the
    /// user to clear the window on the Mac.
    static func block(
        of window: MirroringAXWindow, phrases: InterstitialPhrases = .live
    ) -> SessionBlock {
        guard window.isWindow else { return SessionBlock(quoted: [], move: .reopenMirroring) }
        let quoted = Array(labels(of: window).prefix(maxQuotedLabels))
        if hasCredentialPrompt(window) {
            return SessionBlock(quoted: quoted, move: .approveOnMac)
        }
        let words = quoted.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        return SessionBlock(quoted: quoted, move: phrases.move(for: words) ?? .clearOnMac)
    }

    /// Whether the window shows a prompt for a credential: a text or secure
    /// text field in the overlay or in an attached sheet. Nothing is ever
    /// pressed or typed into such a prompt; the user answers it on the Mac.
    static func hasCredentialPrompt(_ window: MirroringAXWindow) -> Bool {
        roots(of: window).contains(where: containsTextField)
    }

    /// Non-empty labels of the static text and buttons under the hosting view
    /// and the attached sheets, in tree order, duplicates dropped. Toolbar
    /// chrome is skipped: it says nothing about the interruption.
    static func labels(of window: MirroringAXWindow) -> [String] {
        var seen = Set<String>()
        return roots(of: window).flatMap(collect).filter { seen.insert($0).inserted }
    }

    // MARK: - Private

    private static func roots(of window: MirroringAXWindow) -> [AXNodeSnapshot] {
        (window.hostingView.map { [$0] } ?? []) + window.sheets
    }

    private static func collect(_ node: AXNodeSnapshot) -> [String] {
        if MirroringWindowResolver.isToolbarControl(node) { return [] }
        let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var own: [String] = []
        if !label.isEmpty {
            if node.role == kAXStaticTextRole as String { own = [label] }
            if node.role == kAXButtonRole as String { own = ["[\(label)]"] }
        }
        return own + node.children.flatMap(collect)
    }

    /// Whether `node` or a descendant is a text field or secure text field.
    private static func containsTextField(_ node: AXNodeSnapshot) -> Bool {
        if node.role == kAXTextFieldRole as String
            || node.subrole == kAXSecureTextFieldSubrole as String {
            return true
        }
        return node.children.contains(where: containsTextField)
    }
}
