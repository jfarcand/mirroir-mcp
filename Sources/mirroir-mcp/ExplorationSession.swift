// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Thread-safe session accumulator for the generate_skill exploration workflow.
// ABOUTME: Tracks explored screens with OCR elements, screenshots, and navigation context.

import Foundation
import HelperLib

/// A single screen captured during app exploration.
struct ExploredScreen: Sendable {
    /// Zero-based index within the exploration session.
    let index: Int
    /// OCR-detected text elements with tap coordinates.
    let elements: [TapPoint]
    /// Contextual hints from the screen describer (e.g. navigation cues).
    let hints: [String]
    /// The action performed to reach this screen (e.g. "tap", "swipe", "type", "press_key").
    let actionType: String?
    /// The element label or value associated with the action (e.g. "General", "up", "hello").
    let arrivedVia: String?
    /// Base64-encoded PNG screenshot of the screen.
    let screenshotBase64: String
}

/// Thread-safe accumulator for the generate_skill session-based workflow.
/// Same pattern as `CompilationSession` in CompilationTools.swift.
final class ExplorationSession: @unchecked Sendable {
    private var screens: [ExploredScreen] = []
    private var appName: String = ""
    private var goal: String = ""
    private var isActive: Bool = false
    private let lock = NSLock()

    /// Begin a new exploration session, resetting any prior state.
    func start(appName: String, goal: String) {
        lock.lock()
        defer { lock.unlock() }
        screens = []
        self.appName = appName
        self.goal = goal
        isActive = true
    }

    /// Append a captured screen to the session.
    /// Returns `false` if the screen is a duplicate of the last captured screen (unchanged).
    @discardableResult
    func capture(
        elements: [TapPoint],
        hints: [String],
        actionType: String?,
        arrivedVia: String?,
        screenshotBase64: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Reject duplicate: compare against last captured screen
        if let lastScreen = screens.last,
           ScreenFingerprint.areEqual(lastScreen.elements, elements) {
            return false
        }

        let screen = ExploredScreen(
            index: screens.count,
            elements: elements,
            hints: hints,
            actionType: actionType,
            arrivedVia: arrivedVia,
            screenshotBase64: screenshotBase64
        )
        screens.append(screen)
        return true
    }

    /// Finalize the session: return all captured data and reset state.
    /// Returns `nil` if the session was not active.
    func finalize() -> (appName: String, goal: String, screens: [ExploredScreen])? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        let result = (appName: appName, goal: goal, screens: screens)
        screens = []
        appName = ""
        goal = ""
        isActive = false
        return result
    }

    /// Whether an exploration session is currently active.
    var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }

    /// Number of screens captured so far.
    var screenCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return screens.count
    }

    /// The app name for the current session (empty if inactive).
    var currentAppName: String {
        lock.lock()
        defer { lock.unlock() }
        return appName
    }

    /// The goal for the current session (empty if inactive).
    var currentGoal: String {
        lock.lock()
        defer { lock.unlock() }
        return goal
    }
}
