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
// ABOUTME: Opens an iPhone app from Mac Spotlight (macOS 27): shows the panel, sets the query, clicks the "From iPhone" row.
// ABOUTME: The query is set through Accessibility, never typed, and the click is posted only where Spotlight's own window is.

import AppKit
import ApplicationServices
import HelperLib

/// What a Mac Spotlight launch attempt did.
enum MacSpotlightOutcome: Equatable {
    /// The iPhone app's row was clicked; the app should now open in Mirroring.
    case clicked
    /// Nothing was clicked, for this reason; the panel was left closed.
    case skipped(String)
    /// Nothing was clicked, and Spotlight's panel would not close: keys sent
    /// now would go to it, not to the iPhone.
    case panelLeftOpen(String)
}

/// Opens an iPhone app through Mac Spotlight's "<name>.app — From iPhone" row.
protocol MacAppLaunching: Sendable {
    func open(appNamed name: String) -> MacSpotlightOutcome
}

/// The live launcher. macOS opens an iPhone app in Mirroring only for Spotlight
/// itself (the launch needs a private entitlement): `open` on the app's
/// placeholder bundle fails, and neither Return sent to Spotlight's process nor
/// AXConfirm on its field opens the row. A click on the row does.
struct MacSpotlightLauncher: MacAppLaunching {
    /// The process hosting Mac Spotlight's panel on macOS 27 (shown as "Siri").
    static let hostBundleID = "com.apple.campo"
    static let fieldIdentifier = "SpotlightSearchField"
    private static let pollUs: UInt32 = 100_000
    private static let panelTimeoutUs: UInt32 = 2_000_000
    private static let resultsSettleUs: UInt32 = 500_000
    private static let lateOpenUs: UInt32 = 2_000_000
    private static let closeTimeoutUs: UInt32 = 1_000_000

    func open(appNamed name: String) -> MacSpotlightOutcome {
        guard let host = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.hostBundleID).first else {
            return .skipped("Mac Spotlight's host (\(Self.hostBundleID)) is not running")
        }
        let pid = host.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        // A panel already up is the user's: its query is not overwritten, and
        // the shortcut would close it.
        if Self.panelShowing(pid: pid) {
            return .skipped("Mac Spotlight is already open, so it was left as it is")
        }
        guard let hotkey = SpotlightHotkey.configured() else {
            return .skipped("Mac Spotlight's keyboard shortcut is turned off")
        }
        Self.post(hotkey)
        let started = DispatchTime.now()
        guard let field = Self.poll(Self.panelTimeoutUs, { Self.searchField(in: app) }) else {
            // It can still open after the wait; it must not be left up for
            // the iPhone's Spotlight step, whose keys it would take.
            let late = Self.poll(Self.lateOpenUs) { Self.panelShowing(pid: pid) ? true : nil } != nil
            let closed = !late || Self.closePanel(field: nil, pid: pid, hotkey: hotkey)
            return Self.skip("Mac Spotlight did not open", late: late, closed: closed)
        }
        DebugLog.log("macSpotlight", "panel open after \(Self.elapsedMs(since: started))ms")
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, name as CFString) == .success else {
            let closed = Self.closePanel(field: field, pid: pid, hotkey: hotkey)
            return Self.skip("Mac Spotlight's search field did not take '\(name)'", closed: closed)
        }
        guard let row = Self.waitForIPhoneRow(named: name, in: app) else {
            let closed = Self.closePanel(field: field, pid: pid, hotkey: hotkey)
            return Self.skip("Mac Spotlight lists no iPhone app named '\(name)'", closed: closed)
        }
        guard let point = Self.clickPoint(of: row),
              WindowListHelper.topmostWindowOwnerPID(at: point) == pid else {
            let closed = Self.closePanel(field: field, pid: pid, hotkey: hotkey)
            return Self.skip("the '\(name)' row in Mac Spotlight is covered or off screen", closed: closed)
        }
        Self.click(at: point)
        // Opening the row closes the panel; one still up after the wait is closed.
        if Self.poll(Self.closeTimeoutUs, { Self.panelShowing(pid: pid) ? nil : true }) == nil {
            DebugLog.log("macSpotlight", "panel still open after the click; closing it")
            _ = Self.closePanel(field: nil, pid: pid, hotkey: hotkey)
        }
        return .clicked
    }

    /// The outcome of a launch that clicked nothing, logged with what became
    /// of the panel. A panel that would not close is `.panelLeftOpen`: the
    /// iPhone's Spotlight step must not run under it.
    private static func skip(_ reason: String, late: Bool = false, closed: Bool) -> MacSpotlightOutcome {
        DebugLog.log("macSpotlight", "\(reason)\(late ? "; it opened late" : ""); panel closed: \(closed)")
        return closed ? .skipped(reason) : .panelLeftOpen(reason)
    }

    /// Clear the query, then close the panel with the shortcut, which toggles
    /// it: it is pressed only while a Spotlight window is on screen, and the
    /// window list is read again after each press. True once none is.
    private static func closePanel(field: AXUIElement?, pid: pid_t, hotkey: SpotlightHotkey) -> Bool {
        if let field { AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) }
        for _ in 0 ..< 2 {
            guard panelShowing(pid: pid) else { return true }
            post(hotkey)
            if poll(closeTimeoutUs, { panelShowing(pid: pid) ? nil : true }) != nil { return true }
        }
        return !panelShowing(pid: pid)
    }

    /// Whether Spotlight's host has a window on screen: its panel. The host
    /// shows none while Spotlight is closed.
    static func panelShowing(pid: pid_t) -> Bool {
        WindowListHelper.windowEntries(onScreenOnly: true).contains { $0.ownerPID == pid && $0.layer > 0 }
    }

    private static func elapsedMs(since start: DispatchTime) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Accessibility

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Depth-first search under the host's windows, bounded so a large tree
    /// cannot stall a launch.
    private static func first(in app: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var stack = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).reversed().map { $0 }
        var visited = 0
        while let element = stack.popLast(), visited < 2_000 {
            visited += 1
            if match(element) { return element }
            stack.append(contentsOf: children(element).reversed())
        }
        return nil
    }

    static func searchField(in app: AXUIElement) -> AXUIElement? {
        first(in: app) { (attribute($0, "AXIdentifier") as? String) == fieldIdentifier }
    }

    /// The result cell whose texts name the iPhone app `name`.
    static func iPhoneRow(named name: String, in app: AXUIElement) -> AXUIElement? {
        first(in: app) { element in
            guard isCell(element) else { return false }
            let texts = children(element).compactMap { attribute($0, kAXValueAttribute) as? String }
            return MacSpotlightMatch.isIPhoneApp(rowTexts: texts, named: name)
        }
    }

    /// The iPhone app's row, waiting up to `macSpotlightResultsTimeoutUs`, or
    /// `resultsSettleUs` past the first results when they hold no such row:
    /// Apple's own apps have no "From iPhone" row, and the iPhone's Spotlight
    /// should not wait the whole timeout for them.
    private static func waitForIPhoneRow(named name: String, in app: AXUIElement) -> AXUIElement? {
        let timeout = EnvConfig.macSpotlightResultsTimeoutUs
        var waited: UInt32 = 0
        var resultsSince: UInt32?
        while true {
            if let row = iPhoneRow(named: name, in: app) { return row }
            if resultsSince == nil, first(in: app, where: isCell) != nil { resultsSince = waited }
            if waited >= timeout { return nil }
            if let since = resultsSince, waited - since >= resultsSettleUs { return nil }
            usleep(pollUs)
            waited += pollUs
        }
    }

    private static func isCell(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXRoleAttribute) as? String) == (kAXCellRole as String)
    }

    /// A point on the row's name, left of the inline buttons some rows show
    /// on their right.
    private static func clickPoint(of row: AXUIElement) -> CGPoint? {
        guard let positionValue = attribute(row, kAXPositionAttribute),
              let sizeValue = attribute(row, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: position.x + size.width * 0.3, y: position.y + size.height / 2)
    }

    // MARK: - Events

    private static func post(_ hotkey: SpotlightHotkey) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: hotkey.keyCode, keyDown: down)
            else { continue }
            event.flags = CGEventFlags(rawValue: hotkey.modifierFlags)
            event.post(tap: .cghidEventTap)
        }
    }

    /// One left click at `point`, then the pointer goes back where it was.
    private static func click(at point: CGPoint) {
        let before = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(EnvConfig.clickHoldUs)
        }
        if let before { CGWarpMouseCursorPosition(before) }
    }

    private static func poll<T>(_ timeoutUs: UInt32, _ read: () -> T?) -> T? {
        var waited: UInt32 = 0
        while true {
            if let value = read() { return value }
            guard waited < timeoutUs else { return nil }
            usleep(pollUs)
            waited += pollUs
        }
    }
}
