// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Value snapshots of the iPhone Mirroring window read from Accessibility.
// ABOUTME: Produced fresh per call by a MirroringSystemProbing and consumed by MirroringWindowResolver.

import CoreGraphics

/// One node of an Accessibility subtree, copied out of AX so it can be
/// classified without holding (or faking) live `AXUIElement` references.
struct AXNodeSnapshot: Sendable, Equatable {
    /// AX role, e.g. `AXButton`, `AXGroup`, `AXStaticText`.
    let role: String?
    /// The node's title, else its description, else its string value (the
    /// words of static text).
    let label: String?
    /// Child nodes, depth-bounded by the probe that built the snapshot.
    let children: [AXNodeSnapshot]

    init(role: String?, label: String? = nil, children: [AXNodeSnapshot] = []) {
        self.role = role
        self.label = label
        self.children = children
    }
}

/// The iPhone Mirroring main window as Accessibility reports it at one instant.
struct MirroringAXWindow: Sendable, Equatable {
    /// Window title (`AXTitle`), matched against the window server's window
    /// name to pick the right window without trusting AX geometry.
    let title: String?
    /// AX frame in global top-left coordinates, or nil when AX reports no size.
    let frame: CGRect?
    /// The window's first child (the SwiftUI hosting view) and its subtree, or
    /// nil when the window has no children.
    let hostingView: AXNodeSnapshot?
}
