// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds an app's icon tile on an open Spotlight screen: its name label with an app icon above it.
// ABOUTME: launch_app taps that tile's label instead of typing when Spotlight already shows the app.

import Foundation
import HelperLib

/// An app tile in Spotlight: the app's icon with its name label right below it, as
/// in the top hit row and in Siri's suggested apps. When Spotlight reopens holding
/// a previous search, the iPhone ignores typed keys (even the Mac's own keyboard)
/// until iPhone Mirroring restarts, while taps still land. Tapping the tile's label
/// opens the app without typing into that field. The label is what gets tapped:
/// the icon detector places a tile's icon anywhere from its image to the card edge
/// above it. A search-history row ("Q Clock") does not count: its glyph sits
/// beside the text, not above it.
enum SpotlightAppTile {

    /// Widest horizontal offset, in points, between an icon's center and its label's.
    static let maxCenterOffset = 20.0

    /// Vertical span, in points, a detected icon's center may sit above its label's
    /// center (31pt and 105pt were both measured for the same top hit on an XR).
    static let iconAboveLabel = 10.0 ... 120.0

    /// The label to tap for `name`, or nil when no tile shows it. With several
    /// tiles, the highest one (the top hit) wins.
    static func label(for name: String, in elements: [TapPoint]) -> TapPoint? {
        let target = normalize(name)
        guard !target.isEmpty else { return nil }
        let icons = elements.filter { $0.text == CoreMLElementDetector.iconLabel }
        let tiles = elements
            .filter { normalize($0.text) == target }
            .filter { label in icons.contains { isAbove($0, label) } }
        return tiles.min { $0.tapY < $1.tapY }
    }

    private static func isAbove(_ icon: TapPoint, _ label: TapPoint) -> Bool {
        abs(icon.tapX - label.tapX) <= maxCenterOffset
            && iconAboveLabel.contains(label.tapY - icon.tapY)
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
