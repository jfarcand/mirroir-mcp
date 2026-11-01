// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds an app's tile on an open Spotlight screen: its name label below an app icon, or in a row of tiles.
// ABOUTME: launch_app taps that tile's label instead of typing when Spotlight already shows the app.

import Foundation
import HelperLib

/// An app tile in Spotlight: the app's icon with its name label right below it, as
/// in the top hit row and in Siri's suggested apps. When Spotlight reopens holding
/// a previous search, the iPhone ignores typed keys (even the Mac's own keyboard)
/// until iPhone Mirroring restarts, while taps still land. Tapping the tile's label
/// opens the app without typing into that field. The label is what gets tapped:
/// the icon detector places a tile's icon anywhere from its image to the card edge
/// above it, and sometimes misses it (an app icon drawn as a clock face reads as
/// text); a label on the same baseline as a row of tiles is then a tile too, as
/// the top hit is beside its app shortcuts. A row whose glyph sits beside its text
/// (a search-history "Q Clock", a web suggestion) is no tile, and its glyph marks
/// no tile below it.
enum SpotlightAppTile {

    /// Widest horizontal offset, in points, between an icon's center and its label's.
    static let maxCenterOffset = 20.0

    /// Vertical span, in points, a detected icon's center may sit above its label's
    /// center (31pt and 105pt were both measured for the same top hit on an XR).
    static let iconAboveLabel = 10.0 ... 120.0

    /// Widest vertical offset, in points, between a row glyph and the text beside it.
    static let rowTolerance = 12.0

    /// Widest gap, in points, from a row glyph to the text it sits beside.
    static let rowGlyphGap = 80.0

    /// The label to tap for `name`, or nil when no tile shows it. With several
    /// tiles, the highest one (the top hit) wins.
    static func label(for name: String, in elements: [TapPoint]) -> TapPoint? {
        let target = normalize(name)
        guard !target.isEmpty else { return nil }
        let icons = elements.filter { $0.text == CoreMLElementDetector.iconLabel }
        let texts = elements.filter { $0.text != CoreMLElementDetector.iconLabel }
        let tileIcons = icons.filter { icon in !texts.contains { isBeside(icon, $0) } }
        let iconLabels = texts.filter { label in tileIcons.contains { isAbove($0, label) } }
        let tiles = texts
            .filter { normalize($0.text) == target }
            .filter { label in
                iconLabels.contains { $0 == label || onSameRow($0, label) }
            }
        return tiles.min { $0.tapY < $1.tapY }
    }

    /// Whether two labels share a baseline: tiles of one row.
    private static func onSameRow(_ one: TapPoint, _ other: TapPoint) -> Bool {
        abs(one.tapY - other.tapY) <= rowTolerance
    }

    /// Whether `text` sits on `icon`'s row, just right of it: the icon is that
    /// row's glyph, not a tile's image.
    private static func isBeside(_ icon: TapPoint, _ text: TapPoint) -> Bool {
        abs(text.tapY - icon.tapY) <= rowTolerance
            && text.tapX > icon.tapX + maxCenterOffset
            && text.tapX - icon.tapX <= rowGlyphGap
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
