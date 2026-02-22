// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Fake macOS app that mimics the iPhone Mirroring window for integration testing.
// ABOUTME: Renders text labels on a dark background for OCR validation without a real iPhone.

import AppKit

/// View that renders iOS-style text labels on a dark background for OCR testing.
/// Draws white text at 16pt+ for reliable Vision OCR detection.
final class FakeScreenView: NSView {
    private let labels: [(String, CGPoint)] = [
        ("9:41", CGPoint(x: 175, y: 30)),
        ("Settings", CGPoint(x: 60, y: 300)),
        ("Safari", CGPoint(x: 160, y: 300)),
        ("Photos", CGPoint(x: 260, y: 300)),
        ("Camera", CGPoint(x: 360, y: 300)),
        ("Messages", CGPoint(x: 60, y: 500)),
        ("Mail", CGPoint(x: 160, y: 500)),
        ("Clock", CGPoint(x: 260, y: 500)),
        ("Maps", CGPoint(x: 360, y: 500)),
    ]

    override var isFlipped: Bool { true }

    /// Tab bar icon positions (x-center) and sizes — 5 evenly spaced icons
    /// on a white bar at the bottom, simulating an iOS tab bar for icon detection testing.
    private let tabBarHeight: CGFloat = 50
    private let iconSize: CGFloat = 24
    private let tabBarIconXPositions: [CGFloat] = [50, 130, 210, 290, 370]

    override func draw(_ dirtyRect: NSRect) {
        // Dark background for high OCR contrast
        NSColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0).setFill()
        dirtyRect.fill()

        // Draw text labels
        let font = NSFont.systemFont(ofSize: 18, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]

        for (text, origin) in labels {
            let size = (text as NSString).size(withAttributes: attributes)
            let centeredX = origin.x - size.width / 2
            (text as NSString).draw(at: NSPoint(x: centeredX, y: origin.y), withAttributes: attributes)
        }

        // Draw white tab bar background at the bottom
        let barY = bounds.height - tabBarHeight
        NSColor.white.setFill()
        NSRect(x: 0, y: barY, width: bounds.width, height: tabBarHeight).fill()

        // Draw dark icon shapes (simple filled rectangles) on the tab bar
        NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0).setFill()
        let iconY = barY + (tabBarHeight - iconSize) / 2
        for iconX in tabBarIconXPositions {
            let rect = NSRect(
                x: iconX - iconSize / 2,
                y: iconY,
                width: iconSize,
                height: iconSize
            )
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
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

    /// Build a View menu with navigation items for AX menu traversal tests.
    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // App menu (required by macOS)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit FakeMirroring", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // View menu with navigation items
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Home Screen", action: #selector(noOp(_:)), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: "Spotlight", action: #selector(noOp(_:)), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: "App Switcher", action: #selector(noOp(_:)), keyEquivalent: ""))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func noOp(_ sender: Any?) {
        // Menu items exist for AX traversal testing; no action needed.
    }
}

// Launch the app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
