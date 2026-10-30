// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: App Switcher overlay: an iOS-like carousel of running AppPacks, each card a snapshot of its screen.
// ABOUTME: A swipe-up gesture on a card invokes registry.forceQuit so reset_before_explore exercises real reset.

import AppKit
import HelperLib

/// State for an active App Switcher overlay.
/// Cards sit side by side; each shows its app's name above a snapshot of its
/// screen and supports a swipe-up gesture that force-quits the underlying pack.
@MainActor
final class AppSwitcherOverlay {
    private let registry: AppRegistry
    /// Called when the user dismisses the overlay (swiped down off-screen, or
    /// closed via menu). FakeScreenView clears its `appSwitcherOverlay`.
    let onClose: () -> Void

    /// Card rectangles keyed by pack appName, computed lazily by sceneData().
    /// Used by FakeScreenView's hit handler to map a swipe-up to a force-quit.
    private(set) var cardRects: [(packName: String, rect: CGRect)] = []

    init(registry: AppRegistry, onClose: @escaping () -> Void) {
        self.registry = registry
        self.onClose = onClose
    }

    /// Force-quit the pack underneath the swipe. Returns true if a card was hit.
    func handleSwipeUp(at point: CGPoint) -> Bool {
        for (name, rect) in cardRects where rect.contains(point) {
            if let pack = registry.packs[name.lowercased()] {
                registry.forceQuit(pack)
            }
            return true
        }
        return false
    }

    func close() { onClose() }

    /// Card geometry of the carousel, in scene points. Like iOS, cards sit side
    /// by side with the app that was in front as the rightmost card and older
    /// apps to its left, sliding off the left edge. Each card spans the band
    /// reset_app drags from (`appSwitcherCardYFraction` of the window height).
    private static let cardWidth: CGFloat = 150
    private static let cardStep: CGFloat = 165
    private static let rightmostCardX: CGFloat = 245
    private static let cardTop: CGFloat = 150
    private static let cardHeight: CGFloat = 650
    /// The app's name sits above its card, inside the label band
    /// `AppSwitcherCardLocator.labelBandContains` reads.
    private static let labelY: CGFloat = 110
    /// A card shows a snapshot of its app's screen: its first lines, cut to
    /// what fits the card width.
    private static let snapshotLines = 8
    private static let snapshotLineChars = 16
    private static let snapshotLineSpacing: CGFloat = 35

    /// Render the running app cards as ScenarioData.
    func sceneData() -> ScenarioData {
        var plainTexts: [(String, CGPoint)] = []
        var placeholders: [CGRect] = []
        cardRects = []

        let front = registry.foregroundPack?.spec.appName
        let ordered = registry.runningPackIDs.filter { $0 != front } + (front.map { [$0] } ?? [])
        for (offset, name) in ordered.reversed().enumerated() {
            guard let pack = registry.packs[name.lowercased()] else { continue }
            let cardX = Self.rightmostCardX - CGFloat(offset) * Self.cardStep
            let rect = CGRect(x: cardX, y: Self.cardTop, width: Self.cardWidth, height: Self.cardHeight)
            placeholders.append(rect)
            plainTexts.append((pack.spec.appName, CGPoint(x: cardX + 10, y: Self.labelY)))
            for (line, text) in Self.snapshot(of: pack).enumerated() {
                let y = Self.cardTop + 20 + CGFloat(line) * Self.snapshotLineSpacing
                plainTexts.append((text, CGPoint(x: cardX + 10, y: y)))
            }
            cardRects.append((name, rect))
        }
        if registry.runningPackIDs.isEmpty {
            plainTexts.append(("No running apps", CGPoint(x: 100, y: 400)))
        }
        return ScenarioData(
            header: "",
            rows: [],
            hasTabBar: false,
            plainTexts: plainTexts,
            buttons: [],
            placeholders: placeholders,
            hasBackChevron: false,
            cards: [],
            sliderTrack: nil,
            textFieldRects: []
        )
    }

    /// The lines a card previews: the pack's current screen (or its obstacle)
    /// as rendered in the foreground — header, then rows, texts and buttons.
    private static func snapshot(of pack: AppPack) -> [String] {
        let scene: ScenarioData
        if let obstacle = pack.activeObstacle {
            scene = SceneRenderer.render(obstacle)
        } else if let screen = pack.currentScreen {
            scene = SceneRenderer.render(screen, tabBarStyle: pack.spec.tabBarStyle)
        } else {
            return []
        }
        let lines = [scene.header] + scene.rows.map(\.0) + scene.plainTexts.map(\.0)
            + scene.buttons.map(\.0)
        return lines.filter { !$0.isEmpty }.prefix(snapshotLines)
            .map { String($0.prefix(snapshotLineChars)) }
    }
}
