// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ScreenCaptureKitShot's completion bridge: reply, dropped handler, timeout, late reply.
// ABOUTME: Pins that a provider releasing its completion unanswered returns at once instead of stalling.

import CoreGraphics
import Foundation
import XCTest
@testable import mirroir_mcp

/// How a scripted provider treats the reply closure it is handed. The real
/// ScreenCaptureKit is replaced because the failure under test — the framework
/// releasing its completion handler without calling it — cannot be provoked on
/// demand from the real API.
private enum ProviderScript {
    /// Call the reply on the calling thread.
    case replyNow(WindowImageReply)
    /// Call the reply from a background queue after a delay.
    case replyLater(WindowImageReply, delayMs: Int)
    /// Release the reply without ever calling it, synchronously.
    case dropNow
    /// Hold the reply on a background queue for a while, then release it uncalled.
    case dropLater(delayMs: Int)
    /// Keep the reply alive and never call it until `release()`.
    case hold
}

private final class ScriptedProvider: WindowImageProviding, @unchecked Sendable {
    private let script: ProviderScript
    private let lock = NSLock()
    private var held: (@Sendable (WindowImageReply) -> Void)?

    init(_ script: ProviderScript) {
        self.script = script
    }

    func captureWindowImage(
        windowID: CGWindowID, reply: @escaping @Sendable (WindowImageReply) -> Void
    ) {
        switch script {
        case .replyNow(let value):
            reply(value)
        case .replyLater(let value, let delayMs):
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                reply(value)
            }
        case .dropNow:
            break
        case .dropLater(let delayMs):
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                _ = reply
            }
        case .hold:
            lock.withLock { held = reply }
        }
    }

    /// Answer a held request late, after the caller has given up.
    func answerHeld(_ value: WindowImageReply) {
        let reply = lock.withLock { () -> (@Sendable (WindowImageReply) -> Void)? in
            defer { held = nil }
            return held
        }
        reply?(value)
    }
}

final class ScreenCaptureKitShotTests: XCTestCase {

    private let png = Data([0x89, 0x50, 0x4E, 0x47])
    private let windowID: CGWindowID = 42

    private func capture(
        _ provider: ScriptedProvider, timeout: DispatchTimeInterval = .seconds(5)
    ) -> (WindowShotOutcome, TimeInterval) {
        let start = Date()
        let outcome = ScreenCaptureKitShot.capture(
            windowID: windowID, provider: provider, timeout: timeout)
        return (outcome, Date().timeIntervalSince(start))
    }

    private func failure(of outcome: WindowShotOutcome) -> WindowShotFailure? {
        if case .unavailable(let reason) = outcome { return reason }
        return nil
    }

    func testImmediateReplyIsCaptured() {
        let (outcome, _) = capture(ScriptedProvider(.replyNow(.image(png))))
        guard case .captured(let data) = outcome else {
            return XCTFail("expected captured, got \(outcome)")
        }
        XCTAssertEqual(data, png)
    }

    func testReplyFromAnotherQueueIsCaptured() {
        let (outcome, _) = capture(ScriptedProvider(.replyLater(.image(png), delayMs: 50)))
        guard case .captured(let data) = outcome else {
            return XCTFail("expected captured, got \(outcome)")
        }
        XCTAssertEqual(data, png)
    }

    func testWindowNotShareableIsReported() {
        let (outcome, _) = capture(ScriptedProvider(.replyNow(.windowNotShareable)))
        XCTAssertEqual(failure(of: outcome), .windowNotShareable)
    }

    func testProviderErrorIsReported() {
        let (outcome, _) = capture(ScriptedProvider(.replyNow(.failed("no permission"))))
        XCTAssertEqual(failure(of: outcome), .captureError)
    }

    /// The carnet#24 shape: the provider releases its completion without
    /// calling it. The caller must learn that at once, not after `timeout`.
    func testDroppedHandlerReturnsImmediately() {
        let (outcome, elapsed) = capture(ScriptedProvider(.dropNow), timeout: .seconds(10))
        XCTAssertEqual(failure(of: outcome), .handlerDropped)
        XCTAssertLessThan(elapsed, 1.0, "a dropped handler must not wait out the timeout")
    }

    func testHandlerDroppedLaterOnAnotherQueueReturnsWhenReleased() {
        let (outcome, elapsed) = capture(
            ScriptedProvider(.dropLater(delayMs: 100)), timeout: .seconds(10))
        XCTAssertEqual(failure(of: outcome), .handlerDropped)
        XCTAssertLessThan(elapsed, 2.0, "release of the handler ends the wait, not the timeout")
    }

    func testHeldRequestTimesOut() {
        let provider = ScriptedProvider(.hold)
        let (outcome, elapsed) = capture(provider, timeout: .milliseconds(200))
        XCTAssertEqual(failure(of: outcome), .timedOut)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        // A reply after the caller gave up is ignored and does not crash.
        provider.answerHeld(.image(png))
    }
}
