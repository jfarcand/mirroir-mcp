// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: One-shot ScreenCaptureKit capture of a single window by CGWindowID, as PNG data.
// ABOUTME: Grabs the window regardless of Space or occlusion, so capture needs no activation (no focus steal).

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Why a window shot produced no image, so the caller falls back to the
/// `screencapture` CLI. The raw value is the name the capture summary prints.
enum WindowShotFailure: String, Sendable, CaseIterable {
    /// The window has no `CGWindowID`, so ScreenCaptureKit cannot address it.
    case noWindowID = "no_window_id"
    /// The window is not in ScreenCaptureKit's shareable content.
    case windowNotShareable = "not_shareable"
    /// ScreenCaptureKit returned an error.
    case captureError = "error"
    /// ScreenCaptureKit released its completion handler without calling it.
    /// `replayd` keys capture clients by executable path, so two live processes
    /// of the same binary (the MCP server and a `mirroir-mcp test` run) keep
    /// interrupting each other's connection; the interrupted request's handler
    /// is released unanswered (ReplayKit error 4097).
    case handlerDropped = "handler_dropped"
    /// No answer arrived within `ScreenCaptureKitShot.timeout`.
    case timedOut = "timeout"
}

/// The result of one window shot.
enum WindowShotOutcome: Sendable {
    case captured(Data)
    case unavailable(WindowShotFailure)
}

/// Captures a single window by its `CGWindowID` through a `WindowImageProviding`
/// (ScreenCaptureKit in production).
///
/// `SCScreenshotManager.captureImage` (macOS 14+) reaches a window on any Space,
/// occluded or not, without bringing it forward — unlike the `screencapture` CLI,
/// which only sees the current Space and so forces an activation that steals the
/// user's focus.
///
/// The provider's completion API is bridged to the synchronous capture path
/// with a semaphore and no Swift concurrency in between. A provider that
/// releases the completion without calling it — what a `mirroir test` run hits
/// while an MCP server of the same binary is live (see `.handlerDropped`) — is
/// detected the moment the closure is released (`ReplySentinel`), so that case
/// returns at once instead of waiting out `timeout`. The timeout bounds only a provider
/// that keeps the request alive and never answers.
enum ScreenCaptureKitShot {

    /// How long to wait for a provider that holds the request but never answers.
    static let timeout: DispatchTimeInterval = .seconds(10)

    /// Capture the window with `windowID`, or say why no image was produced.
    static func capture(
        windowID: CGWindowID,
        provider: any WindowImageProviding = ScreenCaptureKitProvider(),
        timeout: DispatchTimeInterval = timeout
    ) -> WindowShotOutcome {
        let latch = ShotLatch()
        // The sentinel lives only in the closure's capture list: when the
        // provider releases the closure, the sentinel goes with it.
        provider.captureWindowImage(windowID: windowID) {
            [sentinel = ReplySentinel(latch: latch)] reply in
            sentinel.deliver(reply)
        }
        let outcome = latch.wait(timeout: timeout)
        if case .unavailable(let failure) = outcome {
            DebugLog.log("ScreenCaptureKitShot",
                "no image for window \(windowID): \(failure.rawValue)")
        }
        return outcome
    }
}

/// Production `WindowImageProviding`: ScreenCaptureKit's completion-handler API.
struct ScreenCaptureKitProvider: WindowImageProviding {

    func captureWindowImage(
        windowID: CGWindowID, reply: @escaping @Sendable (WindowImageReply) -> Void
    ) {
        SCShareableContent.getExcludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ) { content, error in
            guard let content else {
                reply(.failed(error.map { "\($0)" } ?? "no shareable content"))
                return
            }
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                reply(.windowNotShareable)
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            ) { image, error in
                guard let image, let png = Self.png(from: image) else {
                    reply(.failed(error.map { "\($0)" } ?? "no image"))
                    return
                }
                reply(.image(png))
            }
        }
    }

    /// Encode a `CGImage` as PNG, matching the `screencapture` output format.
    private static func png(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// One-shot result slot the capturing thread waits on. The first resolution
/// wins; later ones (a reply after a timeout, the sentinel after a reply) are
/// ignored.
private final class ShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: WindowShotOutcome?

    func resolve(_ value: WindowShotOutcome) {
        let first: Bool = lock.withLock {
            guard outcome == nil else { return false }
            outcome = value
            return true
        }
        if first { semaphore.signal() }
    }

    func wait(timeout: DispatchTimeInterval) -> WindowShotOutcome {
        _ = semaphore.wait(timeout: .now() + timeout)
        return lock.withLock {
            if let outcome { return outcome }
            outcome = .unavailable(.timedOut)
            return .unavailable(.timedOut)
        }
    }
}

/// Rides inside the reply closure handed to the provider. Delivering a reply
/// resolves the latch; being deallocated without one means the provider
/// released the closure unanswered, which resolves it as `.handlerDropped`.
private final class ReplySentinel: @unchecked Sendable {
    private let latch: ShotLatch

    init(latch: ShotLatch) {
        self.latch = latch
    }

    func deliver(_ reply: WindowImageReply) {
        switch reply {
        case .image(let data): latch.resolve(.captured(data))
        case .windowNotShareable: latch.resolve(.unavailable(.windowNotShareable))
        case .failed(let message):
            DebugLog.log("ScreenCaptureKitShot", "capture failed: \(message)")
            latch.resolve(.unavailable(.captureError))
        }
    }

    deinit {
        latch.resolve(.unavailable(.handlerDropped))
    }
}
