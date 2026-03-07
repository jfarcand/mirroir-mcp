// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Detects navigation patterns in OCR results and generates target-aware navigation hints.
// ABOUTME: Mobile targets get tap-based advice; desktop targets get keyboard shortcut advice.

/// Analyzes OCR-detected elements for navigation patterns and generates
/// actionable hints appropriate for the target type.
///
/// Mobile targets (iPhone Mirroring) receive tap-based back navigation
/// hints, while desktop targets receive keyboard shortcut hints (Cmd+[).
public enum NavigationHintDetector {
    /// Fraction of window height that defines the top navigation zone.
    /// Elements in the top 15% are considered nav bar candidates.
    public static let topZoneFraction = 0.15
    /// Fraction of window height that defines the bottom toolbar zone.
    /// Elements in the bottom 15% are considered toolbar candidates.
    public static let bottomZoneFraction = 0.85
    /// Text patterns that indicate a back button.
    public static let backChevronPatterns: Set<String> = ["<", "‹", "〈"]

    /// Detect navigation patterns and return human-readable hint strings.
    ///
    /// - Parameters:
    ///   - elements: OCR-detected tap points from the current screen.
    ///   - windowHeight: Height of the mirroring window in points.
    ///   - isMobile: When true, emits tap-based hints (for iPhone Mirroring).
    ///     When false, emits keyboard shortcut hints (for desktop targets).
    /// - Returns: Array of hint strings describing navigation alternatives
    ///   for detected navigation elements.
    public static func detect(elements: [TapPoint], windowHeight: Double, isMobile: Bool = true) -> [String] {
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
            if isMobile {
                hints.append(
                    "Back navigation: \"<\" detected — tap it to go back."
                )
            } else {
                hints.append(
                    "Back navigation: \"<\" detected — use press_key with "
                    + "key=\"[\" modifiers=[\"command\"] (more reliable than tapping)."
                )
            }
        }

        return hints
    }
}
