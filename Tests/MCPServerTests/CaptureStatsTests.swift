// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for CaptureStats and ScreenCapture's accounting of ScreenCaptureKit vs CLI-fallback captures.
// ABOUTME: Pins the `capture: sck=N fallback=M` summary line `mirroir test` prints for CI to assert on.

import CoreGraphics
import Foundation
import XCTest
@testable import mirroir_mcp

/// A provider that always answers with the same reply.
private struct FixedProvider: WindowImageProviding {
    let reply: WindowImageReply

    func captureWindowImage(
        windowID: CGWindowID, reply: @escaping @Sendable (WindowImageReply) -> Void
    ) {
        reply(self.reply)
    }
}

/// A bridge with a fixed window that records activation, which only the
/// `screencapture` CLI fallback performs.
private final class ActivationRecordingBridge: WindowBridging, @unchecked Sendable {
    let targetName = "capture-stats"
    private let windowID: CGWindowID
    private let lock = NSLock()
    private var activations = 0

    init(windowID: CGWindowID) {
        self.windowID = windowID
    }

    var activationCount: Int { lock.withLock { activations } }

    func findProcess() -> NSRunningApplication? { nil }
    func getWindowInfo() -> WindowInfo? {
        // A 1x1 region keeps the CLI fallback's region capture trivial.
        WindowInfo(windowID: windowID, position: .zero,
                   size: CGSize(width: 1, height: 1), pid: 0)
    }
    func getState() -> WindowState { .connected }
    func getOrientation() -> DeviceOrientation? { .portrait }
    func activate() { lock.withLock { activations += 1 } }
}

final class CaptureStatsTests: XCTestCase {

    func testFreshStatsSummarizeToZero() {
        let line = CaptureStats().snapshot().summaryLine
        XCTAssertEqual(line, "capture: sck=0 fallback=0")
    }

    func testSummaryListsFallbackReasonsInDeclarationOrder() {
        let stats = CaptureStats()
        stats.recordSCK()
        stats.recordSCK()
        stats.recordFallback(.timedOut)
        stats.recordFallback(.handlerDropped)
        stats.recordFallback(.handlerDropped)

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.sck, 2)
        XCTAssertEqual(snapshot.fallback, 3)
        XCTAssertEqual(snapshot.summaryLine,
                       "capture: sck=2 fallback=3 (handler_dropped=2, timeout=1)")
    }

    func testScreenCaptureKitImageCountsAsSCKWithoutActivation() {
        let stats = CaptureStats()
        let bridge = ActivationRecordingBridge(windowID: 7)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let capture = ScreenCapture(
            bridge: bridge, windowImages: FixedProvider(reply: .image(png)), stats: stats)

        let result = capture.captureWithInfo()

        XCTAssertEqual(result?.data, png)
        XCTAssertEqual(stats.snapshot(), CaptureStatsSnapshot(sck: 1, fallbackReasons: [:]))
        XCTAssertEqual(bridge.activationCount, 0, "an SCK capture never steals focus")
    }

    func testScreenCaptureKitFailureCountsAsFallbackAndActivates() {
        let stats = CaptureStats()
        let bridge = ActivationRecordingBridge(windowID: 7)
        let capture = ScreenCapture(
            bridge: bridge, windowImages: FixedProvider(reply: .windowNotShareable), stats: stats)

        _ = capture.captureWithInfo()

        XCTAssertEqual(stats.snapshot(),
                       CaptureStatsSnapshot(sck: 0, fallbackReasons: [.windowNotShareable: 1]))
        XCTAssertEqual(bridge.activationCount, 1, "the CLI fallback activates the target")
    }

    func testMissingWindowIDSkipsScreenCaptureKitAndCountsFallback() {
        let stats = CaptureStats()
        let bridge = ActivationRecordingBridge(windowID: 0)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let capture = ScreenCapture(
            bridge: bridge, windowImages: FixedProvider(reply: .image(png)), stats: stats)

        _ = capture.captureWithInfo()

        XCTAssertEqual(stats.snapshot(),
                       CaptureStatsSnapshot(sck: 0, fallbackReasons: [.noWindowID: 1]))
    }
}
