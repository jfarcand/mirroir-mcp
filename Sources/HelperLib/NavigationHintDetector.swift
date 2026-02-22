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

    /// Tunable thresholds for navigation hint detection.
    public struct HintConfig {
        /// Fraction of window height that defines the top navigation zone.
        /// Elements above this threshold are considered nav bar candidates.
        public var topZoneFraction: Double

        /// Fraction of window height that defines the bottom toolbar zone.
        /// Elements below this threshold are considered toolbar candidates.
        public var bottomZoneFraction: Double

        /// Text patterns that indicate a back button.
        public var backChevronPatterns: Set<String>

        public init(
            topZoneFraction: Double = 0.15,
            bottomZoneFraction: Double = 0.85,
            backChevronPatterns: Set<String> = ["<", "‹", "〈"]
        ) {
            self.topZoneFraction = topZoneFraction
            self.bottomZoneFraction = bottomZoneFraction
            self.backChevronPatterns = backChevronPatterns
        }
    }

    /// Detect navigation patterns and return human-readable hint strings.
    ///
    /// - Parameters:
    ///   - elements: OCR-detected tap points from the current screen.
    ///   - windowHeight: Height of the mirroring window in points.
    ///   - config: Thresholds and patterns for detection. Uses defaults when omitted.
    /// - Returns: Array of hint strings describing reliable alternatives
    ///   for detected navigation elements.
    public static func detect(
        elements: [TapPoint],
        windowHeight: Double,
        config: HintConfig = HintConfig()
    ) -> [String] {
        var hints: [String] = []
        let topZone = windowHeight * config.topZoneFraction
        let bottomZone = windowHeight * config.bottomZoneFraction

        var foundBackInTop = false
        var foundBackInBottom = false

        for element in elements {
            let trimmed = element.text.trimmingCharacters(in: .whitespaces)
            guard config.backChevronPatterns.contains(trimmed) else { continue }

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
