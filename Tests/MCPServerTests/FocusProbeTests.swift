// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for FocusProbe, FocusStats and the FocusObservingInput decorator over a scripted window server.
// ABOUTME: Pins how a focus steal, a raise and an unjudged action are told apart and summarized for `mirroir test`.

import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import mirroir_mcp

private let mirrorPID: pid_t = 100
private let terminalPID: pid_t = 200
private let browserPID: pid_t = 300

private func window(_ pid: pid_t, layer: Int = 0) -> WindowListEntry {
    WindowListEntry(windowID: CGWindowID(pid), ownerPID: pid, name: nil,
                    bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: layer)
}

/// A bridge whose window belongs to `pid`, or that has no window when nil.
private struct PIDBridge: WindowBridging {
    let targetName = "focus-probe"
    let pid: pid_t?

    func findProcess() -> NSRunningApplication? { nil }
    func getWindowInfo() -> WindowInfo? {
        pid.map { WindowInfo(windowID: 1, position: .zero,
                             size: CGSize(width: 100, height: 100), pid: $0) }
    }
    func getState() -> WindowState { .connected }
    func getOrientation() -> DeviceOrientation? { .portrait }
    func activate() {}
}

/// Hands out a scripted sequence of window lists, one per call; the last repeats.
private final class ScriptedWindowServer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[WindowListEntry]]

    init(_ frames: [[WindowListEntry]]) { self.frames = frames }

    func next() -> [WindowListEntry] {
        lock.withLock { frames.count > 1 ? frames.removeFirst() : frames[0] }
    }
}

final class FocusProbeTests: XCTestCase {

    // MARK: - FocusProbe

    func testSampleIgnoresHigherLayersForFrontmostAndDepth() {
        let entries = [window(browserPID, layer: 25), window(terminalPID), window(mirrorPID)]
        let sample = FocusProbe.sample(entries: entries, targetPID: mirrorPID)
        XCTAssertEqual(sample, FocusSample(frontmostPID: terminalPID, targetDepth: 1))
    }

    func testTakingTheFrontIsAFocusSteal() {
        let before = FocusSample(frontmostPID: terminalPID, targetDepth: 1)
        let after = FocusSample(frontmostPID: mirrorPID, targetDepth: 0)
        XCTAssertEqual(FocusProbe.interruption(before: before, after: after, targetPID: mirrorPID),
                       .stoleFocus)
    }

    func testMovingForwardWithoutTheFrontIsARaise() {
        let before = FocusSample(frontmostPID: terminalPID, targetDepth: 2)
        let after = FocusSample(frontmostPID: terminalPID, targetDepth: 1)
        XCTAssertEqual(FocusProbe.interruption(before: before, after: after, targetPID: mirrorPID),
                       .raised)
    }

    func testAppearingOnScreenIsARaise() {
        let before = FocusSample(frontmostPID: terminalPID, targetDepth: nil)
        let after = FocusSample(frontmostPID: terminalPID, targetDepth: 1)
        XCTAssertEqual(FocusProbe.interruption(before: before, after: after, targetPID: mirrorPID),
                       .raised)
    }

    func testAlreadyFrontmostTargetStaysClean() {
        let sample = FocusSample(frontmostPID: mirrorPID, targetDepth: 0)
        XCTAssertEqual(FocusProbe.interruption(before: sample, after: sample, targetPID: mirrorPID),
                       .clean)
    }

    func testUnchangedBackgroundTargetIsClean() {
        let sample = FocusSample(frontmostPID: terminalPID, targetDepth: 1)
        XCTAssertEqual(FocusProbe.interruption(before: sample, after: sample, targetPID: mirrorPID),
                       .clean)
    }

    // MARK: - FocusStats

    func testFreshStatsSummarizeToZero() {
        XCTAssertEqual(FocusStats().snapshot().summaryLine, "focus: actions=0 stole=0 raised=0")
    }

    func testSummaryBreaksDownStealsAndRaisesByKindInDeclarationOrder() {
        let stats = FocusStats()
        stats.record(.stoleFocus, kind: .type)
        stats.record(.stoleFocus, kind: .tap)
        stats.record(.stoleFocus, kind: .tap)
        stats.record(.raised, kind: .swipe)
        stats.record(.clean, kind: .tap)
        stats.record(.unmeasured, kind: .launch)
        XCTAssertEqual(
            stats.snapshot().summaryLine,
            "focus: actions=6 stole=3 raised=1 unmeasured=1 (stole: tap=2, type=1; raised: swipe=1)")
    }

    // MARK: - FocusObservingInput

    func testDecoratorRecordsAStealAndForwardsTheCall() {
        let server = ScriptedWindowServer([
            [window(terminalPID), window(mirrorPID)],
            [window(mirrorPID), window(terminalPID)],
        ])
        let stats = FocusStats()
        let stub = StubInput()
        let input = FocusObservingInput(wrapping: stub, bridge: PIDBridge(pid: mirrorPID),
                                        stats: stats, entries: { server.next() })

        XCTAssertNil(input.tap(x: 10, y: 20, cursorMode: nil))

        XCTAssertEqual(stub.tapCalls.count, 1)
        XCTAssertEqual(stub.tapCalls.first?.x, 10)
        XCTAssertEqual(stats.snapshot().stole, [.tap: 1])
    }

    func testDecoratorReturnsTheWrappedResultUnchanged() {
        let stub = StubInput()
        stub.typeTextResult = TypeResult(success: false, error: "keyboard lost")
        let input = FocusObservingInput(wrapping: stub, bridge: PIDBridge(pid: mirrorPID),
                                        stats: FocusStats(),
                                        entries: { [window(mirrorPID)] })
        let result = input.typeText("hello")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "keyboard lost")
        XCTAssertEqual(stub.typeCalls, ["hello"])
    }

    func testDecoratorCountsAnUnidentifiedTargetAsUnmeasured() {
        let stats = FocusStats()
        let input = FocusObservingInput(wrapping: StubInput(), bridge: PIDBridge(pid: nil),
                                        stats: stats, entries: { [window(terminalPID)] })
        _ = input.swipe(fromX: 0, fromY: 0, toX: 0, toY: 100, durationMs: 300, cursorMode: nil)
        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.actions, 1)
        XCTAssertEqual(snapshot.unmeasured, 1)
        XCTAssertTrue(snapshot.stole.isEmpty)
    }

    func testDecoratorLeavesAFrontmostTargetClean() {
        let stats = FocusStats()
        let input = FocusObservingInput(wrapping: StubInput(), bridge: PIDBridge(pid: mirrorPID),
                                        stats: stats,
                                        entries: { [window(mirrorPID), window(terminalPID)] })
        _ = input.pressKey(keyName: "return", modifiers: [])
        XCTAssertEqual(stats.snapshot().summaryLine, "focus: actions=1 stole=0 raised=0")
    }
}
