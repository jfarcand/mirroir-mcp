// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Drawing primitives for FakeScreenView (status bar, rows, cards, slider, overlays).
// ABOUTME: Extracted from main.swift to keep file sizes under the 500-line limit.

import AppKit

/// Drawing methods for FakeScreenView. Separated from the main class to keep
/// file sizes manageable while keeping all rendering logic in one place.
extension FakeScreenView {

    func drawStatusBar() {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let (text, origin) = statusBarLabel
        let size = (text as NSString).size(withAttributes: attrs)
        let centeredX = origin.x - size.width / 2
        (text as NSString).draw(at: NSPoint(x: centeredX, y: origin.y), withAttributes: attrs)
    }

    func drawBackChevron() {
        let font = NSFont.systemFont(ofSize: 22, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.systemBlue,
        ]
        ("<" as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: attrs)
    }

    func drawHeader(_ headerText: String) {
        let font = NSFont.systemFont(ofSize: 28, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        (headerText as NSString).draw(at: NSPoint(x: 100, y: 120), withAttributes: attrs)
    }

    func drawRows(_ rowLabels: [(String, CGPoint)]) {
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

    func drawPlainTexts(_ texts: [(String, CGPoint)]) {
        let font = NSFont.systemFont(ofSize: 15, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        for (text, origin) in texts {
            (text as NSString).draw(at: NSPoint(x: origin.x, y: origin.y), withAttributes: attrs)
        }
    }

    func drawButtons(_ buttons: [(String, CGRect)]) {
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

    func drawPlaceholders(_ rects: [CGRect]) {
        NSColor(white: 0.25, alpha: 1.0).setFill()
        for rect in rects {
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
    }

    func drawCards(_ cards: [CardData]) {
        guard !cards.isEmpty else { return }
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let valueFont = NSFont.systemFont(ofSize: 28, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let subColor = NSColor(white: 0.6, alpha: 1.0)
        for card in cards {
            NSColor(white: 0.18, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: card.rect, xRadius: 12, yRadius: 12).fill()
            card.color.setFill()
            let strip = NSRect(x: card.rect.minX, y: card.rect.minY,
                               width: 4, height: card.rect.height)
            NSBezierPath(roundedRect: strip, xRadius: 2, yRadius: 2).fill()
            let x = card.rect.minX + 16
            (card.title as NSString).draw(at: NSPoint(x: x, y: card.rect.minY + 12),
                withAttributes: [.font: titleFont, .foregroundColor: card.color])
            (card.value as NSString).draw(at: NSPoint(x: x, y: card.rect.minY + 36),
                withAttributes: [.font: valueFont, .foregroundColor: NSColor.white])
            (card.subtitle as NSString).draw(at: NSPoint(x: x, y: card.rect.minY + 78),
                withAttributes: [.font: subFont, .foregroundColor: subColor])
        }
    }

    func drawSlider(_ slider: (label: String, rect: CGRect)) {
        let rect = slider.rect
        // Track background
        NSColor(white: 0.3, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        // Filled portion
        let filledWidth = rect.width * sliderFraction
        let filledRect = CGRect(x: rect.minX, y: rect.minY, width: filledWidth, height: rect.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: filledRect, xRadius: 4, yRadius: 4).fill()
        // Thumb circle
        let thumbX = rect.minX + filledWidth - 12
        let thumbRect = CGRect(x: thumbX, y: rect.minY - 3, width: 24, height: rect.height + 6)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: thumbRect).fill()
        // Percentage label
        let pct = Int(sliderFraction * 100)
        let labelFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: NSColor.white,
        ]
        let pctText = "\(pct)%"
        (pctText as NSString).draw(at: NSPoint(x: rect.maxX + 8, y: rect.minY + 5), withAttributes: labelAttrs)
    }

    func drawTypedTextOverlays(_ content: ScenarioData) {
        guard !content.textFieldRects.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 16, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        for (idx, fieldRect) in content.textFieldRects.enumerated() {
            if let text = typedText[idx], !text.isEmpty {
                // Cover the placeholder text before drawing typed text.
                // Without this, OCR merges the typed text with the placeholder
                // label underneath (e.g., "hello" + "Username" → "bieloname").
                NSColor(white: 0.25, alpha: 1.0).setFill()
                NSBezierPath(roundedRect: fieldRect, xRadius: 6, yRadius: 6).fill()
                (text as NSString).draw(at: NSPoint(x: fieldRect.minX + 12, y: fieldRect.minY + 10),
                                        withAttributes: textAttrs)
            }
            // Active field indicator (blue border, high contrast for OCR)
            if idx == activeFieldIndex {
                NSColor.systemBlue.setStroke()
                let borderPath = NSBezierPath(roundedRect: fieldRect, xRadius: 6, yRadius: 6)
                borderPath.lineWidth = 2
                borderPath.stroke()
            }
        }
    }

    func drawOverlayLabels() {
        let overlayFont = NSFont.systemFont(ofSize: 20, weight: .bold)
        let overlayAttrs: [NSAttributedString.Key: Any] = [
            .font: overlayFont,
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor(red: 0, green: 0, blue: 0, alpha: 0.7),
        ]
        if let label = longPressLabel {
            let size = (label as NSString).size(withAttributes: overlayAttrs)
            let x = (bounds.width - size.width) / 2
            (label as NSString).draw(at: NSPoint(x: x, y: bounds.height / 2), withAttributes: overlayAttrs)
        }
        if let label = doubleTapLabel {
            let size = (label as NSString).size(withAttributes: overlayAttrs)
            let x = (bounds.width - size.width) / 2
            (label as NSString).draw(at: NSPoint(x: x, y: bounds.height / 2 + 40), withAttributes: overlayAttrs)
        }
    }

    func drawTabBar() {
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
