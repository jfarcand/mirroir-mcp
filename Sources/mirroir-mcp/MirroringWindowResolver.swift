// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pure resolution of iPhone Mirroring window geometry and connection state from live snapshots.
// ABOUTME: Picks the window server's bounds for the mirroring window and classifies the paused overlay.

import ApplicationServices
import CoreGraphics
import Foundation

/// Turns one fresh set of AX and window-server snapshots into the bridge's
/// answers. Stateless: every call resolves from the snapshots it is handed.
enum MirroringWindowResolver {

    /// Button titles that dismiss a Continuity interruption overlay and free the
    /// session: the camera dialog's "OK" and the pause overlay's resume action
    /// (localized variants). Compared lower-cased.
    static let resumeControlTitles: Set<String> = [
        "ok", "resume", "try again", "reprendre", "continuer", "réessayer", "reessayer",
    ]

    /// Resolve the mirroring window's live geometry.
    ///
    /// The window server's bounds are authoritative: AX geometry can lag after
    /// a rotation or resize. The window-server entry is identified by the AX
    /// title first, which stays correct when the AX size is the lagging value;
    /// a size match against AX identifies it when the window server exposes no
    /// titles. AX geometry is reported only when neither identifies a window.
    /// Returns nil when nothing identifies a window and AX has no frame.
    static func windowInfo(
        pid: pid_t, axWindow: MirroringAXWindow, windowList: [WindowListEntry]
    ) -> WindowInfo? {
        let owned = windowList.filter { $0.ownerPID == pid }
        if let entry = titleMatch(owned, title: axWindow.title)
            ?? axWindow.frame.flatMap({ sizeMatch(owned, size: $0.size) }) {
            return WindowInfo(
                windowID: entry.windowID, position: entry.bounds.origin,
                size: entry.bounds.size, pid: pid)
        }
        guard let frame = axWindow.frame else { return nil }
        return WindowInfo(windowID: 0, position: frame.origin, size: frame.size, pid: pid)
    }

    /// Connection state of a live mirroring window.
    ///
    /// The active mirroring surface is an opaque video view: its hosting view
    /// has no AX children, or only unlabeled structural ones (groups, images)
    /// that say nothing and do not mean the frames stopped. An interruption
    /// always tells the user something: the "click to resume" overlay and
    /// Continuity dialogs carry a button, and the overlays with nothing to
    /// press (iPhone locked, connecting, iPhone in use) carry labeled text.
    /// Either one reads as paused, so input never goes into a dead session;
    /// the escape plugins then find no resume control and the paused error
    /// reaches the caller.
    static func state(of window: MirroringAXWindow) -> WindowState {
        guard let hosting = window.hostingView else { return .noWindow }
        return hosting.children.contains(where: isInterruption) ? .paused : .connected
    }

    /// Whether a button with `label` resumes or dismisses an interruption.
    /// An unlabeled button is the plain resume overlay's; a labeled one must
    /// name a known resume action, so a control that closes or quits
    /// Mirroring is never pressed.
    static func isResumeControl(label: String?) -> Bool {
        let normalized = label?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return normalized.isEmpty || resumeControlTitles.contains(normalized)
    }

    // MARK: - Private

    private static func titleMatch(_ entries: [WindowListEntry], title: String?) -> WindowListEntry? {
        guard let title, !title.isEmpty else { return nil }
        return largest(entries.filter { $0.name == title })
    }

    private static func sizeMatch(_ entries: [WindowListEntry], size: CGSize) -> WindowListEntry? {
        largest(entries.filter {
            WindowListHelper.matches($0.bounds.width, size.width)
                && WindowListHelper.matches($0.bounds.height, size.height)
        })
    }

    /// The entry with the largest area — the content window rather than an
    /// accessory sliver sharing its title or size. The first wins a tie.
    private static func largest(_ entries: [WindowListEntry]) -> WindowListEntry? {
        entries.reduce(nil) { best, entry in
            guard let best else { return entry }
            let area = entry.bounds.width * entry.bounds.height
            return area > best.bounds.width * best.bounds.height ? entry : best
        }
    }

    /// Whether `node` or a descendant is a button or labeled text: the
    /// content of an interruption overlay.
    private static func isInterruption(_ node: AXNodeSnapshot) -> Bool {
        if node.role == kAXButtonRole as String { return true }
        if node.role == kAXStaticTextRole as String,
           let label = node.label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return node.children.contains(where: isInterruption)
    }
}
