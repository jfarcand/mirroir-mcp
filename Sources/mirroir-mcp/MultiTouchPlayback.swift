// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Business logic of the multi_touch tool: held-touch refusal, backend URL, window-to-device mapping, playback.
// ABOUTME: Keeps one MultiTouchProviding per runner URL so its WebDriverAgent session is reused across calls.

import CoreGraphics
import Foundation
import HelperLib

/// Why a multi_touch call was refused or failed.
enum MultiTouchError: Error, Equatable, CustomStringConvertible {
    /// A persistent `touch` contact is held; carries the shared refusal text.
    case touchHeld(String)
    /// No runner URL in the call, the settings, or the environment.
    case notConfigured
    /// The runner URL is not an http(s) URL with a host.
    case invalidURL(String)
    /// The target's window could not be found, so its coordinates mean nothing.
    case windowNotFound(target: String)
    /// The runner is reachable but says it cannot take commands.
    case backendNotReady(message: String?)
    case validation(MultiTouchValidationError)
    case mapping(MultiTouchMappingError)
    case backend(WebDriverAgentError)

    var description: String {
        switch self {
        case .touchHeld(let refusal):
            return refusal
        case .notConfigured:
            return "multi_touch needs a WebDriverAgent runner on the iPhone (iOS 26: the only way "
                + "to inject independent fingers). Install and launch WebDriverAgentRunner, then set "
                + "MIRROIR_WDA_URL (or \"wdaURL\" in settings.json) to its URL, e.g. "
                + "http://<iphone-ip>:8100, or pass wda_url. Setup: "
                + "docs/tools.md#multi-finger-touches-on-ios-26-webdriveragent"
        case .invalidURL(let url):
            return "'\(url)' is not a WebDriverAgent URL; expected http://<iphone-ip>:8100."
        case .windowNotFound(let target):
            return "Target '\(target)' window not found: multi_touch coordinates are relative to "
                + "the mirroring window, like tap, so the window must be open."
        case .backendNotReady(let message):
            return "WebDriverAgent is running but not ready" + (message.map { ": \($0)" } ?? ".")
        case .validation(let error): return error.description
        case .mapping(let error): return error.description
        case .backend(let error): return error.description
        }
    }
}

/// Plays a multi_touch call: refuses while a `touch` contact is held (both
/// drive the same screen, and a held Mirroring touch would sit under the
/// gesture), resolves the runner URL, validates the fingers in the window's
/// coordinates, maps them to device points, and has the backend play them.
///
/// One backend is kept per runner URL, so its WebDriverAgent session lasts
/// across calls; asking for a different URL replaces it.
final class MultiTouchPlayback: @unchecked Sendable {
    /// Name of the tool this playback serves, used in the held-touch refusal.
    static let toolName = "multi_touch"

    /// The playback the server uses: the shared touch session, the configured
    /// runner URL, and a WebDriverAgent client per URL.
    static let shared = MultiTouchPlayback(
        touchSession: .shared,
        configuredURL: { EnvConfig.wdaURL },
        makeProvider: { WebDriverAgentClient(baseURL: $0) })

    private let touchSession: TouchSession
    private let configuredURL: @Sendable () -> String
    private let makeProvider: @Sendable (URL) -> any MultiTouchProviding
    private let lock = NSLock()
    private var cached: (url: URL, provider: any MultiTouchProviding, status: MultiTouchBackendStatus)?

    init(touchSession: TouchSession,
         configuredURL: @escaping @Sendable () -> String,
         makeProvider: @escaping @Sendable (URL) -> any MultiTouchProviding) {
        self.touchSession = touchSession
        self.configuredURL = configuredURL
        self.makeProvider = makeProvider
    }

    /// Play `timelines`, written in `window`'s coordinates, through the
    /// runner at `urlOverride` or the configured one.
    func play(_ timelines: [FingerTimeline], window: WindowInfo?, targetName: String,
              urlOverride: String?) -> Result<MultiTouchPlayed, MultiTouchError> {
        if let refusal = touchSession.heldRefusal(tool: Self.toolName) {
            return .failure(.touchHeld(refusal))
        }
        do throws(MultiTouchError) {
            let url = try runnerURL(override: urlOverride)
            guard let window else { throw .windowNotFound(target: targetName) }
            let requested = try validated(timelines, bounds: window.size)
            let (provider, status) = try backend(for: url)
            let device = try backendCall { () throws(WebDriverAgentError) in try provider.viewportSize() }
            let mapped: [FingerTimeline]
            do {
                mapped = try MultiTouchCoordinateMapper.map(requested.timelines, window: window.size,
                                                            device: device)
            } catch {
                throw .mapping(error)
            }
            let gesture = try validated(mapped, bounds: device)
            let report = try backendCall { () throws(WebDriverAgentError) in try provider.perform(gesture) }
            return .success(MultiTouchPlayed(requested: requested, report: report,
                                             runnerURL: url, osVersion: status.osVersion))
        } catch {
            return .failure(error)
        }
    }

    /// The runner URL: the call's own, else the configured one.
    private func runnerURL(override: String?) throws(MultiTouchError) -> URL {
        let raw = (override ?? configuredURL()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw .notConfigured }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
            throw .invalidURL(raw)
        }
        return url
    }

    /// The backend for `url` and its status, asking a new backend for its
    /// status once and refusing it when it is not ready.
    private func backend(for url: URL) throws(MultiTouchError) -> (any MultiTouchProviding, MultiTouchBackendStatus) {
        if let cached = lock.withLock({ cached }), cached.url == url {
            return (cached.provider, cached.status)
        }
        let provider = makeProvider(url)
        let status = try backendCall { () throws(WebDriverAgentError) in try provider.status() }
        guard status.ready else { throw .backendNotReady(message: status.message) }
        lock.withLock { cached = (url, provider, status) }
        return (provider, status)
    }

    private func validated(_ timelines: [FingerTimeline],
                           bounds: CGSize) throws(MultiTouchError) -> MultiTouchGesture {
        do {
            return try MultiTouchGesture(timelines: timelines, bounds: bounds)
        } catch {
            throw .validation(error)
        }
    }

    private func backendCall<T>(
        _ call: () throws(WebDriverAgentError) -> T
    ) throws(MultiTouchError) -> T {
        do {
            return try call()
        } catch {
            throw .backend(error)
        }
    }
}

/// A played multi_touch call: the gesture as requested in window points, and
/// the backend's report of what it played in device points.
struct MultiTouchPlayed: Sendable, Equatable {
    let requested: MultiTouchGesture
    let report: MultiTouchReport
    let runnerURL: URL
    let osVersion: String?
}
