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
// ABOUTME: Tests launch_app's Mac Spotlight step: an app it opens skips the iPhone's Spotlight, and any miss falls back to it.
// ABOUTME: Also pins that a click goes only where Spotlight's own window is front-most, and which targets get the step.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

final class MacSpotlightLaunchTests: XCTestCase {

    private func screen(_ texts: [(String, Double, Double)]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.map { TapPoint(text: $0.0, tapX: $0.1, tapY: $0.2, confidence: 0.9) },
            screenshotBase64: "img")
    }

    private var home: ScreenDescriber.DescribeResult {
        screen([("Météo", 80, 200), ("Calendrier", 180, 200), ("Waze", 280, 600), ("Q Rechercher", 200, 850)])
    }

    /// Waze's map, as the iPhone showed it once Mac Spotlight opened it (2026-11-27).
    private var waze: ScreenDescriber.DescribeResult {
        screen([("Où va-t-on ?", 140, 640), ("Domicile", 90, 700), ("Travail", 220, 700), ("Récemment", 80, 760)])
    }

    private func input(reader: any ScreenDescribing, launcher: FakeMacLauncher,
                       poster: RecordingWindowPoster = RecordingWindowPoster(),
                       keys: RecordingKeyPoster = RecordingKeyPoster()) -> (InputSimulation, StubBridge) {
        let bridge = StubBridge()
        bridge.frontmost = false
        bridge.windowInfo = WindowInfo(
            windowID: 4242, position: CGPoint(x: 100, y: 50),
            size: CGSize(width: 410, height: 898), pid: 777)
        let input = InputSimulation(bridge: bridge, keyboardLayouts: .usQWERTY, pasteVerifier: reader,
                                    keyPoster: keys, pasteboard: RecordingPasteboard(contents: nil),
                                    windowPoster: poster, macLauncher: launcher)
        return (input, bridge)
    }

    func testAnAppOpenedFromMacSpotlightSkipsTheIPhoneSpotlight() {
        let launcher = FakeMacLauncher(outcome: .clicked)
        let home = self.home, waze = self.waze
        let poster = RecordingWindowPoster()
        let keys = RecordingKeyPoster()
        let (input, bridge) = input(
            reader: ReadAfter { launcher.names.isEmpty ? home : waze }, launcher: launcher,
            poster: poster, keys: keys)
        XCTAssertNil(input.launchApp(name: "Waze"))
        XCTAssertEqual(launcher.names, ["Waze"])
        XCTAssertTrue(bridge.menuActionCalls.isEmpty, "the iPhone's Spotlight is not opened")
        XCTAssertTrue(keys.keycodes.isEmpty)
        XCTAssertTrue(poster.buttons.isEmpty, "nothing is tapped on the iPhone")
    }

    /// Strava on the test Mac: its row is the Mac's Chrome web app, so the
    /// launcher clicks nothing and the iPhone's Spotlight opens the app.
    func testASkippedMacLaunchFallsBackToTheIPhoneSpotlight() {
        let launcher = FakeMacLauncher(outcome: .skipped("Mac Spotlight lists no iPhone app named 'Notes'"))
        let poster = RecordingWindowPoster()
        let clock = screen([("00:00,00", 213, 303), ("Chronomètre", 267, 857)])
        let idle = screen([("Suggestions de Siri", 97, 109), ("Q Rechercher", 107, 872)])
        let typed = screen([
            ("Meilleur résultat", 86, 107), (CoreMLElementDetector.iconLabel, 81, 177), ("Notes", 79, 219),
            ("Notes - Ouvrir", 137, 873),
        ])
        var reads = [clock, clock, idle, typed]
        let (input, bridge) = input(reader: ReadAfter {
            if !poster.buttons.isEmpty { return clock }
            return reads.count > 1 ? reads.removeFirst() : reads[0]
        }, launcher: launcher, poster: poster)
        XCTAssertNil(input.launchApp(name: "Notes"))
        XCTAssertEqual(launcher.names, ["Notes"])
        XCTAssertEqual(bridge.menuActionCalls.map(\.item), ["Spotlight"])
        XCTAssertEqual(poster.buttons.first?.point.x, 79, "the iPhone Spotlight's Notes tile is tapped")
    }

    /// The app already open in front: the click changes nothing, so the launch
    /// is not confirmed and the iPhone's Spotlight is used.
    func testAClickThatChangesNothingOnTheIPhoneIsNotALaunch() {
        let launcher = FakeMacLauncher(outcome: .clicked)
        let waze = self.waze
        let (input, _) = input(reader: ReadAfter { waze }, launcher: launcher)
        XCTAssertEqual(input.launchThroughMacSpotlight(name: "Waze"), .fallBack)
        XCTAssertEqual(launcher.names, ["Waze"])
    }

    /// Without a read before, nothing could confirm the launch: Mac Spotlight is not touched.
    func testWithoutAScreenReadMacSpotlightIsNotTouched() {
        let launcher = FakeMacLauncher(outcome: .clicked)
        let (input, _) = input(reader: StubDescriber(), launcher: launcher)
        XCTAssertEqual(input.launchThroughMacSpotlight(name: "Waze"), .fallBack)
        XCTAssertTrue(launcher.names.isEmpty)
    }

    /// A Mac panel that would not close would take the keys the iPhone's
    /// Spotlight needs: the launch stops with nothing typed or tapped.
    func testAPanelLeftOpenStopsTheLaunch() {
        let launcher = FakeMacLauncher(outcome: .panelLeftOpen("Mac Spotlight lists no iPhone app named 'Horloge'"))
        let home = self.home
        let keys = RecordingKeyPoster()
        let poster = RecordingWindowPoster()
        let (input, bridge) = input(reader: ReadAfter { home }, launcher: launcher, poster: poster, keys: keys)
        let error = input.launchApp(name: "Horloge")
        XCTAssertEqual(error, "'Horloge' was not launched: Mac Spotlight lists no iPhone app named 'Horloge', "
            + "and the Mac's Spotlight panel did not close, so nothing was typed on the iPhone (the panel "
            + "would take the keys). Close it on the Mac (Escape), then call launch_app again.")
        XCTAssertTrue(bridge.menuActionCalls.isEmpty)
        XCTAssertTrue(keys.keycodes.isEmpty)
        XCTAssertTrue(poster.buttons.isEmpty)
    }

    func testTheClickGoesOnlyWhereSpotlightIsFrontMost() {
        let menuLayer = WindowListHelper.mainMenuLayer
        let entries = [
            WindowListEntry(windowID: 1, ownerPID: 10, name: nil,
                            bounds: CGRect(x: 0, y: 0, width: 1700, height: 34), layer: menuLayer),
            WindowListEntry(windowID: 2, ownerPID: 1705, name: nil,
                            bounds: CGRect(x: 51, y: 34, width: 1659, height: 1073), layer: 23),
            WindowListEntry(windowID: 3, ownerPID: 42, name: nil,
                            bounds: CGRect(x: 0, y: 0, width: 1700, height: 1100), layer: 0),
        ]
        XCTAssertEqual(WindowListHelper.topmostWindowOwnerPID(at: CGPoint(x: 722, y: 398), entries: entries), 1705)
        XCTAssertEqual(WindowListHelper.topmostWindowOwnerPID(at: CGPoint(x: 20, y: 10), entries: entries), 42,
                       "the menu bar is not a window a click lands on")
        XCTAssertNil(WindowListHelper.topmostWindowOwnerPID(at: CGPoint(x: 5000, y: 10), entries: entries))
    }

    /// FakeMirroring stands in for iPhone Mirroring in integration tests and
    /// has no iPhone behind it.
    func testOnlyTheRealIPhoneMirroringGetsTheMacStep() {
        let fake = MirroringBridge(targetName: "iphone", bundleID: "com.jfarcand.FakeMirroring")
        XCTAssertNil(IPhoneMirroringTarget.macLauncher(for: fake, enabled: true))
        let real = MirroringBridge(targetName: "iphone", bundleID: IPhoneMirroringTarget.realMirroringBundleID)
        XCTAssertNotNil(IPhoneMirroringTarget.macLauncher(for: real, enabled: true))
        XCTAssertNil(IPhoneMirroringTarget.macLauncher(for: real, enabled: false), "macSpotlightLaunch off")
    }

    func testTheMacStepIsOffByDefault() {
        XCTAssertFalse(EnvConfig.macSpotlightLaunch)
    }
}

/// Records each app it is asked to open and answers `outcome`.
private final class FakeMacLauncher: MacAppLaunching, @unchecked Sendable {
    let outcome: MacSpotlightOutcome
    private(set) var names: [String] = []

    init(outcome: MacSpotlightOutcome) { self.outcome = outcome }

    func open(appNamed name: String) -> MacSpotlightOutcome {
        names.append(name)
        return outcome
    }
}

/// Answers every read with what `read` returns given what happened so far.
private final class ReadAfter: ScreenDescribing, @unchecked Sendable {
    let read: () -> ScreenDescriber.DescribeResult

    init(_ read: @escaping () -> ScreenDescriber.DescribeResult) { self.read = read }

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? { read() }
}
