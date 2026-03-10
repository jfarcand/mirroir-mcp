// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Thread-safe session accumulator for the generate_skill exploration workflow.
// ABOUTME: Tracks explored screens, action history, goal queue, and flow state.

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
    /// The raw element text associated with the action (e.g. "General", "up", "hello").
    let arrivedVia: String?
    /// Clean label derived from the component's LabelRule, free of OCR artifacts.
    /// Used for skill step naming. Falls back to `arrivedVia` when no component context
    /// is available.
    var displayLabel: String? = nil
    /// Base64-encoded PNG screenshot of the screen.
    let screenshotBase64: String
}

/// A single action attempted during exploration (including rejected duplicates).
/// Used for cycle detection — even failed actions are tracked.
struct ExplorationAction: Sendable {
    let actionType: String?
    let arrivedVia: String?
    var displayLabel: String? = nil
    let wasDuplicate: Bool
}

/// Thread-safe accumulator for the generate_skill session-based workflow.
/// Same pattern as `CompilationSession` in CompilationTools.swift.
final class ExplorationSession: @unchecked Sendable {
    private var screens: [ExploredScreen] = []
    private var appName: String = ""
    private var goal: String = ""
    private var isActive: Bool = false
    private var mode: ExplorationGuide.Mode = .goalDriven
    private var actionLog: [ExplorationAction] = []
    private var startElements: [TapPoint]?
    private var goalsQueue: [String] = []
    private var goalIndex: Int = 0
    private var graph: NavigationGraph = NavigationGraph()
    private var strategyChoice: String = "mobile"
    private let lock = NSLock()

    /// Begin a new exploration session, resetting any prior state.
    ///
    /// - Parameters:
    ///   - appName: The app being explored.
    ///   - goal: A single goal description (empty for discovery mode).
    ///   - goals: Optional array of goals for manifest mode. If non-empty,
    ///     `goals[0]` is the initial goal and the rest are queued.
    func start(appName: String, goal: String, goals: [String] = []) {
        lock.lock()
        defer { lock.unlock() }
        screens = []
        actionLog = []
        graph = NavigationGraph()
        strategyChoice = "mobile"
        self.appName = appName
        self.startElements = nil

        if !goals.isEmpty {
            self.goalsQueue = goals
            self.goalIndex = 0
            self.goal = goals[0]
        } else {
            self.goalsQueue = []
            self.goalIndex = 0
            self.goal = goal
        }

        isActive = true
        mode = self.goal.isEmpty ? .discovery : .goalDriven
    }

    /// Append a captured screen to the session.
    /// Returns `false` if the screen is a duplicate of the last captured screen (unchanged).
    /// Both accepted and rejected captures are logged for cycle detection.
    @discardableResult
    func capture(
        elements: [TapPoint],
        hints: [String],
        actionType: String?,
        arrivedVia: String?,
        displayLabel: String? = nil,
        screenshotBase64: String
    ) -> Bool {
        capture(
            elements: elements, hints: hints, icons: [],
            actionType: actionType, arrivedVia: arrivedVia,
            displayLabel: displayLabel,
            screenshotBase64: screenshotBase64
        )
    }

    /// Extended capture that includes icon data for NavigationGraph population.
    /// Returns `false` if the screen is a duplicate.
    ///
    /// - Parameter skipGraphTransition: When `true`, skip the `graph.recordTransition()` call.
    ///   Set this when the caller (e.g. DFSExplorer) manages the graph directly to avoid
    ///   redundant double-recording on the shared NavigationGraph instance.
    @discardableResult
    func capture(
        elements: [TapPoint],
        hints: [String],
        icons: [IconDetector.DetectedIcon],
        actionType: String?,
        arrivedVia: String?,
        displayLabel: String? = nil,
        screenshotBase64: String,
        skipGraphTransition: Bool = false
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Reject duplicate: compare against last captured screen
        if let lastScreen = screens.last,
           StructuralFingerprint.areEquivalent(lastScreen.elements, elements) {
            actionLog.append(ExplorationAction(
                actionType: actionType, arrivedVia: arrivedVia,
                displayLabel: displayLabel, wasDuplicate: true))
            return false
        }

        // Store start elements from first capture for flow boundary detection
        if screens.isEmpty {
            startElements = elements
        }

        // Populate NavigationGraph alongside flat screen list.
        // Skip when the caller manages the graph directly (DFS explorer).
        if !skipGraphTransition {
            let screenType = classifyScreenWithStrategy(elements: elements, hints: hints)
            if !graph.started {
                graph.start(
                    rootElements: elements, icons: icons, hints: hints,
                    screenshot: screenshotBase64, screenType: screenType
                )
            } else if let actionType, let arrivedVia {
                _ = graph.recordTransition(
                    elements: elements, icons: icons, hints: hints,
                    screenshot: screenshotBase64, actionType: actionType,
                    elementText: arrivedVia, displayLabel: displayLabel,
                    screenType: screenType
                )
            }
        }

        let screen = ExploredScreen(
            index: screens.count,
            elements: elements,
            hints: hints,
            actionType: actionType,
            arrivedVia: arrivedVia,
            displayLabel: displayLabel,
            screenshotBase64: screenshotBase64
        )
        screens.append(screen)
        actionLog.append(ExplorationAction(
            actionType: actionType, arrivedVia: arrivedVia,
            displayLabel: displayLabel, wasDuplicate: false))
        return true
    }

    /// Finalize the current goal: return captured data and advance state.
    ///
    /// In manifest mode (goals queue has more entries), the session stays active
    /// and advances to the next goal with cleared screens and action log.
    /// Otherwise, the session is fully deactivated.
    ///
    /// Returns `nil` if the session was not active.
    func finalize() -> (
        appName: String, goal: String, screens: [ExploredScreen], graphSnapshot: GraphSnapshot
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        let snapshot = graph.finalize()
        let result = (appName: appName, goal: goal, screens: screens, graphSnapshot: snapshot)

        // Check if there are more goals in the queue
        let nextIndex = goalIndex + 1
        if nextIndex < goalsQueue.count {
            // Advance to next goal: reset screens but keep session active
            goalIndex = nextIndex
            self.goal = goalsQueue[nextIndex]
            screens = []
            actionLog = []
            startElements = nil
            graph = NavigationGraph()
            mode = .goalDriven
        } else {
            // No more goals: fully reset
            screens = []
            actionLog = []
            appName = ""
            goal = ""
            goalsQueue = []
            goalIndex = 0
            startElements = nil
            graph = NavigationGraph()
            isActive = false
        }

        return result
    }

    // MARK: - Read-Only Accessors

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

    /// The current exploration mode.
    var currentMode: ExplorationGuide.Mode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    /// The complete action log (including rejected duplicates).
    var actions: [ExplorationAction] {
        lock.lock()
        defer { lock.unlock() }
        return actionLog
    }

    /// The elements from the first captured screen (flow starting point).
    var startScreenElements: [TapPoint]? {
        lock.lock()
        defer { lock.unlock() }
        return startElements
    }

    /// Whether there are more goals in the queue after the current one.
    var hasMoreGoals: Bool {
        lock.lock()
        defer { lock.unlock() }
        return goalIndex + 1 < goalsQueue.count
    }

    /// The remaining goals in the queue (excluding current).
    var remainingGoals: [String] {
        lock.lock()
        defer { lock.unlock() }
        let nextIndex = goalIndex + 1
        guard nextIndex < goalsQueue.count else { return [] }
        return Array(goalsQueue[nextIndex...])
    }

    /// Zero-based index of the current goal in the manifest queue.
    /// Returns 0 for single-goal and discovery modes.
    var currentGoalIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return goalIndex
    }

    /// Total number of goals in the manifest queue (0 for single-goal mode).
    var totalGoals: Int {
        lock.lock()
        defer { lock.unlock() }
        return goalsQueue.count
    }

    /// The navigation graph for the current exploration session.
    var currentGraph: NavigationGraph {
        lock.lock()
        defer { lock.unlock() }
        return graph
    }

    /// Set the exploration strategy choice (e.g. "mobile", "social", "desktop").
    func setStrategy(_ choice: String) {
        lock.lock()
        defer { lock.unlock() }
        strategyChoice = choice
    }

    /// The current exploration strategy choice.
    var currentStrategy: String {
        lock.lock()
        defer { lock.unlock() }
        return strategyChoice
    }

    // MARK: - Strategy Dispatch

    /// Classify a screen using the current strategy choice.
    /// Must be called under lock or from a lock-protected method.
    private func classifyScreenWithStrategy(elements: [TapPoint], hints: [String]) -> ScreenType {
        switch strategyChoice {
        case "social":
            return SocialAppStrategy.classifyScreen(elements: elements, hints: hints)
        case "desktop":
            return DesktopAppStrategy.classifyScreen(elements: elements, hints: hints)
        default:
            return MobileAppStrategy.classifyScreen(elements: elements, hints: hints)
        }
    }
}
