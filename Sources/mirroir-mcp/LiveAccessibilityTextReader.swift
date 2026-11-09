// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Reads the text a macOS app reports for one of its windows by walking that window's accessibility tree.
// ABOUTME: Bounded by a node limit and a per-request timeout, so a huge or hung app cannot hold the server.

import ApplicationServices
import CoreGraphics
import Foundation
import HelperLib

/// The live `AccessibilityTextReading`: asks the app that owns a window for
/// the elements inside it.
struct LiveAccessibilityTextReader: AccessibilityTextReading {

    /// The attributes read for every element, in one request.
    private static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
        kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ]

    /// The subrole of a field that hides what it holds.
    private static let secureFieldSubrole = "AXSecureTextField"

    func readText(in window: WindowInfo) -> Result<AccessibilityTextSnapshot, AccessibilityTextUnreadable> {
        guard AXIsProcessTrusted() else {
            return .failure(AccessibilityTextUnreadable(
                reason: "Accessibility is not granted to the app that runs mirroir"))
        }
        guard window.pid > 0 else {
            return .failure(AccessibilityTextUnreadable(reason: "the window has no process to ask"))
        }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, Float(EnvConfig.axTreeMessagingTimeoutMs) / 1000)
        guard let root = Self.matchingWindow(of: app, window) else {
            return .failure(AccessibilityTextUnreadable(
                reason: "the app reports no window at the target's position"))
        }

        // Breadth first, each element with the part of the window its
        // ancestors leave visible: a row scrolled out of a list is still in
        // the tree, but its frame lies outside the list's.
        var queue: [(element: AXUIElement, clip: CGRect, container: Int?)] = Self.children(of: root.element)
            .map { ($0, CGRect(origin: .zero, size: root.size), nil) }
        var nodes: [AccessibilityTextNode] = []
        var visited = 0
        var index = 0
        let limit = EnvConfig.axTreeMaxNodes
        while index < queue.count {
            guard visited < limit else {
                return .success(AccessibilityTextSnapshot(nodes: nodes, truncated: true))
            }
            let (element, clip, container) = queue[index]
            index += 1
            visited += 1
            let read = Self.read(element, windowOrigin: root.origin)
            guard read.subrole != Self.secureFieldSubrole else { continue }
            var visible = clip
            var nearest = container
            if let frame = read.frame {
                visible = frame.intersection(clip)
                guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
                if let text = read.text {
                    nearest = nodes.count
                    nodes.append(AccessibilityTextNode(
                        text: text, frame: visible, role: read.role ?? "", container: container))
                }
            }
            queue.append(contentsOf: read.children.map { ($0, visible, nearest) })
        }
        return .success(AccessibilityTextSnapshot(nodes: nodes, truncated: false))
    }

    // MARK: - Private

    /// The app's AX window whose geometry is the target's, with its origin and size.
    private static func matchingWindow(
        of app: AXUIElement, _ window: WindowInfo
    ) -> (element: AXUIElement, origin: CGPoint, size: CGSize)? {
        var candidates: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            candidates += windows
        }
        if let main = LiveMirroringProbe.axMainWindow(pid: window.pid) { candidates.append(main) }
        let sameGeometry = candidates.compactMap { candidate -> (AXUIElement, CGPoint, CGSize)? in
            guard let geometry = WindowListHelper.geometryFromAXElement(candidate),
                  WindowListHelper.matches(geometry.position.x, window.position.x),
                  WindowListHelper.matches(geometry.position.y, window.position.y),
                  WindowListHelper.matches(geometry.size.width, window.size.width),
                  WindowListHelper.matches(geometry.size.height, window.size.height) else { return nil }
            return (candidate, geometry.position, geometry.size)
        }
        // The tabs of a tabbed window share one geometry. The window server's
        // name for the target's window ID says which one is meant.
        let wanted = WindowListHelper.windowEntries().first { $0.windowID == window.windowID }?.name
        if let wanted, !wanted.isEmpty,
           let titled = sameGeometry.first(where: { WindowListHelper.title(of: $0.0) == wanted }) {
            return titled
        }
        return sameGeometry.first
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// What one element reports, read in a single request.
    private struct Element {
        var role: String?
        var subrole: String?
        var text: String?
        var frame: CGRect?
        var children: [AXUIElement] = []
    }

    private static func read(_ element: AXUIElement, windowOrigin: CGPoint) -> Element {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as? [Any], list.count == attributes.count else { return Element() }
        var read = Element()
        read.role = list[0] as? String
        read.subrole = list[1] as? String
        read.text = [list[2], list[3], list[4]].lazy
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let position = point(list[5]), let size = size(list[6]) {
            read.frame = CGRect(
                x: position.x - windowOrigin.x, y: position.y - windowOrigin.y,
                width: size.width, height: size.height)
        }
        read.children = list[7] as? [AXUIElement] ?? []
        return read
    }

    private static func point(_ value: Any) -> CGPoint? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // Safe cast: the CFTypeID check above confirms the type.
        return AXValueGetValue(unsafeDowncast(value as AnyObject, to: AXValue.self), .cgPoint, &point)
            ? point : nil
    }

    private static func size(_ value: Any) -> CGSize? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        // Safe cast: the CFTypeID check above confirms the type.
        return AXValueGetValue(unsafeDowncast(value as AnyObject, to: AXValue.self), .cgSize, &size)
            ? size : nil
    }
}
