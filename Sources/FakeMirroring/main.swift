// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Fake macOS app that mimics the iPhone Mirroring window for integration testing.
// ABOUTME: Renders switchable scenario screens with header, rows, cards, and tab bar for OCR testing.

import AppKit
import HelperLib

/// View that renders an iOS-style screen for OCR testing.
/// Draws a large title, category rows, summary cards, and optionally a tab bar with icons.
/// The `appPack` (or active overlay) controls what content is displayed.
/// Handles all input types: tap, scroll, type, long press, drag, double tap.
final class FakeScreenView: NSView {

    /// When non-nil, scenes are driven by this pack's current screen / obstacle.
    /// When nil (and no overlay is active), the view renders an empty home frame.
    /// Set via AppRegistry on Spotlight launch or App Switcher dismissal.
    var appPack: AppPack? {
        didSet { resetInputState(); needsDisplay = true }
    }

    /// When non-nil, the Spotlight search overlay is active and intercepts all input.
    var spotlightOverlay: SpotlightOverlay? {
        didSet { needsDisplay = true }
    }

    /// When non-nil, the App Switcher overlay is active and intercepts all input.
    var appSwitcherOverlay: AppSwitcherOverlay? {
        didSet { needsDisplay = true }
    }

    /// Status bar time display.
    let statusBarLabel = ("9:41", CGPoint(x: 175, y: 30))

    /// Disclosure indicators for rows (simulating ">" chevrons).
    let chevronX: CGFloat = 370

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Tab bar layout constants.
    let tabBarHeight: CGFloat = 60
    let iconSize: CGFloat = 24
    let tabBarIconXPositions: [CGFloat] = [50, 130, 210, 290, 370]
    let tabBarLabels = ["Home", "Search", "Feed", "Chat", "Profile"]

    /// Row height and separator styling.
    let rowHeight: CGFloat = 44
    let separatorInset: CGFloat = 20

    // MARK: - Input State

    /// Vertical scroll offset for content (positive = scrolled down).
    var scrollOffset: CGFloat = 0

    /// Index of the active text field (Login scenario). -1 = none active.
    var activeFieldIndex: Int = -1

    /// Text typed into the active text field, keyed by field index.
    var typedText: [Int: String] = [:]

    /// Timestamp of mouseDown for long press detection.
    private var mouseDownTime: CFAbsoluteTime = 0

    /// Timestamp of last mouseUp for double-tap detection.
    private var lastMouseUpTime: CFAbsoluteTime = 0

    /// Position of mouseDown for drag tracking.
    private var mouseDownPoint: CGPoint = .zero

    /// Whether a drag is in progress.
    private var isDragging: Bool = false

    /// Whether mouseDown already handled the interaction (e.g., slider snap).
    private var mouseDownHandled: Bool = false

    /// Slider thumb fraction (0.0–1.0) for Profile scenario drag testing.
    var sliderFraction: CGFloat = 0.5

    /// Label shown temporarily on long press detection.
    var longPressLabel: String? = nil

    /// Label shown temporarily on double tap detection.
    var doubleTapLabel: String? = nil

    /// Long press detection threshold in seconds.
    let longPressThreshold: CFTimeInterval = 0.4

    /// Reset all mutable input state when scenario changes.
    private func resetInputState() {
        scrollOffset = 0
        activeFieldIndex = -1
        typedText = [:]
        mouseDownTime = 0
        lastMouseUpTime = 0
        mouseDownPoint = .zero
        isDragging = false
        mouseDownHandled = false
        sliderFraction = 0.5
        longPressLabel = nil
        doubleTapLabel = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0).setFill()
        dirtyRect.fill()

        let content = currentSceneData()

        // Status bar and tab bar are fixed (not scrolled)
        drawStatusBar()
        if content.hasTabBar { drawTabBar(style: content.tabBarStyle, labels: content.tabLabels) }

        // Scrollable content area
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -scrollOffset)

        if content.hasBackChevron { drawBackChevron() }
        drawHeader(content.header)
        drawPlaceholders(content.placeholders)
        drawCards(content.cards)
        drawRows(content.rows)
        drawPlainTexts(content.plainTexts)
        drawButtons(content.buttons)
        if let slider = content.sliderTrack { drawSlider(slider) }
        drawTypedTextOverlays(content)

        ctx.restoreGState()

        // Overlay labels (long press / double tap indicators) — drawn above everything
        drawOverlayLabels()
    }

    // MARK: - Hit Detection & Input Handlers

    override func mouseDown(with event: NSEvent) {
        mouseDownTime = CFAbsoluteTimeGetCurrent()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
        mouseDownHandled = false

        // Double tap detection in mouseDown: CGEvent synthetic double-clicks
        // set clickState on the second mouseDown before mouseUp fires.
        let clickState = event.cgEvent.map {
            $0.getIntegerValueField(.mouseEventClickState)
        } ?? 0
        if event.clickCount >= 2 || clickState >= 2 {
            handleDoubleTap(at: mouseDownPoint)
            mouseDownHandled = true
            return
        }

        // Snap slider to click position on mouseDown (immediate feedback for
        // both direct taps on the slider and drag start positions).
        let content = currentSceneData()
        if let slider = content.sliderTrack,
           slider.rect.insetBy(dx: -10, dy: -20).contains(mouseDownPoint) {
            let fraction = (mouseDownPoint.x - slider.rect.minX) / slider.rect.width
            sliderFraction = min(1.0, max(0.0, fraction))
            mouseDownHandled = true
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        isDragging = true
        let current = convert(event.locationInWindow, from: nil)
        let content = currentSceneData()

        // Handle slider drag on Profile scenario
        if let slider = content.sliderTrack {
            let trackRect = slider.rect
            if trackRect.contains(mouseDownPoint) || trackRect.insetBy(dx: -10, dy: -20).contains(current) {
                let fraction = (current.x - trackRect.minX) / trackRect.width
                sliderFraction = min(1.0, max(0.0, fraction))
                needsDisplay = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        // If mouseDown already handled this interaction (slider snap, double tap),
        // skip further processing in mouseUp.
        if mouseDownHandled {
            mouseDownHandled = false
            isDragging = false
            lastMouseUpTime = CFAbsoluteTimeGetCurrent()
            NSLog("[fakemirror-tap] mouseUp swallowed by mouseDownHandled flag")
            return
        }

        let clickPoint = convert(event.locationInWindow, from: nil)
        let holdDuration = CFAbsoluteTimeGetCurrent() - mouseDownTime
        NSLog(
            "[fakemirror-tap] mouseUp locationInWindow=(%.1f,%.1f) " +
            "clickPoint=(%.1f,%.1f) bounds=(%.0fx%.0f) holdDuration=%.3fs " +
            "isKey=%@ activeScene=%@",
            event.locationInWindow.x, event.locationInWindow.y,
            clickPoint.x, clickPoint.y,
            bounds.width, bounds.height,
            holdDuration,
            (window?.isKeyWindow ?? false) ? "yes" : "no",
            appPack?.spec.appName ?? (spotlightOverlay != nil ? "spotlight" :
                appSwitcherOverlay != nil ? "switcher" : "<home>")
        )

        // App Switcher overlay: a swipe up from a card force-quits the underlying
        // pack. Checked before drag and long-press handling: a swipe arrives as a
        // held drag, and those paths would swallow it.
        if let switcher = appSwitcherOverlay {
            let upwardDelta = mouseDownPoint.y - clickPoint.y
            if upwardDelta > 50, switcher.handleSwipeUp(at: mouseDownPoint) {
                needsDisplay = true
                return
            }
            // Tapping outside any card closes the overlay
            switcher.close()
            return
        }

        // If actual mouseDragged events were received, finalize slider and exit.
        // Only use isDragging (set by mouseDragged handler), NOT distance heuristics.
        // In CI, mouseDown coordinates from convert(event.locationInWindow) can be
        // unreliable for CGEvent-posted events, causing false positive drag detection.
        if isDragging {
            isDragging = false
            let content = currentSceneData()
            if let slider = content.sliderTrack, slider.rect.insetBy(dx: -10, dy: -20).contains(clickPoint) {
                let fraction = (clickPoint.x - slider.rect.minX) / slider.rect.width
                sliderFraction = min(1.0, max(0.0, fraction))
                needsDisplay = true
            }
            return
        }

        // Long press detection (held > threshold without drag)
        if holdDuration >= longPressThreshold {
            handleLongPress(at: clickPoint)
            return
        }

        // Double tap detection: AppKit clickCount, raw CGEvent clickState, or timing.
        // Synthetic CGEvent double-clicks may not propagate clickCount correctly in
        // all environments, so we also detect via rapid successive mouseUp events.
        let clickState = event.cgEvent.map {
            $0.getIntegerValueField(.mouseEventClickState)
        } ?? 0
        let timeSinceLastUp = CFAbsoluteTimeGetCurrent() - lastMouseUpTime
        let isDoubleTap = event.clickCount >= 2 || clickState >= 2 || timeSinceLastUp < 0.3
        lastMouseUpTime = CFAbsoluteTimeGetCurrent()
        if isDoubleTap {
            handleDoubleTap(at: clickPoint)
            return
        }

        // Adjust click point for scroll offset (content coordinates)
        let contentPoint = CGPoint(x: clickPoint.x, y: clickPoint.y + scrollOffset)

        // AppPack-driven path: resolve the tapped element via the active screen
        // (or active obstacle) and let the pack update its state. This fully
        // replaces the legacy ScenarioContent/NavigationMap flow when a pack
        // is foreground.
        if let pack = appPack {
            if handleAppPackTap(pack: pack, at: contentPoint, screenPoint: clickPoint) {
                return
            }
        }

        // Slider snap: check in mouseUp using reliable clickPoint coordinates.
        // The mouseDown slider check may fail in CI where convert(event.locationInWindow)
        // returns unreliable coordinates for CGEvent-posted mouseDown events.
        // currentSceneData() resolves either AppPack-driven or legacy scenario-driven
        // rendering, so slider/textField hit testing works in both modes.
        let content = currentSceneData()
        if let slider = content.sliderTrack,
           slider.rect.insetBy(dx: -10, dy: -20).contains(contentPoint) {
            let fraction = (contentPoint.x - slider.rect.minX) / slider.rect.width
            sliderFraction = min(1.0, max(0.0, fraction))
            needsDisplay = true
            return
        }

        // Check text field tap (Login scenario)
        for (idx, fieldRect) in content.textFieldRects.enumerated() {
            if fieldRect.contains(contentPoint) {
                activeFieldIndex = idx
                window?.makeFirstResponder(self)
                needsDisplay = true
                return
            }
        }

        // Tap outside text fields deactivates the active field
        activeFieldIndex = -1
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let content = currentSceneData()
        // Scroll wheel deltaY: positive = scroll content up (show content below)
        // NSEvent.scrollingDeltaY: positive = user scrolled down (trackpad finger moved down)
        // In a flipped view scrolling down should reveal content below, so we subtract
        let delta = event.scrollingDeltaY
        scrollOffset -= delta
        // Clamp: no negative scroll, and limit to the amount of content below fold
        let maxScroll = maxScrollOffset(for: content)
        scrollOffset = min(max(0, scrollOffset), maxScroll)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // Spotlight overlay swallows all keystrokes — type into the search,
        // press Return to commit, Esc to dismiss.
        if let spotlight = spotlightOverlay, let chars = event.characters {
            for char in chars {
                if char == "\u{7F}" {
                    if !spotlight.query.isEmpty {
                        spotlight.setQuery(String(spotlight.query.dropLast()))
                    }
                } else if char == "\r" || char == "\n" {
                    spotlight.commit()
                    return
                } else if char == "\u{1B}" {
                    spotlight.cancel()
                    return
                } else if !char.isNewline {
                    spotlight.setQuery(spotlight.query + String(char))
                }
            }
            needsDisplay = true
            return
        }

        guard activeFieldIndex >= 0, let chars = event.characters else {
            super.keyDown(with: event)
            return
        }
        for char in chars {
            if char == "\u{7F}" { // backspace
                if var text = typedText[activeFieldIndex], !text.isEmpty {
                    text.removeLast()
                    typedText[activeFieldIndex] = text
                }
            } else if char == "\r" || char == "\n" {
                // Return key: deactivate field
                activeFieldIndex = -1
            } else if !char.isNewline {
                typedText[activeFieldIndex, default: ""].append(char)
            }
        }
        needsDisplay = true
    }

    // MARK: - Input Helpers

    /// Maximum scroll offset based on content extent below the visible area.
    private func maxScrollOffset(for content: ScenarioData) -> CGFloat {
        let visibleHeight = bounds.height - (content.hasTabBar ? tabBarHeight : 0)
        var maxY: CGFloat = 0
        for (_, origin) in content.rows { maxY = max(maxY, origin.y + rowHeight) }
        for card in content.cards { maxY = max(maxY, card.rect.maxY) }
        for (_, origin) in content.plainTexts { maxY = max(maxY, origin.y + 20) }
        for (_, rect) in content.buttons { maxY = max(maxY, rect.maxY) }
        for rect in content.placeholders { maxY = max(maxY, rect.maxY) }
        if let slider = content.sliderTrack { maxY = max(maxY, slider.rect.maxY + 30) }
        let overflow = maxY - visibleHeight
        return max(0, overflow + 40) // 40pt padding
    }

    /// Handle long press: show "Context Menu" overlay at the press location.
    /// Tries to label the menu with the row/button text under the press by
    /// matching against the active scene's elements; falls back to a generic label.
    private func handleLongPress(at point: CGPoint) {
        let contentPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        let data = currentSceneData()
        var label: String?
        for (rowText, origin) in data.rows {
            let rect = CGRect(x: 0, y: origin.y - rowHeight / 2,
                              width: bounds.width, height: rowHeight)
            if rect.contains(contentPoint) { label = rowText; break }
        }
        if label == nil {
            for (buttonText, rect) in data.buttons where rect.contains(contentPoint) {
                label = buttonText; break
            }
        }
        longPressLabel = label.map { "Context Menu: \($0)" } ?? "Context Menu"
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.longPressLabel = nil
            self?.needsDisplay = true
        }
    }

    /// Handle double tap: show "Zoomed" overlay.
    private func handleDoubleTap(at point: CGPoint) {
        doubleTapLabel = "Zoomed"
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.doubleTapLabel = nil
            self?.needsDisplay = true
        }
    }

}

/// Window subclass that accepts mouse events even when not key.
/// Integration tests post CGEvents via postToPid while the user works
/// in another app; the default NSWindow drops mouse events when not key.
final class AlwaysAcceptingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        // When not key, NSWindow discards mouse events. Force-promote
        // ourselves to key before dispatch so the content view receives them.
        if !isKeyWindow, event.type == .leftMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

// Launch the app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
