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
// ABOUTME: Pure resolution of iPhone Mirroring window geometry and connection state from live snapshots.
// ABOUTME: Picks the window server's bounds for the mirroring window and classifies the paused overlay.

import ApplicationServices
import CoreGraphics
import Foundation

/// Turns one fresh set of AX and window-server snapshots into the bridge's
/// answers. Stateless: every call resolves from the snapshots it is handed.
enum MirroringWindowResolver {

    /// Subroles of the window's own traffic-light controls. iPhone Mirroring
    /// hosts them inside the hosting view, where they surface whenever the
    /// toolbar is revealed; they are chrome, not an interruption.
    static let windowControlSubroles: Set<String> = [
        kAXCloseButtonSubrole as String, kAXZoomButtonSubrole as String,
        kAXMinimizeButtonSubrole as String, kAXFullScreenButtonSubrole as String,
    ]

    /// Identifiers of the toolbar's Home and App Switcher buttons. The
    /// identifiers are locale-independent; their labels are not.
    static let toolbarControlIdentifiers: Set<String> = [
        "app.grid.3x3", "iphone.app.switcher",
    ]

    /// Identifiers of the Mac's own text-input UI drawn over the window while
    /// keys are typed into it: the autocorrection bubble ("Horloge" with a
    /// close button after typing "horloge"). It belongs to the Mac, not to
    /// an interruption, and goes away with the next keystroke or click.
    static let macTextInputIdentifiers: Set<String> = [
        "NSAutocorrectionSuggestion",
    ]

    /// Resolve the mirroring window's live geometry.
    ///
    /// The window server's bounds are authoritative: AX geometry can lag after
    /// a rotation or resize. The window-server entry is identified by the AX
    /// title first, which stays correct when the AX size is the lagging value;
    /// a size match against AX identifies it when the window server exposes no
    /// titles. AX geometry is reported only when neither identifies a window.
    ///
    /// One exception: when the window server shows the window as a thumbnail
    /// (the Stage Manager strip, Mission Control), its bounds are that scaled
    /// copy while AX keeps the frame the window takes once it is shown. The
    /// AX frame is then reported, with the window server's ID for capture;
    /// see `isThumbnail`.
    /// Returns nil when nothing identifies a window and AX has no frame.
    static func windowInfo(
        pid: pid_t, axWindow: MirroringAXWindow, windowList: [WindowListEntry]
    ) -> WindowInfo? {
        let owned = windowList.filter { $0.ownerPID == pid }
        if let entry = titleMatch(owned, title: axWindow.title)
            ?? axWindow.frame.flatMap({ sizeMatch(owned, size: $0.size) }) {
            if let frame = axWindow.frame, isThumbnail(entry.bounds.size, of: frame.size) {
                return WindowInfo(
                    windowID: entry.windowID, position: frame.origin, size: frame.size, pid: pid)
            }
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
    /// reaches the caller. Revealing the toolbar adds the window controls and
    /// the Home / App Switcher buttons to the same subtree; those are window
    /// chrome over a live session and never read as paused.
    ///
    /// Buttons with no label and no labeled text anywhere are ambiguous: a
    /// live macOS 27 window exposes such buttons over the video. The frame
    /// decides them: `frameIsBlank` is asked only then, and a frame showing
    /// content reads as connected.
    static func state(of window: MirroringAXWindow, frameIsBlank: () -> Bool) -> WindowState {
        // An unreadable AX tree cannot show an interruption, so it cannot
        // prove the session live: it reads as blocked, never as connected.
        guard window.isWindow else { return .paused }
        guard let hosting = window.hostingView else { return .noWindow }
        // A sheet attached to the window (a Mac password or Touch ID prompt)
        // takes every click until it is answered.
        if !window.sheets.isEmpty { return .paused }
        switch hosting.children.map(overlayContent).max() ?? .none {
        case .none: return .connected
        case .labeled: return .paused
        case .unlabeledControls: return frameIsBlank() ? .paused : .connected
        }
    }

    /// Whether a button with `label` resumes or dismisses an interruption.
    /// Only a button naming a known resume action qualifies, in English or in
    /// the Mac's language as iPhone Mirroring's own strings render it
    /// (`InterstitialPhrases.resumeControlKeys`). An unlabeled
    /// button is explicitly NOT a resume control: AX-pressing the overlay's
    /// first unlabeled button terminates iPhone Mirroring when that button is a
    /// close/quit control rather than the resume one, so it is never pressed —
    /// a paused session with only an unlabeled control is left for a manual
    /// resume instead of risking the crash.
    static func isResumeControl(label: String?, phrases: InterstitialPhrases = .live) -> Bool {
        phrases.isResumeControl(label: label)
    }

    /// Largest share of the AX frame's area a window-server size may cover
    /// and still be read as a thumbnail of it. Measured on macOS 26.5: the
    /// Stage Manager strip shows a 430x942 window at 47x141 (1.6% of its
    /// area), Mission Control at 228x499 (28%). A rotation keeps the area and
    /// a resize of the mirroring window changes it far less than half.
    static let thumbnailAreaRatio: CGFloat = 0.5

    /// Whether `shown` is a scaled-down presentation of a window whose real
    /// size is `frame`, rather than the window itself.
    static func isThumbnail(_ shown: CGSize, of frame: CGSize) -> Bool {
        let frameArea = frame.width * frame.height
        return frameArea > 0 && shown.width * shown.height < frameArea * thumbnailAreaRatio
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

    // MARK: - Overlay content

    /// What an overlay subtree carries, ordered by how surely it means an
    /// interruption.
    enum OverlayContent: Int, Comparable {
        /// Nothing that speaks: the live surface or its structural children.
        case none
        /// Buttons, none labeled, and no labeled text.
        case unlabeledControls
        /// A labeled button or labeled text: an interstitial talking.
        case labeled

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The strongest overlay content in `node` and its descendants. Toolbar
    /// chrome is skipped whole.
    static func overlayContent(_ node: AXNodeSnapshot) -> OverlayContent {
        if isChrome(node) { return .none }
        let hasLabel = !(node.label?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        var own = OverlayContent.none
        if node.role == kAXButtonRole as String {
            own = hasLabel ? .labeled : .unlabeledControls
        } else if node.role == kAXStaticTextRole as String, hasLabel {
            own = .labeled
        }
        return ([own] + node.children.map(overlayContent)).max() ?? own
    }

    /// Whether `node` is chrome the Mac draws over a live session: a window
    /// or toolbar control, or the Mac's text-input UI. Skipped whole.
    static func isChrome(_ node: AXNodeSnapshot) -> Bool {
        if let identifier = node.identifier, macTextInputIdentifiers.contains(identifier) {
            return true
        }
        return isToolbarControl(node)
    }

    /// Whether `node` is a window control or a toolbar button: chrome that
    /// shows over a live session when the toolbar is revealed.
    static func isToolbarControl(_ node: AXNodeSnapshot) -> Bool {
        guard node.role == kAXButtonRole as String else { return false }
        if let subrole = node.subrole, windowControlSubroles.contains(subrole) { return true }
        if let identifier = node.identifier, toolbarControlIdentifiers.contains(identifier) {
            return true
        }
        return false
    }
}
