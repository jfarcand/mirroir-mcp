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
// ABOUTME: Tests the point-tap report: reads around the tap, the unchanged-screen note, and a tap that fails.
// ABOUTME: The reads and the tap are closures; the real check is a close ✕ tapped on a device (carnet#91).

import HelperLib
import XCTest
@testable import mirroir_mcp

final class PointTapReportTests: XCTestCase {

    private func read(_ texts: [String]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.enumerated().map { TapPoint(text: $1, tapX: 100, tapY: Double(100 + $0 * 40),
                                                         confidence: 0.99) },
            screenshotBase64: "")
    }

    func testTheScreenIsReadBeforeTheTapAndAfterTheWait() {
        var events: [String] = []
        _ = PointTapReport.run(
            described: "Tapped at (198, 56)", tapped: "the point (198, 56)",
            read: { events.append("read"); return self.read(["Share"]) },
            tap: { events.append("tap"); return nil },
            wait: { events.append("wait") })
        XCTAssertEqual(events, ["read", "tap", "wait", "read"])
    }

    func testATapThatFailsIsReportedAndNotReadAfter() {
        var reads = 0
        let outcome = PointTapReport.run(
            described: "Tapped at (1, 1)", tapped: "the point (1, 1)",
            read: { reads += 1; return self.read(["Share"]) },
            tap: { "the window is gone" }, wait: { XCTFail("no wait after a failed tap") })
        XCTAssertEqual(outcome, .failure(PointTapError(message: "the window is gone")))
        XCTAssertEqual(reads, 1)
    }

    /// A screen with no text (a game, a photo) cannot show that nothing changed.
    func testAScreenWithNoTextGetsNoNote() {
        let reply = PointTapReport.reply(described: "Tapped at (10, 10)", tapped: "the point (10, 10)",
                                         before: read([]), after: read([]))
        XCTAssertEqual(reply, "Tapped at (10, 10)\n\nScreen now: ")
    }

    func testNoReadBeforeMeansNoNote() {
        let reply = PointTapReport.reply(described: "Tapped at (10, 10)", tapped: "the point (10, 10)",
                                         before: nil, after: read(["Copy Link", "AirDrop"]))
        XCTAssertFalse(reply.contains("read the same"), reply)
        XCTAssertTrue(reply.hasSuffix("Screen now: Copy Link AirDrop"), reply)
    }

    func testNoReadAfterLeavesTheTapLineAlone() {
        XCTAssertEqual(PointTapReport.reply(described: "Tapped at (10, 10)", tapped: "the point (10, 10)",
                                            before: read(["Share"]), after: nil),
                       "Tapped at (10, 10)")
    }
}
