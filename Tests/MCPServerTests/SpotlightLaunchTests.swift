// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests how launch_app opens Spotlight and taps an app tile it already shows.
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

    private func launch(
        screens: [ScreenDescriber.DescribeResult]
    ) -> (error: String?, bridge: StubBridge, poster: RecordingWindowPoster) {
        let bridge = StubBridge()
        bridge.frontmost = false
        bridge.windowInfo = WindowInfo(
            windowID: 4242, position: CGPoint(x: 100, y: 50),
            size: CGSize(width: 410, height: 898), pid: 777)
        let describer = StubDescriber()
        describer.describeResults = screens
        let poster = RecordingWindowPoster()
        let input = InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY,
                                    pasteVerifier: describer, keyPoster: RecordingKeyPoster(),
                                    windowPoster: poster)
        return (input.launchApp(name: "Horloge"), bridge, poster)
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

    func testTheTileIsTappedInsideItsIconNotOnItsLabel() {
        let run = launch(screens: [heldSpotlight, heldSpotlight, clock])
        let tapped = run.poster.buttons.first?.point
        XCTAssertEqual(tapped?.x, 80)
        XCTAssertEqual(tapped?.y, 219 - SpotlightAppTile.iconTapLift)
    }
}
