// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects navigation patterns in OCR results and generates keyboard shortcut hints.
// ABOUTME: Solves the iPhone Mirroring limitation where nav bar back button taps are unreliable.

/// Analyzes OCR-detected elements for navigation patterns and generates
/// actionable hints suggesting reliable keyboard shortcuts.
///
/// iPhone Mirroring has a known limitation where tapping UINavigationBar
/// back buttons (`<`) is unreliable — the HID events arrive but the nav
/// bar doesn't respond. Keyboard shortcuts like `Cmd+[` bypass this
/// limitation entirely.
public enum NavigationHintDetector {
    /// Fraction of window height that defines the top navigation zone.
    /// Elements in the top 15% are considered nav bar candidates.
    static let topZoneFraction = 0.15
    /// Fraction of window height that defines the bottom toolbar zone.
    /// Elements in the bottom 15% are considered toolbar candidates.
    static let bottomZoneFraction = 0.85
    /// Text patterns that indicate a back button.
    static let backChevronPatterns: Set<String> = ["<", "‹", "〈"]

    /// Detect navigation patterns and return human-readable hint strings.
    ///
    /// - Parameters:
    ///   - elements: OCR-detected tap points from the current screen.
    ///   - windowHeight: Height of the mirroring window in points.
    /// - Returns: Array of hint strings describing reliable alternatives
    ///   for detected navigation elements.
    public static func detect(elements: [TapPoint], windowHeight: Double) -> [String] {
        var hints: [String] = []
        let topZone = windowHeight * topZoneFraction
        let bottomZone = windowHeight * bottomZoneFraction

        var foundBackInTop = false
        var foundBackInBottom = false

        for element in elements {
            let trimmed = element.text.trimmingCharacters(in: .whitespaces)
            guard backChevronPatterns.contains(trimmed) else { continue }

            if element.tapY <= topZone && !foundBackInTop {
                foundBackInTop = true
            } else if element.tapY >= bottomZone && !foundBackInBottom {
                foundBackInBottom = true
            }
        }

        if foundBackInTop || foundBackInBottom {
            hints.append(
                "Back navigation: \"<\" detected — use press_key with key=\"[\" "
                + "modifiers=[\"command\"] instead of tapping (more reliable)"
            )
        }

        return hints
    }
}
