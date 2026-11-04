// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds an app's tile on an open Spotlight screen: its name label below an app icon, or in a row of tiles.
// ABOUTME: launch_app taps that tile's label instead of typing when Spotlight already shows the app.

import Foundation
import HelperLib

/// An app tile in Spotlight: the app's icon with its name label right below it, as
/// in the top hit row and in Siri's suggested apps. Typed keys can stop reaching
/// the iPhone (even the Mac's own keyboard) until iPhone Mirroring restarts, while
/// taps still land; Spotlight then often reopens holding the previous search.
/// Tapping the tile opens the app without typing into that field. The tile is found by its label: the
/// icon detector places a tile's icon anywhere from its image to the card edge
/// above it, and sometimes misses it (an app icon drawn as a clock face reads as
/// text); a label on the same baseline as a row of tiles is then a tile too, as
/// the top hit is beside its app shortcuts. The tap itself goes into the icon,
/// `iconTapLift` above the label (see `tapPoint(for:)`). A row whose glyph sits beside its text
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

    /// How far above its label's center a tile is tapped, in points. Spotlight
    /// opens a tile from its icon only: a tap on the label does nothing, through
    /// HID and through a window record alike (measured on an XR, iOS 26), while
    /// taps 20pt and 43pt above the label opened the app. The label sits right
    /// below an icon about 64pt tall, so this lands inside the icon.
    static let iconTapLift = 30.0

    /// How far below the top-hit heading its tile's label sits at most, in points
    /// (112pt measured on an XR).
    static let topHitReach = 150.0

    /// The label to tap for `name`, or nil when no tile shows it. With several
    /// tiles, the highest one (the top hit) wins.
    static func label(for name: String, in elements: [TapPoint]) -> TapPoint? {
        let target = normalize(name)
        guard !target.isEmpty else { return nil }
        let labels = iconLabels(in: elements)
        let tiles = elements
            .filter { $0.text != CoreMLElementDetector.iconLabel && normalize($0.text) == target }
            .filter { label in
                labels.contains { $0 == label || onSameRow($0, label) }
            }
        return tiles.min { $0.tapY < $1.tapY }
    }

    /// The text elements with a tile's icon above them.
    private static func iconLabels(in elements: [TapPoint]) -> [TapPoint] {
        let icons = elements.filter { $0.text == CoreMLElementDetector.iconLabel }
        let texts = elements.filter { $0.text != CoreMLElementDetector.iconLabel }
        let tileIcons = icons.filter { icon in !texts.contains { isBeside(icon, $0) } }
        return texts.filter { label in tileIcons.contains { isAbove($0, label) } }
    }

    /// Where to tap the tile `label` names: inside its icon, above the label.
    static func tapPoint(for label: TapPoint) -> (x: Double, y: Double) {
        (label.tapX, label.tapY - iconTapLift)
    }

    /// The label of the tile that is Spotlight's top result: the first tile under
    /// the top-hit heading, within `topHitReach`. Nil when the top result is not a
    /// tile (a message or a web row has its image beside its text).
    static func topHit(in elements: [TapPoint]) -> TapPoint? {
        guard let heading = elements.first(where: { element in
            SpotlightDetector.topHitHeadings.contains {
                element.text.lowercased().contains($0.lowercased())
            }
        }) else { return nil }
        let reach = heading.tapY ... (heading.tapY + topHitReach)
        return iconLabels(in: elements)
            .filter { reach.contains($0.tapY) }
            .min { $0.tapY < $1.tapY }
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
