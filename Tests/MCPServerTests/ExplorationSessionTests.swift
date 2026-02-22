// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ExplorationSession lifecycle: start, capture, finalize, and active flags.
// ABOUTME: Verifies thread-safe accumulation and state transitions for the generate_skill workflow.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ExplorationSessionTests: XCTestCase {

    // MARK: - Start and Capture

    func testStartAndCapture() {
        let session = ExplorationSession()

        XCTAssertFalse(session.active)
        XCTAssertEqual(session.screenCount, 0)

        session.start(appName: "Settings", goal: "check version")

        XCTAssertTrue(session.active)
        XCTAssertEqual(session.currentAppName, "Settings")
        XCTAssertEqual(session.currentGoal, "check version")
        XCTAssertEqual(session.screenCount, 0)

        session.capture(
            elements: [TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95)],
            hints: ["Navigation bar detected"],
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: "base64screenshot1"
        )

        XCTAssertEqual(session.screenCount, 1)
    }

    // MARK: - Finalize Returns Screens In Order

    func testFinalizeReturnsScreensInOrder() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "explore")

        session.capture(
            elements: [TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95)],
            hints: [],
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: "screen0"
        )
        session.capture(
            elements: [TapPoint(text: "About", tapX: 205, tapY: 400, confidence: 0.92)],
            hints: [],
            actionType: "tap",
            arrivedVia: "General",
            screenshotBase64: "screen1"
        )
        session.capture(
            elements: [TapPoint(text: "iOS Version", tapX: 205, tapY: 300, confidence: 0.88)],
            hints: [],
            actionType: "tap",
            arrivedVia: "About",
            screenshotBase64: "screen2"
        )

        let data = session.finalize()
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.screens.count, 3)
        XCTAssertEqual(data?.screens[0].index, 0)
        XCTAssertEqual(data?.screens[1].index, 1)
        XCTAssertEqual(data?.screens[2].index, 2)
        XCTAssertEqual(data?.screens[0].screenshotBase64, "screen0")
        XCTAssertEqual(data?.screens[1].arrivedVia, "General")
        XCTAssertEqual(data?.screens[1].actionType, "tap")
        XCTAssertEqual(data?.screens[2].arrivedVia, "About")
        XCTAssertEqual(data?.screens[2].actionType, "tap")
        XCTAssertEqual(data?.appName, "Settings")
        XCTAssertEqual(data?.goal, "explore")
    }

    // MARK: - Finalize Clears State

    func testFinalizeClearsState() {
        let session = ExplorationSession()
        session.start(appName: "Maps", goal: "search")

        session.capture(
            elements: [TapPoint(text: "Search", tapX: 100, tapY: 150, confidence: 0.9)],
            hints: [],
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: "img"
        )

        let data = session.finalize()
        XCTAssertNotNil(data)

        // Session should be inactive after finalize
        XCTAssertFalse(session.active)
        XCTAssertEqual(session.screenCount, 0)
        XCTAssertEqual(session.currentAppName, "")
        XCTAssertEqual(session.currentGoal, "")

        // Second finalize returns nil
        let secondFinalize = session.finalize()
        XCTAssertNil(secondFinalize)
    }

    // MARK: - Active Flags

    func testActiveFlags() {
        let session = ExplorationSession()

        XCTAssertFalse(session.active, "Session should be inactive before start")

        session.start(appName: "Notes", goal: "")
        XCTAssertTrue(session.active, "Session should be active after start")

        _ = session.finalize()
        XCTAssertFalse(session.active, "Session should be inactive after finalize")
    }

    // MARK: - Start Resets Previous Session

    func testStartResetsExistingSession() {
        let session = ExplorationSession()
        session.start(appName: "OldApp", goal: "old goal")

        session.capture(
            elements: [TapPoint(text: "Old Screen", tapX: 100, tapY: 100, confidence: 0.9)],
            hints: [],
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: "old"
        )

        XCTAssertEqual(session.screenCount, 1)

        // Starting a new session resets the old one
        session.start(appName: "NewApp", goal: "new goal")
        XCTAssertEqual(session.currentAppName, "NewApp")
        XCTAssertEqual(session.currentGoal, "new goal")
        XCTAssertEqual(session.screenCount, 0)
        XCTAssertTrue(session.active)
    }

    // MARK: - Duplicate Screen Rejection

    func testCaptureDuplicateScreenIsRejected() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "test dedup")

        let elements = [
            TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95),
            TapPoint(text: "Privacy", tapX: 205, tapY: 400, confidence: 0.93),
        ]

        let first = session.capture(
            elements: elements, hints: [], actionType: nil,
            arrivedVia: nil, screenshotBase64: "img1")
        XCTAssertTrue(first, "First capture should be accepted")
        XCTAssertEqual(session.screenCount, 1)

        let second = session.capture(
            elements: elements, hints: [], actionType: "tap",
            arrivedVia: "General", screenshotBase64: "img2")
        XCTAssertFalse(second, "Duplicate screen should be rejected")
        XCTAssertEqual(session.screenCount, 1, "Count should not increase on duplicate")
    }

    func testCaptureDifferentScreenIsAccepted() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "test dedup")

        let first = session.capture(
            elements: [TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95)],
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "img1")
        XCTAssertTrue(first)

        let second = session.capture(
            elements: [TapPoint(text: "About", tapX: 205, tapY: 400, confidence: 0.92)],
            hints: [], actionType: "tap", arrivedVia: "General", screenshotBase64: "img2")
        XCTAssertTrue(second, "Different screen should be accepted")
        XCTAssertEqual(session.screenCount, 2)
    }

    func testCaptureDuplicateAfterDifferentIsRejected() {
        let session = ExplorationSession()
        session.start(appName: "Settings", goal: "test dedup")

        let elementsA = [TapPoint(text: "General", tapX: 205, tapY: 340, confidence: 0.95)]
        let elementsB = [TapPoint(text: "About", tapX: 205, tapY: 400, confidence: 0.92)]

        session.capture(
            elements: elementsA, hints: [], actionType: nil,
            arrivedVia: nil, screenshotBase64: "img1")
        session.capture(
            elements: elementsB, hints: [], actionType: "tap",
            arrivedVia: "General", screenshotBase64: "img2")

        let duplicate = session.capture(
            elements: elementsB, hints: [], actionType: "tap",
            arrivedVia: "About", screenshotBase64: "img3")
        XCTAssertFalse(duplicate, "B after B should be rejected")
        XCTAssertEqual(session.screenCount, 2, "Count should stay at 2")
    }
}
