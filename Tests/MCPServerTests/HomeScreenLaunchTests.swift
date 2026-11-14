// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests launch_app's Home Screen route when Spotlight swallows the typed name (iOS 26, carnet#60).
// ABOUTME: The screen follows the menu items pressed and the taps posted, as the iPhone's would.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

/// Answers each read with what the iPhone shows given what was done so far.
/// Stands in for the capture, which only the device can produce.
private final class FollowingDescriber: ScreenDescribing, @unchecked Sendable {
    var screen: () -> [TapPoint] = { [] }

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        ScreenDescriber.DescribeResult(elements: screen(), screenshotBase64: "img")
    }
}

final class HomeScreenLaunchTests: XCTestCase {

    private func el(_ text: String, _ x: Double, _ y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.9)
    }

    /// Clock, the app in front before launch_app.
    private var clock: [TapPoint] { [el("00:00,00", 213, 303), el("Chronomètre", 267, 857)] }

    /// Idle Spotlight that took none of the typing (XR, carnet#60).
    private var idleSpotlight: [TapPoint] {
        [el("Suggestions de Siri", 97, 109), el(CoreMLElementDetector.iconLabel, 171, 189),
         el("Notes", 170, 218), el("Q Rechercher", 107, 872)]
    }

    /// A Home Screen page holding Rappels, with its search pill.
    private var homePage: [TapPoint] {
        [el("Notes", 70, 160), el("Rappels", 165, 160), el("Réglages", 260, 160),
         el("Horloge", 355, 160), el("Q Rechercher", 205, 783)]
    }

    /// Rappels, once open.
    private var rappels: [TapPoint] { [el("Mes listes", 120, 300), el("Épicerie", 140, 420)] }

    private func launch(
        name: String, home: @escaping (_ tapped: Bool) -> [TapPoint]
    ) -> (error: String?, bridge: StubBridge, poster: RecordingWindowPoster) {
        let bridge = StubBridge()
        bridge.frontmost = false
        bridge.windowInfo = WindowInfo(
            windowID: 4242, position: CGPoint(x: 100, y: 50),
            size: CGSize(width: 410, height: 898), pid: 777)
        let poster = RecordingWindowPoster()
        let describer = FollowingDescriber()
        let idle = idleSpotlight
        let front = clock
        describer.screen = {
            let items = bridge.menuActionCalls.map(\.item)
            if items.contains("Home Screen") { return home(!poster.buttons.isEmpty) }
            return items.count % 2 == 1 ? idle : front
        }
        let input = InputSimulation(bridge: bridge, keyboardLayout: .usQWERTY,
                                    pasteVerifier: describer, keyPoster: RecordingKeyPoster(),
                                    windowPoster: poster)
        return (input.launchApp(name: name), bridge, poster)
    }

    func testANameSpotlightIgnoresIsOpenedFromItsHomeScreenIcon() {
        let page = homePage
        let opened = rappels
        let run = launch(name: "Rappels") { tapped in tapped ? opened : page }
        XCTAssertNil(run.error, run.error ?? "")
        XCTAssertEqual(run.bridge.menuActionCalls.map(\.item), ["Spotlight", "Home Screen"],
                       "Spotlight opened, then Home, which closes it: the toggle is not pressed again")
        XCTAssertEqual(run.poster.buttons.first?.point, CGPoint(x: 165, y: 160), "the Rappels label's tap point")
    }

    func testAHomeScreenThatNeverShowsFailsWithTheSpotlightOnceExplanation() {
        let front = clock
        let run = launch(name: "Rappels") { _ in front }
        let error = run.error ?? ""
        XCTAssertEqual(error, InputSimulation.spotlightIgnoredTyping(
            name: "Rappels", homeFailure: "the Home Screen did not show (its search pill was not found)"))
        XCTAssertTrue(error.contains("can take typing only once"), error)
        XCTAssertFalse(error.contains("quit"), "the old remedy, quitting iPhone Mirroring, is gone")
        XCTAssertFalse(error.contains(AgentInstruction.waitForUser), "no stop instruction")
        XCTAssertTrue(run.poster.buttons.isEmpty, "nothing was tapped")
        XCTAssertEqual(run.bridge.menuActionCalls.map(\.item), ["Spotlight", "Home Screen"])
    }

    /// An app on another page fails honestly: no page is turned, because a
    /// drag across the icon grid can move icons into a folder (XR, 2026-11-12).
    func testAnAppNotOnTheShownPageFailsWithoutTurningAPage() {
        let page = homePage
        let run = launch(name: "Calendrier") { _ in page }
        let error = run.error ?? ""
        XCTAssertTrue(error.contains("no icon is labeled exactly 'Calendrier' on the Home Screen page that shows"),
                      error)
        XCTAssertTrue(error.contains("Other pages are not turned to"), error)
        XCTAssertTrue(run.poster.buttons.isEmpty, "no icon was tapped")
        XCTAssertEqual(run.bridge.menuActionCalls.map(\.item), ["Spotlight", "Home Screen"],
                       "Home is pressed once and the phone stays there")
    }

    /// An icon tapped while the Home Screen stays is not a launch.
    func testAnIconTapThatLeavesTheHomeScreenUpIsNotALaunch() {
        let page = homePage
        let run = launch(name: "Rappels") { _ in page }
        XCTAssertEqual(run.error, InputSimulation.spotlightIgnoredTyping(
            name: "Rappels", homeFailure: "the 'Rappels' icon was tapped but the Home Screen still shows"))
        XCTAssertEqual(run.poster.buttons.count, 2, "one click: down and up")
    }
}
