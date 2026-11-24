/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Opens iPhone Mirroring's Control Center (iOS 27) on its connectivity page and reads a tile's state.
// ABOUTME: set_network's path on phones Mirroring gives Control Center to; tile labels and the off word are pattern data.

import CoreGraphics
import Foundation
import HelperLib

/// Control Center, reached through iPhone Mirroring's View > Control Centre
/// command (Cmd-4, macOS 27). Mirroring gives it only to an iPhone on iOS 27
/// or later; for an older one it shows "Update Required" and pauses the
/// session instead, which is how this path tells it is not available.
///
/// The connectivity page lists Airplane Mode, Wi-Fi and cellular data as
/// labelled tiles, each with one line under the label: the off word
/// (`Non`, `Off`) when the tile is off, anything else (a network name, a SIM
/// line) when it is on. That line, not the icon's colour, is read: an off
/// icon is translucent and takes the colour of the wallpaper behind it.
enum ControlCenterNetwork {

    /// The key equivalent of View > Control Centre in iPhone Mirroring.
    static let commandKey = "4"

    /// Swipes up through Control Center's pages looking for the connectivity
    /// page before giving up.
    static let maxPageSwipes = 4

    /// The largest gap, in window points, from one line of a tile to the next
    /// (measured 18-19 pt on an iPhone 16 window 379-426 pt wide).
    static let maxLineGap = 28.0

    /// The largest horizontal offset, in window points, between the centres
    /// of a tile's lines (measured up to 26 pt; the next tile is 150+ pt away).
    static let maxColumnOffset = 60.0

    /// Where the page swipe starts and ends, as fractions of the window height.
    /// A shorter drag (83% to 32%) moved the page and let it snap back
    /// (2026-11-23); the start stays off the bottom edge, where a swipe up
    /// closes Control Center.
    static let swipeFromFraction = 0.8
    static let swipeToFraction = 0.1

    /// The page swipe's speed, in points per second: a real trackpad flick.
    /// Control Center pages only on a flick; anything slower than
    /// `SwipeGestureProfile.flickVelocity` is posted as a drag, which does not
    /// page (2026-11-23: 382 pt in 200 ms, 1900 pt/s, never left the first page).
    static let pageFlickSpeed = 3300.0

    /// How long the page swipe takes for a window `height` points tall, so
    /// that it moves at `pageFlickSpeed` whatever the window's size.
    static func swipeDurationMs(height: Double) -> Int {
        Int(height * (swipeFromFraction - swipeToFraction) / pageFlickSpeed * 1000)
    }

    /// Whether Control Center was opened on its connectivity page.
    enum Opening: Equatable {
        /// The connectivity page shows.
        case opened
        /// This Mac or this iPhone has no Control Center through Mirroring;
        /// nothing reached the iPhone, or the refusal was dismissed.
        case unavailable(String)
        /// Control Center opened, but its connectivity page was not found.
        case failed(String)
    }

    /// Open Control Center and page to its connectivity tiles.
    static func open(
        menuBridge: any MenuActionCapable, input: any InputProviding,
        describer: any ScreenDescribing, size: CGSize, loadUs: UInt32, phrases: SystemPhrases
    ) -> Opening {
        if let refusal = input.ensureConnected(tag: "set_network") {
            return .failed(refusal)
        }
        guard menuBridge.pressMenuItem(commandKey: commandKey) else {
            return .unavailable("this iPhone Mirroring has no Control Centre command")
        }
        usleep(loadUs)
        guard menuBridge.getState() == .connected else {
            _ = input.ensureConnected(tag: "set_network")
            return .unavailable("iPhone Mirroring refused Control Centre (it needs iOS 27 on the iPhone)")
        }
        let pager = Pager(input: input, describer: describer, size: size, loadUs: loadUs)
        switch pager.page(until: { isConnectivityPage($0, phrases: phrases) }) {
        case .found: return .opened
        case .failed(let reason): return .failed(reason + " Nothing was tapped.")
        case .notFound:
            return .failed("Control Center opened, but its connectivity tiles (Airplane Mode, Wi-Fi, "
                + "cellular data) were not found on any page. Nothing was tapped.")
        }
    }

    /// Tap `section`'s icon on the connectivity page, placed from the tile's
    /// own text as OCR reads it on `locator`. Only the round icon toggles a
    /// tile: a tap on the tile body does nothing, and Control Center's first
    /// page shows the connectivity tiles as one button that opens this page
    /// (2026-11-24: an exact tap on its cellular glyph toggled nothing).
    /// Neither OCR nor the icon detector finds the round icons, so the tap
    /// point comes from the label's left edge and the state line.
    static func tapIcon(
        _ section: SystemPhrases.Section, input: any InputProviding,
        locator: any ScreenDescribing, size: CGSize, phrases: SystemPhrases
    ) -> String? {
        guard let screen = locator.describe(),
              let tile = tile(section, in: screen.elements, phrases: phrases),
              let icon = iconPoint(of: tile, shape: shape(of: section), windowWidth: Double(size.width))
        else {
            return "The tile's text and state line were not read with their positions, "
                + "so its icon could not be placed; nothing was tapped."
        }
        DebugLog.log("set_network", "tile \(tile.label.text) icon at (\(Int(icon.x)),\(Int(icon.y)))")
        return input.tap(x: icon.x, y: icon.y)
    }

    /// How a connectivity tile lays out its icon: above its text (Wi-Fi,
    /// cellular data) or beside it (Airplane Mode's full-width tile).
    enum TileShape {
        case square
        case pill
    }

    /// The shape of `section`'s tile. The connectivity page's layout is fixed
    /// by iOS: it is not one of the Control Center controls a user arranges.
    static func shape(of section: SystemPhrases.Section) -> TileShape {
        section == .controlCenterAirplaneTile ? .pill : .square
    }

    /// The window width, in points, the icon offsets below were measured at
    /// (iPhone 16, iOS 27); they scale with the window (checked at 319 pt).
    static let referenceWindowWidth = 359.0

    /// In a square tile, how far right of the text's left edge, and how far
    /// above the state line, the icon's centre lies.
    static let squareIconInset = 15.0
    static let squareIconRise = 80.0

    /// In a pill tile, how far left of the text's left edge the icon's
    /// centre lies; vertically it is centred on the label and state lines.
    static let pillIconGap = 18.0

    /// Where `tile`'s icon is, from its label's left edge and its state line;
    /// nil when either was read without a position (a vision model's tile).
    static func iconPoint(of tile: Tile, shape: TileShape, windowWidth: Double) -> CGPoint? {
        guard let width = tile.label.width, let status = tile.statusLine else { return nil }
        let scale = windowWidth / referenceWindowWidth
        let left = tile.label.tapX - width / 2
        switch shape {
        case .square:
            return CGPoint(x: left + squareIconInset * scale, y: status.tapY - squareIconRise * scale)
        case .pill:
            return CGPoint(x: left - pillIconGap * scale, y: (tile.label.tapY + status.tapY) / 2)
        }
    }

    /// Whether `elements` are the connectivity page: Airplane Mode's tile with
    /// a readable state. Control Center's first page also names "Mode avion"
    /// to a vision model, with no state.
    static func isConnectivityPage(_ elements: [TapPoint], phrases: SystemPhrases) -> Bool {
        guard let airplane = tile(.controlCenterAirplaneTile, in: elements, phrases: phrases) else {
            return false
        }
        return state(of: airplane, phrases: phrases) != .none
    }

    /// The outcome of paging until a page matches.
    enum PageSearch {
        case found
        case notFound
        case failed(String)
    }

    /// Flicks through Control Center's pages, reading each one.
    struct Pager {
        let input: any InputProviding
        let describer: any ScreenDescribing
        let size: CGSize
        let loadUs: UInt32

        /// Read the page and flick to the next one until `matches` holds, at
        /// most `maxPageSwipes` times; a page that did not move ends the search.
        func page(until matches: ([TapPoint]) -> Bool) -> PageSearch {
            var previous: [String]?
            for swipe in 0 ... maxPageSwipes {
                guard let screen = describer.describe() else {
                    return .failed("Control Center could not be read.")
                }
                if matches(screen.elements) { return .found }
                let texts = screen.elements.map(\.text)
                guard swipe < maxPageSwipes, texts != previous else { return .notFound }
                previous = texts
                if let error = flick() { return .failed("Failed to page Control Center: \(error)") }
                usleep(loadUs)
            }
            return .notFound
        }

        /// Flick up, to the next page.
        private func flick() -> String? {
            let x = Double(size.width) / 2
            return input.swipe(
                fromX: x, fromY: Double(size.height) * swipeFromFraction,
                toX: x, toY: Double(size.height) * swipeToFraction,
                durationMs: swipeDurationMs(height: Double(size.height)), cursorMode: nil)
        }
    }

    /// A tile found on screen: where its label starts, and the line under it
    /// as text and, when OCR read it, as a positioned line.
    struct Tile: Equatable {
        let label: TapPoint
        let status: String?
        let statusLine: TapPoint?
    }

    /// What separates a tile's label from its state when a vision model reports
    /// both as one element ("Mode Avion — Non", 2026-11-23).
    static let visionStateSeparators = [" — ", " – "]

    /// The tile labelled with one of `section`'s phrases: one element holding
    /// "label — state" (a vision model), or the label's lines joined with the
    /// line under them (OCR). Nil when no element starts such a label.
    static func tile(
        _ section: SystemPhrases.Section, in elements: [TapPoint], phrases: SystemPhrases
    ) -> Tile? {
        let labels = phrases.phrases(section)
        for element in elements {
            for separator in visionStateSeparators {
                guard let range = element.text.range(of: separator),
                      labels.contains(fold(String(element.text[..<range.lowerBound]))) else { continue }
                let status = element.text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return Tile(label: element, status: status.isEmpty ? nil : status, statusLine: nil)
            }
        }
        for start in elements {
            var text = fold(start.text)
            guard labels.contains(where: { $0 == text || $0.hasPrefix(text + " ") }) else { continue }
            var last = start
            while !labels.contains(text), let next = line(below: last, in: elements),
                  labels.contains(where: { $0.hasPrefix(text + " " + fold(next.text)) }) {
                text += " " + fold(next.text)
                last = next
            }
            guard labels.contains(text) else { continue }
            let statusLine = line(below: last, in: elements)
            return Tile(label: start, status: statusLine?.text, statusLine: statusLine)
        }
        return nil
    }

    /// The state a tile's status line shows: off for an off word, on for any
    /// other line, unreadable when there is none.
    static func state(of tile: Tile, phrases: SystemPhrases) -> SettingsSwitchReader.State {
        guard let status = tile.status else { return .none }
        return phrases.phrases(.controlCenterOffState).contains(fold(status)) ? .off : .on
    }

    /// The next line of text under `element` in the same column. An icon the
    /// element detector placed there is not a line: taken as the state line,
    /// it read as on (2026-11-23: an "icon" 10 pt under "Mode Avion", whose
    /// faint "Non" OCR missed, had `airplane_off` turn Airplane Mode on).
    private static func line(below element: TapPoint, in elements: [TapPoint]) -> TapPoint? {
        elements
            .filter {
                $0.text != CoreMLElementDetector.iconLabel
                    && $0.tapY > element.tapY && $0.tapY - element.tapY <= maxLineGap
                    && abs($0.tapX - element.tapX) <= maxColumnOffset
            }
            .min { $0.tapY < $1.tapY }
    }

    private static func fold(_ text: String) -> String {
        SystemPhrases.fold(text).trimmingCharacters(in: .whitespaces)
    }
}
