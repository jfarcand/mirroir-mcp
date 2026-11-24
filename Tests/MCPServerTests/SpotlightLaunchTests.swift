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
// ABOUTME: Tests how launch_app opens Spotlight and taps the app's tile, the one it already shows or the typed top hit.
// ABOUTME: The menu item toggles Spotlight, so it is pressed only while Spotlight is closed.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

final class SpotlightLaunchTests: XCTestCase {

    private func el(_ text: String, _ x: Double, _ y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.9)
    }

    private func screen(_ elements: [TapPoint]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(elements: elements, screenshotBase64: "img")
    }

    /// Spotlight holding "Horloge", OCR'd on an XR (French UI): its top hit is the Clock tile.
    private var heldSpotlight: ScreenDescriber.DescribeResult {
        screen([
            el("Meilleur résultat", 86, 107),
            el(CoreMLElementDetector.iconLabel, 81, 188), el("Horloge", 80, 219),
            el("Q Horloge - Ouvrir", 133, 874),
        ])
    }

    /// Clock's stopwatch, the screen behind Spotlight once the app opened.
    private var clock: ScreenDescriber.DescribeResult {
        screen([el("00:00,00", 213, 303), el("Chronomètre", 267, 857), el("Minuteurs", 370, 856)])
    }

    /// Run launch_app over `screens`, read in order; once a tap is posted,
    /// every read returns `afterTap` when given (the app that opened).
    private func launch(
        name: String = "Horloge", screens: [ScreenDescriber.DescribeResult],
        afterTap: ScreenDescriber.DescribeResult? = nil
    ) -> (error: String?, bridge: StubBridge, poster: RecordingWindowPoster, keys: RecordingKeyPoster,
          describer: StubDescriber) {
        let bridge = StubBridge()
        bridge.frontmost = false
        bridge.windowInfo = WindowInfo(
            windowID: 4242, position: CGPoint(x: 100, y: 50),
            size: CGSize(width: 410, height: 898), pid: 777)
        let describer = StubDescriber()
        describer.describeResults = screens
        let poster = RecordingWindowPoster()
        let keys = RecordingKeyPoster()
        let reader = TapFollowingDescriber(base: describer, poster: poster, afterTap: afterTap)
        let input = InputSimulation(bridge: bridge, keyboardLayouts: .usQWERTY,
                                    pasteVerifier: reader, keyPoster: keys,
                                    pasteboard: RecordingPasteboard(contents: nil), windowPoster: poster)
        return (input.launchApp(name: name), bridge, poster, keys, describer)
    }

    /// Idle Spotlight on an XR (12:28): a suggested tile, no query held.
    private var idleSpotlight: ScreenDescriber.DescribeResult {
        screen([
            el("Suggestions de Siri", 97, 109), el("Plus de détails", 350, 107),
            el(CoreMLElementDetector.iconLabel, 171, 189), el("Notes", 170, 218),
            el("Q Rechercher", 107, 872),
        ])
    }

    /// "Notes" typed, with Notes installed (12:28): a top hit, and the field says it opens.
    private var typedInstalled: ScreenDescriber.DescribeResult {
        screen([
            el("Meilleur résultat", 86, 107),
            el(CoreMLElementDetector.iconLabel, 81, 177), el("Notes", 79, 219),
            el("Suggestions", 72, 284), el("Notes", 92, 328), el(CoreMLElementDetector.iconLabel, 42, 331),
            el("Notes - Ouvrir", 137, 873),
        ])
    }

    /// "Keynote" typed, with Keynote not installed (12:28): no top hit, a web
    /// suggestion, and an App Store row with its download cloud.
    private var typedNotInstalled: ScreenDescriber.DescribeResult {
        screen([
            el("Suggestions", 72, 108), el(CoreMLElementDetector.iconLabel, 42, 153), el("Keynote", 101, 154),
            el("App Store", 63, 342), el("Keynote: Design Present...", 207, 386),
            el(CoreMLElementDetector.iconLabel, 60, 411), el("Productivity", 143, 409),
            el("Keynote", 107, 872),
        ])
    }

    private static let returnKey = UInt16(36)

    /// carnet#60: on iOS 26 Return can do nothing in Spotlight, while taps land.
    func testAnAppTopHitIsOpenedByTappingItsTileNotWithReturn() {
        let run = launch(name: "Notes", screens: [clock, idleSpotlight, typedInstalled], afterTap: clock)
        XCTAssertNil(run.error)
        XCTAssertTrue(run.keys.keycodes.isEmpty, "Return is not pressed")
        XCTAssertEqual(run.poster.buttons.first?.point, CGPoint(x: 79, y: 219 - SpotlightAppTile.iconTapLift))
    }

    /// A top hit that is an app without a tile read (the field says it opens)
    /// is still opened with Return.
    func testAnAppTopHitWithoutATileIsLaunchedWithReturn() {
        let fieldOnly = screen([
            el("Meilleur résultat", 86, 107), el("Notes", 79, 219), el("Notes - Ouvrir", 137, 873),
        ])
        let run = launch(name: "Notes", screens: [clock, idleSpotlight, fieldOnly])
        XCTAssertNil(run.error)
        XCTAssertEqual(run.keys.keycodes, [Self.returnKey])
        XCTAssertTrue(run.poster.buttons.isEmpty)
    }

    func testAnIdleSuggestionTileIsTypedOverNotTapped() {
        let run = launch(name: "Notes", screens: [clock, idleSpotlight, typedInstalled], afterTap: clock)
        XCTAssertEqual(run.poster.buttons.first?.point.x, 79,
                       "the typed top hit is tapped, not the idle page's suggestion at x 170")
    }

    func testAnAppThatIsNotInstalledFailsWithoutReturn() {
        let run = launch(name: "Keynote", screens: [clock, idleSpotlight, typedNotInstalled])
        XCTAssertEqual(run.error, "Spotlight lists no app as its top result for 'Keynote', so Return "
            + "was not pressed: pressing it would open a web suggestion or an App Store page. The app "
            + "may not be installed, or its name on this iPhone may differ.")
        XCTAssertTrue(run.keys.keycodes.isEmpty)
        XCTAssertEqual(run.bridge.menuActionCalls.map(\.item), ["Spotlight", "Spotlight"],
                       "opened, then closed again so the query is not left on screen")
    }

    /// carnet#74, XR 2026-11-16: the field said "OpenTable — Ouvrir" before the
    /// store card's "Obtenir" was read; Return on that first read opened the
    /// App Store page. Two reads in a row must agree before Return.
    func testTheFieldIsNotTrustedBeforeTheStoreCardIsDrawn() {
        let fieldFirst = screen([
            el("Meilleur résultat", 86, 107), el("OpenTable", 165, 151), el("OpenTable - Ouvrir", 156, 874),
        ])
        let storeCard = screen([
            el("Meilleur résultat", 86, 107), el("OpenTable", 165, 151), el("Obtenir", 342, 171),
            el("Food & Drink", 167, 172), el("OpenTable - Ouvrir", 156, 874),
        ])
        // Reads 1-4: before opening, Spotlight open, and the typed name shown.
        // Read 5 opens the top-hit poll with the field alone; the old check
        // pressed Return there. The card is drawn on read 6.
        let run = launch(name: "OpenTable", screens: [clock, idleSpotlight, fieldFirst, fieldFirst, fieldFirst, storeCard])
        XCTAssertNotNil(run.error)
        XCTAssertTrue(run.keys.keycodes.isEmpty, "Return is never pressed on the store card")
        XCTAssertTrue(run.poster.buttons.isEmpty)
    }

    /// 14:39 on an XR: a refused launch left Spotlight open, and the next name was
    /// typed after it ("KeynoteNotes").
    func testAQuerySpotlightStillHoldsIsSelectedBeforeTyping() {
        let held = screen([
            el("Suggestions", 72, 108), el("Rechercher dans les apps", 119, 555), el("Keynote", 107, 872),
        ])
        let run = launch(name: "Notes", screens: [held, held, typedInstalled], afterTap: clock)
        XCTAssertNil(run.error)
        XCTAssertTrue(run.bridge.menuActionCalls.isEmpty, "pressing the menu item would close Spotlight")
        XCTAssertEqual(run.keys.keycodes, [UInt16(0)], "Cmd+A, then the tile is tapped")
    }

    /// carnet#99, XR, iOS 18: Spotlight reopened holding "google classroom" and
    /// the typed name landed in front of it. Its field said "Open" over a web
    /// search; Return opened that search and the launch was reported.
    func testTypingAddedToAHeldQueryIsNotLaunchedWithReturn() {
        let idle = screen([el("Siri Suggestions", 72, 96), el("Q Search", 73, 728)])
        let mixed = screen([
            el("Top Hit", 45, 96), el("Suggestions", 61, 216), el(CoreMLElementDetector.iconLabel, 36, 253),
            el("settingsgoogle classroomgoogle", 140, 253),
            el("Q settingsgoogle classroomgoogl - Open", 144, 731),
        ])
        let run = launch(name: "Settings", screens: [clock, idle, mixed])
        XCTAssertNotNil(run.error)
        XCTAssertFalse(run.keys.keycodes.contains(Self.returnKey), "Return is not pressed")
        XCTAssertTrue(run.poster.buttons.isEmpty, "nothing is tapped")
    }

    /// 18:35 on an XR: Spotlight holding "Photos" has an "App Store" section
    /// heading with a result's icon above it, which opens nothing when tapped.
    func testASectionHeadingIsNotATile() {
        let held = screen([
            el("Meilleur résultat", 86, 107), el(CoreMLElementDetector.iconLabel, 81, 189), el("Photos", 79, 219),
            el(CoreMLElementDetector.iconLabel, 69, 526), el("App Store", 63, 599),
            el("Q Photos - Ouvrir", 129, 872),
        ])
        let run = launch(name: "App Store", screens: [held, held, typedInstalled])
        XCTAssertTrue(run.poster.buttons.isEmpty, "typed instead of tapping the heading")
    }

    func testSpotlightAlreadyOpenIsNotToggledShut() {
        let run = launch(screens: [heldSpotlight, heldSpotlight, clock])
        XCTAssertNil(run.error)
        XCTAssertTrue(run.bridge.menuActionCalls.isEmpty, "pressing the menu item would close Spotlight")
    }

    func testAClosedSpotlightIsOpenedThroughTheMenu() {
        let run = launch(screens: [clock, heldSpotlight, clock])
        XCTAssertNil(run.error)
        XCTAssertEqual(run.bridge.menuActionCalls.map(\.item), ["Spotlight"])
    }

    /// carnet#70, 16:47:01 on an XR: right after press_home, the screen read
    /// before opening Spotlight decided it was already open. That read waits for
    /// a settled frame; the polls after it do not.
    func testTheScreenBeforeOpeningIsReadSettled() {
        let run = launch(screens: [clock, heldSpotlight, clock])
        XCTAssertEqual(run.describer.settleTimeouts.first, EnvConfig.frameSettleTimeoutUs)
        XCTAssertGreaterThan(EnvConfig.frameSettleTimeoutUs, 0)
        XCTAssertEqual(run.describer.settleTimeouts.dropFirst().first, 0, "the polls read the first frame")
    }

    func testTheTileIsTappedInsideItsIconNotOnItsLabel() {
        let run = launch(screens: [heldSpotlight, heldSpotlight, clock])
        let tapped = run.poster.buttons.first?.point
        XCTAssertEqual(tapped?.x, 80)
        XCTAssertEqual(tapped?.y, 219 - SpotlightAppTile.iconTapLift)
    }

    /// carnet#60: Spotlight that takes no keys at all is not pasted into, so
    /// Universal Clipboard never hands another Mac's clipboard to the iPhone.
    func testTypingThatChangesNothingIsNotFollowedByAPaste() {
        let bridge = StubBridge()
        bridge.frontmost = false
        bridge.windowInfo = WindowInfo(
            windowID: 4242, position: CGPoint(x: 100, y: 50),
            size: CGSize(width: 410, height: 898), pid: 777)
        let poster = RecordingWindowPoster()
        let pasteboard = RecordingPasteboard(contents: "kept")
        let (front, idle) = (clock, idleSpotlight)
        let reader = ClosureDescriber {
            bridge.menuActionCalls.map(\.item).contains("Spotlight")
                && !bridge.menuActionCalls.map(\.item).contains("Home Screen") ? idle : front
        }
        let input = InputSimulation(bridge: bridge, keyboardLayouts: .usQWERTY,
                                    pasteVerifier: reader, keyPoster: RecordingKeyPoster(),
                                    pasteboard: pasteboard, windowPoster: poster)
        XCTAssertNotNil(input.launchApp(name: "Rappels"))
        XCTAssertTrue(pasteboard.writes.isEmpty, "nothing went through the clipboard")
    }

    /// carnet#33: a non-Latin keyboard composes the typed name into its own
    /// script (Korean 2-set turns "Notes" into Hangul), so Spotlight never shows
    /// it. The query is selected and the name pasted verbatim, which lands.
    func testATypedNameThatComesOutAsOtherTextIsPastedVerbatim() {
        let bridge = StubBridge()
        bridge.frontmost = false
        bridge.windowInfo = WindowInfo(
            windowID: 4242, position: CGPoint(x: 100, y: 50),
            size: CGSize(width: 410, height: 898), pid: 777)
        let poster = RecordingWindowPoster()
        let keys = RecordingKeyPoster()
        let pasteboard = RecordingPasteboard(contents: "kept")
        let garbled = screen([el("Suggestions", 72, 108), el("Q ㅜㅐㅅㄷㄴ", 107, 872)])
        let (front, idle, typed) = (clock, idleSpotlight, typedInstalled)
        let reader = ClosureDescriber {
            if !poster.buttons.isEmpty { return front }
            if pasteboard.writes.contains("Notes") { return typed }
            if !poster.keyFocusWindows.isEmpty { return garbled }
            return bridge.menuActionCalls.isEmpty ? front : idle
        }
        let input = InputSimulation(bridge: bridge, keyboardLayouts: .usQWERTY,
                                    pasteVerifier: reader, keyPoster: keys,
                                    pasteboard: pasteboard, windowPoster: poster)
        XCTAssertNil(input.launchApp(name: "Notes"))
        XCTAssertEqual(pasteboard.writes.first, "Notes", "the name went through the clipboard verbatim")
        XCTAssertEqual(pasteboard.contents, "kept", "the pasteboard is restored after the paste")
        XCTAssertEqual(poster.buttons.first?.point, CGPoint(x: 79, y: 219 - SpotlightAppTile.iconTapLift),
                       "the pasted query's top-hit tile is tapped")
    }
}

/// Reads `base` in order until a tap is posted, then `afterTap` when given:
/// the screen after a tile tap is the app, however many reads came before.
private final class TapFollowingDescriber: ScreenDescribing, @unchecked Sendable {
    let base: StubDescriber
    let poster: RecordingWindowPoster
    let afterTap: ScreenDescriber.DescribeResult?

    init(base: StubDescriber, poster: RecordingWindowPoster, afterTap: ScreenDescriber.DescribeResult?) {
        self.base = base
        self.poster = poster
        self.afterTap = afterTap
    }

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        if let afterTap, !poster.buttons.isEmpty { return afterTap }
        return base.describe(settleTimeoutUs: settleTimeoutUs)
    }

}

/// Answers every read with what `screen` returns given the actions so far.
private final class ClosureDescriber: ScreenDescribing, @unchecked Sendable {
    let screen: () -> ScreenDescriber.DescribeResult

    init(_ screen: @escaping () -> ScreenDescriber.DescribeResult) {
        self.screen = screen
    }

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? { screen() }
}
