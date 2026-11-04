// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Data model for the simulator: section of APP.md — declarative scene graph for FakeMirroring.
// ABOUTME: A SimulatorSpec captures every screen, element, and obstacle the simulator needs to reproduce.

import CoreGraphics
import Foundation

/// How the simulator renders the bottom tab bar for an app.
/// Declared once per app via `- tab_bar_style: …` in the `## Simulator` section.
public enum SimulatorTabBarStyle: String, Sendable, Equatable {
    /// Icon glyphs with OCR-readable text labels beneath (default).
    case labels
    /// Icon glyphs only — no text anywhere in the bar. OCR finds nothing;
    /// Vision saliency / icon detection must locate the tab targets.
    case icons
}

/// Declarative scene graph extracted from an APP.md's `## Simulator …` sections.
/// FakeMirroring builds a runnable AppPack from this at startup.
public struct SimulatorSpec: Sendable, Equatable {
    /// The user-visible app name (matches `frontmatter.app`).
    public let appName: String
    /// What `mirroir__launch_app` types into Spotlight to reach this app.
    /// Defaults to `appName` when omitted.
    public let spotlightName: String
    /// Single-glyph icon rendered on the home screen and App Switcher card.
    /// Falls back to the first character of `appName` when omitted.
    public let icon: String
    /// ID of the screen that becomes active on app launch.
    public let rootScreenID: String
    /// How screens with `tab_bar: true` render their bottom bar.
    public let tabBarStyle: SimulatorTabBarStyle
    /// All screens keyed by ID.
    public let screens: [String: SimulatorScreen]
    /// Modal obstacles that may be injected during exploration.
    public let obstacles: [SimulatorObstacle]

    public init(
        appName: String, spotlightName: String, icon: String,
        rootScreenID: String,
        tabBarStyle: SimulatorTabBarStyle = .labels,
        screens: [String: SimulatorScreen],
        obstacles: [SimulatorObstacle]
    ) {
        self.appName = appName
        self.spotlightName = spotlightName
        self.icon = icon
        self.rootScreenID = rootScreenID
        self.tabBarStyle = tabBarStyle
        self.screens = screens
        self.obstacles = obstacles
    }

    /// Convenience: the root screen, or nil if `rootScreenID` is dangling.
    public var rootScreen: SimulatorScreen? { screens[rootScreenID] }
}

/// One screen in the simulator scene graph.
public struct SimulatorScreen: Sendable, Equatable {
    /// Unique ID used for navigation references (`leads_to`, `back`).
    public let id: String
    /// Header/title text drawn at the top of the screen.
    public let title: String
    /// ID of the screen reached by tapping the back chevron, or nil at root.
    public let backTo: String?
    /// Whether to render the bottom tab bar.
    public let hasTabBar: Bool
    /// All elements rendered on this screen, in declaration order.
    public let elements: [SimulatorElement]

    public init(
        id: String, title: String, backTo: String?,
        hasTabBar: Bool, elements: [SimulatorElement]
    ) {
        self.id = id
        self.title = title
        self.backTo = backTo
        self.hasTabBar = hasTabBar
        self.elements = elements
    }
}

/// One renderable, possibly tappable element on a screen.
public enum SimulatorElement: Sendable, Equatable {
    /// A list row with disclosure chevron. Tapping navigates to `leadsTo`.
    case row(text: String, leadsTo: String?)
    /// A pill button. Tapping navigates to `leadsTo` (or stays on the same screen if nil).
    case button(text: String, leadsTo: String?)
    /// Plain text, not interactive.
    case text(String)
    /// One tab in the bottom bar. Tapping switches to `leadsTo` screen.
    case tab(text: String, leadsTo: String)
    /// A keyboard-input text field. Tapping activates it; subsequent keystrokes
    /// accumulate. `fieldID` lets tests assert on per-field text.
    case textField(placeholder: String, fieldID: String)
    /// A horizontal drag slider. `fraction` is the initial 0.0–1.0 position.
    /// Drag updates view-side state; the spec value is the starting position.
    case slider(label: String, fraction: Double, fieldID: String)
    /// A gray rectangle placeholder for media (feed image / avatar). Width and
    /// height are in points relative to the rendered scene's coordinate system.
    case placeholder(width: Int, height: Int)
    /// A square board of equal tappable cells, each cell leading to the
    /// screen its transition names (see `SimulatorGrid`).
    case grid(SimulatorGrid)

    /// Display text for OCR + tap matching.
    public var displayText: String {
        switch self {
        case .row(let t, _), .button(let t, _), .text(let t),
             .tab(let t, _), .textField(let t, _), .slider(let t, _, _):
            return t
        case .placeholder, .grid: return ""
        }
    }

    /// Destination screen ID when this element is tapped, if any.
    public var leadsTo: String? {
        switch self {
        case .row(_, let to), .button(_, let to): return to
        case .tab(_, let to): return to
        case .text, .textField, .slider, .placeholder, .grid: return nil
        }
    }
}

/// A modal dialog that may interrupt exploration.
public struct SimulatorObstacle: Sendable, Equatable {
    /// Unique ID for tracking which obstacles have already fired.
    public let id: String
    /// Modal title text.
    public let title: String
    /// Optional body text rendered below the title.
    public let body: String?
    /// Buttons rendered at the bottom; tapping any of them dismisses the obstacle.
    public let buttons: [String]
    /// When this obstacle should fire.
    public let trigger: SimulatorObstacleTrigger

    public init(
        id: String, title: String, body: String?,
        buttons: [String], trigger: SimulatorObstacleTrigger
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.buttons = buttons
        self.trigger = trigger
    }
}

/// Conditions under which a `SimulatorObstacle` becomes visible.
public enum SimulatorObstacleTrigger: Sendable, Equatable {
    /// First time the screen is OCR-described after launch.
    case onFirstDescribe
    /// After the user has tapped `count` interactive elements.
    case afterTaps(count: Int)
    /// Never auto-fire (obstacle exists for documentation only).
    case never
}
