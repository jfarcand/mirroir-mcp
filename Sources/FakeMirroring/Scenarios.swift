// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Scenario definitions for FakeMirroring's switchable screen content.
// ABOUTME: Each scenario provides layout data (header, rows, cards, buttons) for a different app screen.

import AppKit

/// Defines the available screen scenarios that FakeMirroring can display.
/// Each scenario renders a different combination of UI elements to exercise
/// various testing paths: assertions, fingerprinting, drift, tap, scroll, type, back nav.
enum FakeScenario: String, CaseIterable {
    case settings = "Settings"
    case settingsUpdated = "Settings (Updated)"
    case detail = "Detail"
    case empty = "Empty"
    case feed = "Feed"
    case profile = "Profile"
    case login = "Login"
    case detailWithBack = "Detail (Back)"
    case health = "Health"
}

/// A Health/Santé-style summary card with colored accent, title, value, and subtitle.
struct CardData {
    let title: String
    let value: String
    let subtitle: String
    let color: NSColor
    let rect: CGRect
}

/// Data describing what to render for a given scenario.
struct ScenarioData {
    let header: String
    /// Rows with ">" disclosure chevrons (settings-style list items).
    let rows: [(String, CGPoint)]
    let hasTabBar: Bool
    /// Free text labels without chevrons (captions, stats, links).
    var plainTexts: [(String, CGPoint)] = []
    /// Pill-shaped buttons with centered text.
    var buttons: [(String, CGRect)] = []
    /// Gray placeholder rectangles (simulating images in a feed).
    var placeholders: [CGRect] = []
    /// Whether to render a "<" back chevron in the top-left header zone.
    var hasBackChevron: Bool = false
    /// Health/Santé-style summary cards with accent color and stats.
    var cards: [CardData] = []
}

/// Scenario content definitions. Row positions follow the same layout grid
/// as the original settings screen for consistent OCR detection.
enum ScenarioContent {
    static func data(for scenario: FakeScenario) -> ScenarioData {
        switch scenario {
        case .settings:
            return ScenarioData(
                header: "Settings",
                rows: [
                    ("General", CGPoint(x: 100, y: 250)),
                    ("Display", CGPoint(x: 100, y: 310)),
                    ("Privacy", CGPoint(x: 100, y: 370)),
                    ("About", CGPoint(x: 100, y: 430)),
                    ("Software Update", CGPoint(x: 130, y: 490)),
                    ("Developer", CGPoint(x: 110, y: 550)),
                ],
                hasTabBar: true
            )
        case .settingsUpdated:
            return ScenarioData(
                header: "Settings",
                rows: [
                    ("Accessibility", CGPoint(x: 115, y: 250)),
                    ("Sounds", CGPoint(x: 100, y: 310)),
                    ("Wallpaper", CGPoint(x: 110, y: 370)),
                    ("Battery", CGPoint(x: 100, y: 430)),
                    ("Storage", CGPoint(x: 100, y: 490)),
                    ("Notifications", CGPoint(x: 115, y: 550)),
                ],
                hasTabBar: true
            )
        case .detail:
            return ScenarioData(
                header: "General",
                rows: [
                    ("About", CGPoint(x: 100, y: 250)),
                    ("Software Update", CGPoint(x: 130, y: 310)),
                    ("Storage", CGPoint(x: 100, y: 370)),
                    ("Background App Refresh", CGPoint(x: 155, y: 430)),
                    ("Date & Time", CGPoint(x: 115, y: 490)),
                    ("Keyboard", CGPoint(x: 110, y: 550)),
                ],
                hasTabBar: false
            )
        case .empty:
            return ScenarioData(header: "Empty", rows: [], hasTabBar: false)
        case .feed:
            return feedScenario()
        case .profile:
            return profileScenario()
        case .login:
            return loginScenario()
        case .detailWithBack:
            return detailWithBackScenario()
        case .health:
            return healthScenario()
        }
    }

    // MARK: - Rich Scenarios

    /// Instagram-like social feed with posts, action labels, and image placeholders.
    /// Exercises: scroll_to (dense content), tap (Like/Comment/Share), assert_visible.
    private static func feedScenario() -> ScenarioData {
        ScenarioData(
            header: "Home",
            rows: [],
            hasTabBar: true,
            plainTexts: [
                ("johndoe", CGPoint(x: 60, y: 185)),
                ("Like", CGPoint(x: 30, y: 395)),
                ("Comment", CGPoint(x: 120, y: 395)),
                ("Share", CGPoint(x: 240, y: 395)),
                ("Beautiful sunset at the beach", CGPoint(x: 20, y: 425)),
                ("janesmithphoto", CGPoint(x: 60, y: 475)),
                ("Like", CGPoint(x: 30, y: 685)),
                ("Comment", CGPoint(x: 120, y: 685)),
                ("Share", CGPoint(x: 240, y: 685)),
                ("Coffee and code", CGPoint(x: 20, y: 715)),
                ("traveler_adventures", CGPoint(x: 60, y: 765)),
            ],
            placeholders: [
                CGRect(x: 20, y: 210, width: 370, height: 175),
                CGRect(x: 20, y: 500, width: 370, height: 175),
                CGRect(x: 20, y: 790, width: 370, height: 80),
            ]
        )
    }

    /// Profile screen with stats, action buttons, and grid tabs.
    /// Exercises: tap (Follow/Message buttons, tab switching), assert_visible (stats).
    private static func profileScenario() -> ScenarioData {
        let btnW: CGFloat = 170, btnH: CGFloat = 36, btnY: CGFloat = 310
        return ScenarioData(
            header: "johndoe",
            rows: [],
            hasTabBar: true,
            plainTexts: [
                ("42", CGPoint(x: 55, y: 200)),
                ("Posts", CGPoint(x: 45, y: 225)),
                ("1.2K", CGPoint(x: 175, y: 200)),
                ("Followers", CGPoint(x: 155, y: 225)),
                ("890", CGPoint(x: 315, y: 200)),
                ("Following", CGPoint(x: 298, y: 225)),
                ("Photographer & traveler", CGPoint(x: 20, y: 270)),
                ("Posts", CGPoint(x: 55, y: 370)),
                ("Reels", CGPoint(x: 185, y: 370)),
                ("Tagged", CGPoint(x: 305, y: 370)),
            ],
            buttons: [
                ("Follow", CGRect(x: 20, y: btnY, width: btnW, height: btnH)),
                ("Message", CGRect(x: 200, y: btnY, width: btnW, height: btnH)),
            ],
            placeholders: [
                CGRect(x: 5, y: 400, width: 128, height: 128),
                CGRect(x: 138, y: 400, width: 128, height: 128),
                CGRect(x: 271, y: 400, width: 128, height: 128),
                CGRect(x: 5, y: 533, width: 128, height: 128),
                CGRect(x: 138, y: 533, width: 128, height: 128),
                CGRect(x: 271, y: 533, width: 128, height: 128),
            ]
        )
    }

    /// Login form with text field labels, buttons, and links.
    /// Exercises: type_text (field context), tap (Log In, links), assert_visible.
    private static func loginScenario() -> ScenarioData {
        let fW: CGFloat = 340, fH: CGFloat = 44, cx: CGFloat = 35
        return ScenarioData(
            header: "Welcome",
            rows: [],
            hasTabBar: false,
            plainTexts: [
                ("Sign in to continue", CGPoint(x: 120, y: 165)),
                ("Username", CGPoint(x: cx + 12, y: 260)),
                ("Password", CGPoint(x: cx + 12, y: 330)),
                ("Forgot password?", CGPoint(x: 140, y: 450)),
                ("Create Account", CGPoint(x: 150, y: 510)),
            ],
            buttons: [
                ("Log In", CGRect(x: cx, y: 390, width: fW, height: fH)),
            ],
            placeholders: [
                CGRect(x: cx, y: 250, width: fW, height: fH),
                CGRect(x: cx, y: 320, width: fW, height: fH),
            ]
        )
    }

    /// Detail view with a "<" back chevron for testing OCR-based back navigation.
    /// Exercises: tap (back chevron), assert_visible (info rows).
    private static func detailWithBackScenario() -> ScenarioData {
        ScenarioData(
            header: "About",
            rows: [
                ("Name", CGPoint(x: 100, y: 250)),
                ("Model Name", CGPoint(x: 112, y: 310)),
                ("Software Version", CGPoint(x: 130, y: 370)),
                ("Serial Number", CGPoint(x: 125, y: 430)),
                ("Capacity", CGPoint(x: 105, y: 490)),
                ("Available", CGPoint(x: 105, y: 550)),
            ],
            hasTabBar: false,
            hasBackChevron: true
        )
    }

    /// Returns the hit regions for a scenario, mapping tappable rects to their labels.
    /// Used by FakeScreenView's mouseUp to determine which element was clicked.
    static func hitRegions(for scenario: FakeScenario) -> [(label: String, rect: CGRect)] {
        let content = data(for: scenario)
        let rowHeight: CGFloat = 44
        let viewWidth: CGFloat = 410
        var regions: [(String, CGRect)] = []

        // Back chevron
        if content.hasBackChevron {
            regions.append(("<", CGRect(x: 0, y: 70, width: 60, height: 40)))
        }

        // Rows — full-width tappable band
        for (text, origin) in content.rows {
            regions.append((text, CGRect(x: 0, y: origin.y - 5, width: viewWidth, height: rowHeight)))
        }

        // Buttons — their exact CGRects
        for (title, rect) in content.buttons {
            regions.append((title, rect))
        }

        // Cards — their exact CGRects
        for card in content.cards {
            regions.append((card.title, card.rect))
        }

        // Tab bar labels — 60pt wide band around each label position
        if content.hasTabBar {
            let tabBarY: CGFloat = 898 - 60
            let tabBarLabels = ["Home", "Search", "Feed", "Chat", "Profile"]
            let tabBarXPositions: [CGFloat] = [50, 130, 210, 290, 370]
            for (idx, label) in tabBarLabels.enumerated() {
                let cx = tabBarXPositions[idx]
                regions.append((label, CGRect(x: cx - 30, y: tabBarY, width: 60, height: 60)))
            }
        }

        return regions
    }

    /// Health/Santé-style dashboard with colored summary cards.
    /// Exercises: scroll_to (cards extend below fold), tap (card drill-down),
    /// assert_visible (stats values), fingerprinting (dense structured text).
    private static func healthScenario() -> ScenarioData {
        let cardW: CGFloat = 378, cardH: CGFloat = 110
        let cardX: CGFloat = 16, gap: CGFloat = 12, startY: CGFloat = 180
        func cardRect(_ i: Int) -> CGRect {
            CGRect(x: cardX, y: startY + CGFloat(i) * (cardH + gap), width: cardW, height: cardH)
        }
        return ScenarioData(
            header: "Summary",
            rows: [],
            hasTabBar: true,
            cards: [
                CardData(title: "Steps", value: "8,432", subtitle: "Daily Average",
                         color: .systemRed, rect: cardRect(0)),
                CardData(title: "Heart Rate", value: "72 BPM", subtitle: "Resting",
                         color: .systemPink, rect: cardRect(1)),
                CardData(title: "Sleep", value: "7h 23min", subtitle: "Time in Bed",
                         color: .systemIndigo, rect: cardRect(2)),
                CardData(title: "Exercise Minutes", value: "32 min", subtitle: "Move Goal",
                         color: .systemGreen, rect: cardRect(3)),
                CardData(title: "Respiratory Rate", value: "15 brpm", subtitle: "Average",
                         color: .systemTeal, rect: cardRect(4)),
                CardData(title: "Mindful Minutes", value: "12 min", subtitle: "Weekly Total",
                         color: .systemOrange, rect: cardRect(5)),
            ]
        )
    }
}

/// Maps (currentScenario, tappedLabel) → target scenario for interactive navigation.
/// Defines which taps cause screen transitions in FakeMirroring, enabling
/// integration tests to validate full tap → navigation → verify flows.
enum NavigationMap {

    /// Returns the target scenario when a user taps the given label on the current scenario.
    /// Returns nil if the tap does not trigger a navigation (e.g., tapping a non-interactive element).
    static func destination(from scenario: FakeScenario, tapping label: String) -> FakeScenario? {
        switch scenario {
        case .settings:
            switch label {
            case "General": return .detail
            case "About": return .detailWithBack
            case "Display", "Privacy": return .detail
            case "Profile": return .profile            // tab bar
            default: return nil
            }
        case .settingsUpdated:
            switch label {
            case "Accessibility", "Sounds", "Wallpaper": return .detail
            default: return nil
            }
        case .detail:
            switch label {
            case "<": return .settings                  // back chevron
            case "Home": return .feed                   // tab bar
            default: return nil
            }
        case .detailWithBack:
            switch label {
            case "<": return .settings                  // back chevron
            default: return nil
            }
        case .feed:
            switch label {
            case "Profile": return .profile             // tab bar
            case "Home": return .feed
            default: return nil
            }
        case .profile:
            switch label {
            case "Home": return .feed                   // tab bar
            case "Follow": return .profile              // stays on same screen
            default: return nil
            }
        case .login:
            switch label {
            case "Log In": return .feed
            default: return nil
            }
        case .health:
            switch label {
            case "Steps", "Heart Rate", "Sleep": return .detailWithBack
            default: return nil
            }
        case .empty:
            return nil
        }
    }
}
