// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that emitted labels are text OCR read on the screen acted on, and waits name what is on screen.
// ABOUTME: Covers arrivedVia over displayLabel, icon-only tabs, scroll_to, containment, below-the-fold landmarks.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class ScenarioLabelAndLandmarkTests: XCTestCase {

    private func points(_ labels: [String], startY: Double = 120) -> [TapPoint] {
        labels.enumerated().map { i, text in
            TapPoint(text: text, tapX: 200, tapY: startY + Double(i) * 60, confidence: 0.95)
        }
    }

    private func screen(
        _ index: Int, _ action: String?, _ via: String?, _ labels: [String],
        displayLabel: String? = nil
    ) -> ExploredScreen {
        ExploredScreen(
            index: index, elements: points(labels), hints: [],
            actionType: action, arrivedVia: via, displayLabel: displayLabel,
            screenshotBase64: "")
    }

    private func refusal(_ screens: [ExploredScreen]) -> ScenarioStepFormatter.FormatError? {
        do {
            _ = try ScenarioStepFormatter.scenarioYAML(name: "f", appName: "App", screens: screens)
            return nil
        } catch {
            return error as? ScenarioStepFormatter.FormatError
        }
    }

    // MARK: - Labels

    /// The text actually tapped wins over the display label: a tab matched by
    /// substring was tapped as "Alarms 3", and that is what OCR reads.
    func testTheTappedTextWinsOverTheDisplayLabel() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(name: "f", appName: "Clock", screens: [
            screen(0, nil, nil, ["World Clock", "Alarms 3"]),
            screen(1, "tap", "Alarms 3", ["Edit", "Add Alarm"], displayLabel: "Alarms"),
        ])
        XCTAssertTrue(yaml.contains("  - tap: \"Alarms 3\"\n"), yaml)
    }

    /// An icon-only tab bar has no OCR text: TabTargetInjector synthesizes a
    /// textless anchor named from APP.md. A replay could never find that name
    /// on screen, so the emit refuses it rather than writing a tap that fails.
    func testAnIconOnlyTabIsRefusedNotEmittedUnderItsAppMdName() {
        let windowSize = CGSize(width: 410, height: 890)
        let targets = TabTargetInjector.findTargets(
            tabNames: ["Library", "Search"],
            elements: [TapPoint(text: "•", tapX: 100, tapY: 860, confidence: 0.9)],
            visitedElements: [],
            tabLayout: TabLayout(orientation: .horizontal, edge: .bottom),
            windowSize: windowSize)
        guard let library = targets.first(where: { $0.displayLabel == "Library" }) else {
            return XCTFail("expected a synthesized Library anchor, got \(targets.map(\.reason))")
        }
        XCTAssertEqual(library.point.text, "", "a synthesized anchor carries no OCR text")

        let error = refusal([
            screen(0, nil, nil, ["Listen Now", "Top Picks"]),
            screen(1, "tap", library.point.text, ["Playlists", "Albums"],
                   displayLabel: library.displayLabel),
        ])
        XCTAssertEqual(error, .labelNotOnScreen(index: 1, action: "tap", label: "Library"))
    }

    /// No containment match: a tap on "Every" against a screen showing only
    /// "Every Sunday" is refused, never rewritten into the other control.
    func testAContainedLabelIsRefusedNotRewritten() {
        let error = refusal([
            screen(0, nil, nil, ["Repeat", "Every Sunday"]),
            screen(1, "tap", "Every", ["Done"]),
        ])
        XCTAssertEqual(error, .labelNotOnScreen(index: 1, action: "tap", label: "Every"))
    }

    /// `scroll_to` names what the scroll brought into view: it resolves on the
    /// screen it reached. A source showing only "Every" does not turn
    /// `scroll_to: "Every Sunday"` into `scroll_to: "Every"`.
    func testScrollToResolvesOnTheScreenItReached() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(name: "f", appName: "Clock", screens: [
            screen(0, nil, nil, ["Repeat", "Every"]),
            screen(1, "scroll_to", "every sunday", ["Every", "Every Sunday"]),
        ])
        XCTAssertTrue(yaml.contains("  - scroll_to: \"Every Sunday\"\n"), yaml)
        XCTAssertFalse(yaml.contains("scroll_to: \"Every\"\n"), yaml)

        XCTAssertEqual(refusal([
            screen(0, nil, nil, ["Repeat", "Every Sunday"]),
            screen(1, "scroll_to", "Every Monday", ["Every Sunday"]),
        ]), .labelNotOnScreen(index: 1, action: "scroll_to", label: "Every Monday"))
    }

    /// A tap on a row the explorer reached by scrolling the source screen is
    /// not on the viewport a replay lands on: a `scroll_to:` on that row comes
    /// first. A tap on an arrival-viewport label gets none.
    func testATapOnAScrolledInRowScrollsToItFirst() throws {
        var source = ExploredScreen(
            index: 0, elements: points(["Alarms", "Edit", "Bedtime"]) + points(["Snooze Settings"], startY: 900),
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "")
        source.scrolledElementCount = 1
        var viaScroll = screen(1, "tap", "snooze settings", ["Snooze Length"])
        viaScroll.scrolledElementCount = 0
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "f", appName: "Clock", screens: [source, viaScroll])
        XCTAssertTrue(yaml.contains(
            "  - scroll_to: \"Snooze Settings\"\n  - tap: \"Snooze Settings\"\n" +
            "  - wait_for: \"Snooze Length\"\n"), yaml)

        let onArrival = try ScenarioStepFormatter.scenarioYAML(
            name: "f", appName: "Clock", screens: [source, screen(1, "tap", "Bedtime", ["Sleep"])])
        XCTAssertFalse(onArrival.contains("scroll_to:"), onArrival)
    }

    /// The unsupported-action refusal names its step like every other one.
    func testAnUnsupportedActionNamesItsStep() {
        XCTAssertEqual(refusal([
            screen(0, nil, nil, ["Map"]),
            screen(1, "tap", "Map", ["Zoomed"]),
            screen(2, "pinch", "Zoomed", ["Street"]),
        ]), .unsupportedAction(index: 2, action: "pinch"))
    }

    // MARK: - Landmarks

    /// A row calibration found by scrolling is not on screen when the tap
    /// lands: the wait names the longest label of the arrival viewport, and
    /// the closing assertion does too — never the longer row below the fold.
    func testLandmarksComeOnlyFromTheViewportSeenOnArrival() throws {
        let graph = NavigationGraph()
        graph.start(rootElements: points(["Settings", "General"]), icons: [], hints: [],
                    screenshot: "root", screenType: .settings)
        _ = graph.recordTransition(
            elements: points(["About", "Name"]), icons: [], hints: [], screenshot: "a",
            actionType: "tap", elementText: "General", screenType: .list)
        let merged = graph.mergeScrolledElements(
            fingerprint: graph.currentFingerprint,
            newElements: points(["Legal and Regulatory Information"], startY: 700))
        XCTAssertEqual(merged, 1)

        let snapshot = graph.finalize()
        guard let path = GraphPathFinder.findInterestingPaths(in: snapshot).first else {
            return XCTFail("expected a path")
        }
        let screens = GraphPathFinder.pathToExploredScreens(path: path.edges, snapshot: snapshot)
        XCTAssertEqual(screens.last?.scrolledElementCount, 1)
        XCTAssertEqual(screens.last?.arrivalElements.map(\.text), ["About", "Name"])
        XCTAssertEqual(screens.last?.elements.count, 3, "the full element set is kept")

        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "f", appName: "Settings", screens: screens)
        XCTAssertTrue(yaml.contains("  - tap: \"General\"\n  - wait_for: \"About\"\n"), yaml)
        XCTAssertFalse(yaml.contains("Legal and Regulatory Information"), yaml)
    }

    /// Equal-length landmarks tie-break on screen order.
    func testALandmarkTieGoesToTheFirstLabelOnScreen() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(name: "f", appName: "App", screens: [
            screen(0, nil, nil, ["Home", "Open"]),
            screen(1, "tap", "Open", ["Abcd", "Wxyz"]),
        ])
        XCTAssertTrue(yaml.contains("  - wait_for: \"Abcd\"\n"), yaml)
    }

    /// The status-bar clock is new on every arrival, so it once became the wait
    /// (Horloge, 2026-10-30: `wait_for: "16:33 €"` passed before the sheet rose).
    func testTheStatusBarClockIsNeverALandmark() throws {
        let clock = { (text: String) in TapPoint(text: text, tapX: 58, tapY: 63, confidence: 0.9) }
        let source = ExploredScreen(
            index: 0, elements: [clock("16:32 €")] + points(["Alarmes", "CONFIGURER"]),
            hints: [], actionType: nil, arrivedVia: nil, displayLabel: nil, screenshotBase64: "")
        let arrived = ExploredScreen(
            index: 1, elements: [clock("16:33 €")] + points(["Annuler", "Sommeil désormais"]),
            hints: [], actionType: "tap", arrivedVia: "CONFIGURER", displayLabel: nil,
            screenshotBase64: "")
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "f", appName: "Horloge", screens: [source, arrived])
        XCTAssertFalse(yaml.contains("16:33"), yaml)
        XCTAssertTrue(yaml.contains("  - wait_for: \"Sommeil désormais\"\n"), yaml)
    }
}
