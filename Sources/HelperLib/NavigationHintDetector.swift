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

    /// Whether `text` is back-navigation chrome: a lone back chevron ("<") or a
    /// chevron-labeled back button ("< Back", "‹ Retour"). Such text appears on
    /// every detail screen, so it identifies nothing — landmark selection must
    /// never anchor on it.
    public static func isBackNavigationText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if backChevronPatterns.contains(trimmed) { return true }
        guard let first = trimmed.first else { return false }
        return backChevronPatterns.contains(String(first))
            && trimmed.dropFirst().first?.isWhitespace == true
    }
    /// Prefix for tab-bar presence hints. Consumers match on this prefix to
    /// classify tab-root screens even when the bar is icon-only (no OCR text).
    public static let tabBarHintPrefix = "Tab bar:"
    /// Fraction of window height where the tab-bar band starts. Narrower than
    /// `bottomZoneFraction` (toolbar zone): iOS tab bars occupy roughly the
    /// bottom 12% of the screen — the same convention as the tab-bar zones
    /// used elsewhere. List rows scrolled near the bottom of a Settings-style
    /// screen sit above this band and must not count as tab-bar evidence.
    public static let tabBarZoneFraction = 0.88
    /// Minimum number of tab-band points (short text labels plus detected
    /// icon points) required to report a tab bar. Tab bars typically have
    /// 3-5 items.
    public static let tabBarMinBandPoints = 3
    /// Maximum text length for a tab-band element to count as a tab label.
    /// Longer text is scrolled content.
    public static let tabBarLabelMaxLength = 40
    /// Maximum word count for a tab-band element to count as a tab label.
    /// Tab bar items are short (1-2 words); sentence-like text in the band is
    /// scrolled content or an action bar, not a tab bar.
    public static let tabBarLabelMaxWords = 2

    /// Detect navigation patterns and return human-readable hint strings.
    ///
    /// - Parameters:
    ///   - elements: OCR-detected tap points from the current screen.
    ///   - iconPoints: Detected unlabeled icon positions (text-less tap points)
    ///     from icon detection. Counted as tab-bar evidence for icon-only bars.
    ///   - windowHeight: Height of the mirroring window in points.
    ///   - isMobile: When true, emits tap-based hints (for iPhone Mirroring).
    ///     When false, emits keyboard shortcut hints (for desktop targets) and
    ///     no tab-bar hint, since a desktop window has no iOS tab bar.
    /// - Returns: Array of hint strings describing navigation alternatives
    ///   for detected navigation elements.
    public static func detect(
        elements: [TapPoint], iconPoints: [TapPoint] = [],
        windowHeight: Double, isMobile: Bool = true
    ) -> [String] {
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

        // A tab bar is iOS chrome: on a desktop window the bottom band is the
        // app's own content (Calculator's last row of keys), not a section bar.
        guard isMobile else { return hints }

        // Tab-bar presence: three or more short labels and/or detected icon
        // points clustered in the tab-bar band indicate a tab bar. Icon-only
        // bars (Instagram) carry no OCR text, so detected icon positions
        // count as evidence alongside short text labels. Labels are held to
        // the 1-2 word shape of real tab items so band-scrolled content
        // sentences cannot masquerade as a bar.
        let tabBarZone = windowHeight * tabBarZoneFraction
        let bandLabels = elements.filter { el in
            let trimmed = el.text.trimmingCharacters(in: .whitespaces)
            let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
            return el.tapY >= tabBarZone && !trimmed.isEmpty
                && trimmed.count <= tabBarLabelMaxLength
                && wordCount <= tabBarLabelMaxWords
        }
        let bandIcons = iconPoints.filter { $0.tapY >= tabBarZone }
        let bandPointCount = bandLabels.count + bandIcons.count
        if bandPointCount >= tabBarMinBandPoints {
            hints.append(
                "\(tabBarHintPrefix) \(bandPointCount) items detected in the "
                + "bottom band — tap one to switch sections."
            )
        }

        return hints
    }
}
