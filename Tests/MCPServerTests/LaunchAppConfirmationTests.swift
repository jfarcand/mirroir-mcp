// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests launch_app's confirmation that Spotlight closed, including the no-match case.
// ABOUTME: Uses OCR shapes captured on device: an empty Spotlight shows only "Q <query>" in its field.

import XCTest
@testable import mirroir_mcp
@testable import HelperLib

final class LaunchAppConfirmationTests: XCTestCase {

    private let height = 898.0

    private func point(_ text: String, y: Double) -> TapPoint {
        TapPoint(text: text, tapX: 200, tapY: y, confidence: 0.9)
    }

    private func screen(_ elements: [TapPoint]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(elements: elements, screenshotBase64: "img")
    }

    private func outcome(_ results: [ScreenDescriber.DescribeResult?], name: String) -> MCPToolResult {
        let describer = StubDescriber()
        describer.describeResults = results
        return LaunchAppConfirmation.outcome(
            appName: name, describer: describer, windowHeight: height, settleUs: 0, retryDelayUs: 0
        )
    }

    private func text(_ result: MCPToolResult) -> String {
        result.content.compactMap { part -> String? in
            if case .text(let value) = part { return value }
            return nil
        }.joined()
    }

    // MARK: - Search-field echo

    func testEchoWithGlyphAtBottomIsDetected() {
        let elements = [point("Q Maps", y: 830)]
        XCTAssertTrue(SpotlightDetector.isQueryEchoedInSearchField(elements: elements, query: "Maps", windowHeight: height))
    }

    func testTruncatedEchoIsDetected() {
        let elements = [point("Q MultiTouch-Visualize", y: 829)]
        XCTAssertTrue(SpotlightDetector.isQueryEchoedInSearchField(
            elements: elements, query: "MultiTouch-Visualizer", windowHeight: height))
    }

    func testQueryTextHigherOnScreenIsNotAnEcho() {
        let elements = [point("Maps", y: 300)]
        XCTAssertFalse(SpotlightDetector.isQueryEchoedInSearchField(elements: elements, query: "Maps", windowHeight: height))
    }

    func testAppSearchBarWithOtherWordsIsNotAnEcho() {
        let elements = [point("Search Maps", y: 830)]
        XCTAssertFalse(SpotlightDetector.isQueryEchoedInSearchField(elements: elements, query: "Maps", windowHeight: height))
    }

    func testSingleGlyphNeverCountsAsEcho() {
        let elements = [point("Q", y: 830)]
        XCTAssertFalse(SpotlightDetector.isQueryEchoedInSearchField(elements: elements, query: "Maps", windowHeight: height))
    }

    // MARK: - Outcome

    func testSpotlightGoneReportsLaunched() {
        let result = outcome([screen([point("Rue de la Seve", y: 500)])], name: "Waze")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(text(result), "Launched 'Waze' via Spotlight")
    }

    func testSpotlightStuckWithEchoReportsError() {
        let stuck = screen([point("Q Maps", y: 830)])
        let result = outcome([stuck], name: "Maps")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(text(result).contains("Spotlight is still open"))
    }

    func testSpotlightClosingOnALaterPollReportsLaunched() {
        let stuck = screen([point("Top Hit", y: 200)])
        let open = screen([point("Photos", y: 120)])
        let result = outcome([stuck, stuck, open], name: "Photos")
        XCTAssertFalse(result.isError)
    }

    func testUnreadableScreenIsNotClaimedAsConfirmed() {
        let result = outcome([nil], name: "Maps")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(text(result).contains("not confirmed"))
    }

    func testMissingWindowIsNotClaimedAsConfirmed() {
        let result = LaunchAppConfirmation.outcome(
            appName: "Maps", describer: StubDescriber(), windowHeight: nil, settleUs: 0, retryDelayUs: 0)
        XCTAssertTrue(text(result).contains("not confirmed"))
    }
}
