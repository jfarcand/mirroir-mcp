// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the display-awake hold: one assertion for overlapping runs, released by the last one, off by setting.
// ABOUTME: A counting fake stands in for IOKit, plus one round trip through the real assertion API.

import Foundation
import os
import XCTest
@testable import mirroir_mcp

/// Counts assertions instead of keeping the test Mac's display awake.
private final class CountingAsserter: DisplayAwakeAsserting, @unchecked Sendable {
    let state = OSAllocatedUnfairLock(initialState: (taken: [String](), released: [UInt32]()))
    var refuses = false

    func assertAwake(reason: String) -> UInt32? {
        if refuses { return nil }
        return state.withLock {
            $0.taken.append(reason)
            return UInt32($0.taken.count)
        }
    }

    func release(_ assertion: UInt32) {
        state.withLock { $0.released.append(assertion) }
    }
}

final class DisplayAwakeTests: XCTestCase {

    func testOverlappingRunsShareOneAssertionReleasedByTheLast() {
        let asserter = CountingAsserter()
        let hold = DisplayAwake(asserter: asserter, enabled: { true })
        hold.enter(reason: "mirroir-mcp test")
        hold.enter(reason: "mirroir-mcp start_recording")
        XCTAssertTrue(hold.isHeld)
        hold.leave()
        XCTAssertTrue(hold.isHeld, "the recording still runs")
        hold.leave()
        XCTAssertFalse(hold.isHeld)
        XCTAssertEqual(asserter.state.withLock { $0.taken }, ["mirroir-mcp test"])
        XCTAssertEqual(asserter.state.withLock { $0.released }, [1])
        hold.leave()
        XCTAssertEqual(asserter.state.withLock { $0.released }, [1], "an extra leave releases nothing")
    }

    func testDuringHoldsForTheBodyAndReleasesOnAThrow() {
        struct Failure: Error {}
        let asserter = CountingAsserter()
        let hold = DisplayAwake(asserter: asserter, enabled: { true })
        let held = hold.during("mirroir-mcp run_steps") { hold.isHeld }
        XCTAssertTrue(held)
        XCTAssertThrowsError(try hold.during("mirroir-mcp tap") { throw Failure() })
        XCTAssertFalse(hold.isHeld)
        XCTAssertEqual(asserter.state.withLock { $0.released }, [1, 2])
    }

    func testTurnedOffItAssertsNothing() {
        let asserter = CountingAsserter()
        let hold = DisplayAwake(asserter: asserter, enabled: { false })
        hold.during("mirroir-mcp test") {}
        XCTAssertEqual(asserter.state.withLock { $0.taken }, [])
    }

    func testARefusedAssertionIsRetriedByTheNextRun() {
        let asserter = CountingAsserter()
        asserter.refuses = true
        let hold = DisplayAwake(asserter: asserter, enabled: { true })
        hold.during("first") { XCTAssertFalse(hold.isHeld) }
        asserter.refuses = false
        hold.during("second") { XCTAssertTrue(hold.isHeld) }
    }

    /// The real IOKit assertion is taken and released.
    func testTheIOKitAssertionRoundTrips() throws {
        let live = IOPMDisplayAwake()
        let id = try XCTUnwrap(live.assertAwake(reason: "mirroir-mcp unit test"))
        live.release(id)
    }
}
