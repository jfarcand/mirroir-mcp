// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Converts a SimulatorScreen + active obstacle into the ScenarioData FakeScreenView already knows how to draw.
// ABOUTME: Bridges the new declarative scene graph to the existing AppKit rendering pipeline without rewriting the renderer.

import AppKit
import HelperLib

/// Pure transformation: SimulatorScreen → ScenarioData.
/// Layout coordinates follow the same conventions as Scenarios.swift so OCR
/// behavior on simulated apps matches existing test expectations.
enum SceneRenderer {

    private static let firstRowY: CGFloat = 250
    private static let rowSpacing: CGFloat = 60
    private static let rowX: CGFloat = 100
    private static let textPadding: CGFloat = 20
    private static let textStartY: CGFloat = 250
    private static let textSpacing: CGFloat = 36
    // 500pt keeps buttons inside the visible region on small CI displays
    // (macos-15 headless runners clip the lower window — clicks past screen
    // y~600 land at wrong positions). Login and obstacle dialogs both rely
    // on this constant, so a single low value covers both.
    private static let buttonY: CGFloat = 500
    private static let buttonWidth: CGFloat = 160
    private static let buttonHeight: CGFloat = 36
    private static let buttonGap: CGFloat = 20

    /// Build the ScenarioData for a screen (no active obstacle).
    /// `tabBarStyle` comes from the owning pack's spec — it is app-level,
    /// not per-screen, so the caller passes it alongside the screen.
    static func render(
        _ screen: SimulatorScreen,
        tabBarStyle: SimulatorTabBarStyle = .labels
    ) -> ScenarioData {
        var rows: [(String, CGPoint)] = []
        var plainTexts: [(String, CGPoint)] = []
        var buttons: [(String, CGRect)] = []
        var tabLabels: [String] = []
        var placeholders: [CGRect] = []
        var textFieldRects: [CGRect] = []
        var sliderTrack: (label: String, rect: CGRect)?

        var rowY = firstRowY
        var textY = textStartY
        var buttonX = textPadding
        var placeholderY: CGFloat = textStartY
        var textFieldY: CGFloat = textStartY

        for element in screen.elements {
            switch element {
            case .row(let text, _):
                rows.append((text, CGPoint(x: rowX, y: rowY)))
                rowY += rowSpacing
            case .text(let text):
                plainTexts.append((text, CGPoint(x: textPadding, y: textY)))
                textY += textSpacing
            case .button(let text, _):
                buttons.append((
                    text,
                    CGRect(x: buttonX, y: buttonY,
                           width: buttonWidth, height: buttonHeight)
                ))
                buttonX += buttonWidth + buttonGap
            case .tab(let text, _):
                // Tabs render in the FakeScreenView tab bar, one column each;
                // hasTabBar drives bar visibility.
                tabLabels.append(text)
            case .textField(let placeholder, _):
                let rect = CGRect(
                    x: textPadding, y: textFieldY, width: 370, height: 36)
                textFieldRects.append(rect)
                // Echo the placeholder as plain text so OCR detection works
                // against the same string developers see.
                plainTexts.append((placeholder,
                    CGPoint(x: textPadding + 8, y: textFieldY + 12)))
                textFieldY += 50
            case .slider(let label, let fraction, _):
                let trackRect = CGRect(x: 40, y: 700, width: 330, height: 30)
                sliderTrack = (label, trackRect)
                plainTexts.append((label,
                    CGPoint(x: trackRect.minX, y: trackRect.minY - 25)))
                _ = fraction  // initial fraction is set on the view side
            case .placeholder(let w, let h):
                let rect = CGRect(
                    x: textPadding, y: placeholderY,
                    width: CGFloat(w), height: CGFloat(h))
                placeholders.append(rect)
                placeholderY += CGFloat(h) + 10
            }
        }

        return ScenarioData(
            header: screen.title,
            rows: rows,
            hasTabBar: screen.hasTabBar,
            tabBarStyle: tabBarStyle,
            tabLabels: tabLabels,
            plainTexts: plainTexts,
            buttons: buttons,
            placeholders: placeholders,
            hasBackChevron: screen.backTo != nil,
            cards: [],
            sliderTrack: sliderTrack,
            textFieldRects: textFieldRects
        )
    }

    /// Build ScenarioData for an obstacle modal — title + body text + buttons,
    /// rendered above the host screen by FakeScreenView's existing pipeline.
    /// We render the obstacle's content as the *entire* scene; the underlying
    /// screen is hidden while the obstacle is active (matches typical iOS
    /// permission/dialog modals).
    static func render(_ obstacle: SimulatorObstacle) -> ScenarioData {
        var plainTexts: [(String, CGPoint)] = []
        plainTexts.append((obstacle.title, CGPoint(x: textPadding, y: 200)))
        if let body = obstacle.body {
            plainTexts.append((body, CGPoint(x: textPadding, y: 250)))
        }

        var buttons: [(String, CGRect)] = []
        let count = max(1, obstacle.buttons.count)
        let totalGap = buttonGap * CGFloat(count - 1)
        let availableWidth: CGFloat = 410 - 2 * textPadding
        let perButtonWidth = (availableWidth - totalGap) / CGFloat(count)
        for (idx, label) in obstacle.buttons.enumerated() {
            let x = textPadding + CGFloat(idx) * (perButtonWidth + buttonGap)
            buttons.append((
                label,
                CGRect(x: x, y: buttonY, width: perButtonWidth, height: buttonHeight)
            ))
        }

        return ScenarioData(
            header: "",
            rows: [],
            hasTabBar: false,
            plainTexts: plainTexts,
            buttons: buttons,
            placeholders: [],
            hasBackChevron: false,
            cards: [],
            sliderTrack: nil,
            textFieldRects: []
        )
    }
}
