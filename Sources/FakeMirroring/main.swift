// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Fake macOS app that mimics the iPhone Mirroring window for integration testing.
// ABOUTME: Renders switchable scenario screens with header, rows, cards, and tab bar for OCR testing.

import AppKit

/// View that renders an iOS-style screen for OCR testing.
/// Draws a large title, category rows, summary cards, and optionally a tab bar with icons.
/// The `scenario` property controls which content is displayed.
final class FakeScreenView: NSView {

    /// The active scenario controlling what content is rendered.
    var scenario: FakeScenario = .settings {
        didSet { needsDisplay = true }
    }

    /// Status bar time display.
    private let statusBarLabel = ("9:41", CGPoint(x: 175, y: 30))

    /// Disclosure indicators for rows (simulating ">" chevrons).
    private let chevronX: CGFloat = 370

    override var isFlipped: Bool { true }

    /// Tab bar layout constants.
    private let tabBarHeight: CGFloat = 60
    private let iconSize: CGFloat = 24
    private let tabBarIconXPositions: [CGFloat] = [50, 130, 210, 290, 370]
    private let tabBarLabels = ["Home", "Search", "Feed", "Chat", "Profile"]

    /// Row height and separator styling.
    private let rowHeight: CGFloat = 44
    private let separatorInset: CGFloat = 20

    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0).setFill()
        dirtyRect.fill()

        let content = ScenarioContent.data(for: scenario)

        drawStatusBar()
        if content.hasBackChevron { drawBackChevron() }
        drawHeader(content.header)
        drawPlaceholders(content.placeholders)
        drawCards(content.cards)
        drawRows(content.rows)
        drawPlainTexts(content.plainTexts)
        drawButtons(content.buttons)
        if content.hasTabBar { drawTabBar() }
    }

    // MARK: - Hit Detection

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // NSView flipped coordinate: convert from bottom-left to top-left origin
        let flippedY = bounds.height - point.y
        let clickPoint = CGPoint(x: point.x, y: flippedY)

        let regions = ScenarioContent.hitRegions(for: scenario)
        for (label, rect) in regions {
            if rect.contains(clickPoint) {
                if let target = NavigationMap.destination(from: scenario, tapping: label) {
                    scenario = target
                }
                return
            }
        }
    }

    // MARK: - Drawing Primitives

    private func drawStatusBar() {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let (text, origin) = statusBarLabel
        let size = (text as NSString).size(withAttributes: attrs)
        let centeredX = origin.x - size.width / 2
        (text as NSString).draw(at: NSPoint(x: centeredX, y: origin.y), withAttributes: attrs)
    }

    private func drawBackChevron() {
        let font = NSFont.systemFont(ofSize: 22, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.systemBlue,
        ]
        ("<" as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: attrs)
    }

    private func drawHeader(_ headerText: String) {
        let font = NSFont.systemFont(ofSize: 28, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        (headerText as NSString).draw(at: NSPoint(x: 100, y: 120), withAttributes: attrs)
    }

    private func drawRows(_ rowLabels: [(String, CGPoint)]) {
        let rowFont = NSFont.systemFont(ofSize: 18, weight: .regular)
        let rowAttrs: [NSAttributedString.Key: Any] = [
            .font: rowFont, .foregroundColor: NSColor.white,
        ]
        let chevronFont = NSFont.systemFont(ofSize: 18, weight: .regular)
        let chevronAttrs: [NSAttributedString.Key: Any] = [
            .font: chevronFont, .foregroundColor: NSColor(white: 0.5, alpha: 1.0),
        ]

        for (text, origin) in rowLabels {
            (text as NSString).draw(at: NSPoint(x: origin.x, y: origin.y), withAttributes: rowAttrs)
            (">" as NSString).draw(
                at: NSPoint(x: chevronX, y: origin.y), withAttributes: chevronAttrs)
            let separatorY = origin.y + rowHeight
            NSColor(white: 0.3, alpha: 1.0).setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: separatorInset, y: separatorY))
            path.line(to: NSPoint(x: bounds.width - separatorInset, y: separatorY))
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private func drawPlainTexts(_ texts: [(String, CGPoint)]) {
        let font = NSFont.systemFont(ofSize: 15, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        for (text, origin) in texts {
            (text as NSString).draw(at: NSPoint(x: origin.x, y: origin.y), withAttributes: attrs)
        }
    }

    private func drawButtons(_ buttons: [(String, CGRect)]) {
        let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        for (title, rect) in buttons {
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let size = (title as NSString).size(withAttributes: attrs)
            let textX = rect.origin.x + (rect.width - size.width) / 2
            let textY = rect.origin.y + (rect.height - size.height) / 2
            (title as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
        }
    }

    private func drawPlaceholders(_ rects: [CGRect]) {
        NSColor(white: 0.25, alpha: 1.0).setFill()
        for rect in rects {
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
    }

    private func drawCards(_ cards: [CardData]) {
        guard !cards.isEmpty else { return }
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let valueFont = NSFont.systemFont(ofSize: 28, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let subColor = NSColor(white: 0.6, alpha: 1.0)
        for card in cards {
            // Card background
            NSColor(white: 0.18, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: card.rect, xRadius: 12, yRadius: 12).fill()
            // Colored accent strip on left edge
            card.color.setFill()
            let strip = NSRect(x: card.rect.minX, y: card.rect.minY,
                               width: 4, height: card.rect.height)
            NSBezierPath(roundedRect: strip, xRadius: 2, yRadius: 2).fill()
            // Text content
            let x = card.rect.minX + 16
            (card.title as NSString).draw(at: NSPoint(x: x, y: card.rect.minY + 12),
                withAttributes: [.font: titleFont, .foregroundColor: card.color])
            (card.value as NSString).draw(at: NSPoint(x: x, y: card.rect.minY + 36),
                withAttributes: [.font: valueFont, .foregroundColor: NSColor.white])
            (card.subtitle as NSString).draw(at: NSPoint(x: x, y: card.rect.minY + 78),
                withAttributes: [.font: subFont, .foregroundColor: subColor])
        }
    }

    private func drawTabBar() {
        let barY = bounds.height - tabBarHeight
        NSColor.white.setFill()
        NSRect(x: 0, y: barY, width: bounds.width, height: tabBarHeight).fill()

        let iconColor = NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        iconColor.setFill()
        let iconY = barY + 6
        for iconX in tabBarIconXPositions {
            let rect = NSRect(
                x: iconX - iconSize / 2, y: iconY,
                width: iconSize, height: iconSize
            )
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }

        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: iconColor,
        ]
        let labelY = iconY + iconSize + 4
        for (idx, label) in tabBarLabels.enumerated() {
            let size = (label as NSString).size(withAttributes: labelAttrs)
            let x = tabBarIconXPositions[idx] - size.width / 2
            (label as NSString).draw(at: NSPoint(x: x, y: labelY), withAttributes: labelAttrs)
        }
    }
}

/// Application delegate that creates the main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowWidth: CGFloat = 410
        let windowHeight: CGFloat = 898

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FakeMirroring"
        window.contentView = FakeScreenView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        window.makeKeyAndOrderFront(nil)
        self.window = window

        buildMenuBar()
    }

    /// Build menus: View menu for AX traversal tests, Scenario menu for content switching.
    private func buildMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit FakeMirroring", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Home Screen", action: #selector(noOp(_:)), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: "Spotlight", action: #selector(noOp(_:)), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: "App Switcher", action: #selector(noOp(_:)), keyEquivalent: ""))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let scenarioMenuItem = NSMenuItem()
        let scenarioMenu = NSMenu(title: "Scenario")
        for scenario in FakeScenario.allCases {
            let item = NSMenuItem(
                title: scenario.rawValue,
                action: #selector(switchScenario(_:)),
                keyEquivalent: ""
            )
            item.representedObject = scenario.rawValue
            scenarioMenu.addItem(item)
        }
        scenarioMenuItem.submenu = scenarioMenu
        mainMenu.addItem(scenarioMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func noOp(_ sender: Any?) {
        // Menu items exist for AX traversal testing; no action needed.
    }

    @objc func switchScenario(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let scenario = FakeScenario(rawValue: rawValue),
              let view = window?.contentView as? FakeScreenView else { return }
        view.scenario = scenario
    }
}

// Launch the app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
