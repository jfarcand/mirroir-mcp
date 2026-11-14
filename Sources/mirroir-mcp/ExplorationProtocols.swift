// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Exploration-domain protocol abstractions (strategy, explorer, navigation graph, backtracking, lifecycle, advising).
// ABOUTME: System-boundary protocols live in the *Protocols.swift file of their boundary family.

import CoreGraphics
import Foundation
import HelperLib

/// Strategy for customizing autonomous app exploration behavior.
/// Different app types (mobile, social, desktop) can provide tailored
/// element ranking, backtracking, and screen classification logic.
/// All methods are static because strategies are stateless enum namespaces.
protocol ExplorationStrategy: Sendable {
    /// Classify a screen based on its elements and hints.
    static func classifyScreen(elements: [TapPoint], hints: [String]) -> ScreenType

    /// Rank elements for exploration priority.
    /// Returns elements sorted by exploration value (most interesting first).
    static func rankElements(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        visitedElements: Set<String>,
        depth: Int,
        screenType: ScreenType
    ) -> [TapPoint]

    /// Determine how to backtrack from the current screen.
    static func backtrackMethod(currentHints: [String], depth: Int) -> BacktrackAction

    /// Check if an element should be skipped during exploration.
    /// Skip patterns are loaded from the budget (sourced from permissions.json).
    static func shouldSkip(elementText: String, budget: ExplorationBudget) -> Bool

    /// Check if a screen is a terminal node (no further exploration needed).
    static func isTerminal(
        elements: [TapPoint],
        depth: Int,
        budget: ExplorationBudget,
        screenType: ScreenType
    ) -> Bool

    /// Compute a structural fingerprint for screen identity.
    static func extractFingerprint(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon]
    ) -> String
}

/// Classifies OCR elements into UI components for exploration planning.
/// Abstracts the boundary between heuristic and LLM-based component detection.
protocol ComponentClassifying: Sendable {
    /// Classify OCR elements into screen components.
    ///
    /// - Parameters:
    ///   - classified: Pre-classified OCR elements.
    ///   - definitions: Available component definitions.
    ///   - screenHeight: Height of the target window.
    /// - Returns: Detected screen components, or nil if classification failed.
    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]?
}

/// Common interface for app exploration algorithms (BFS, DFS).
/// Both explorers follow the Session Accumulator pattern: `markStarted()` begins the
/// lifecycle, `step()` advances one action, and `generateBundle()` produces the final output.
protocol Exploring: AnyObject, Sendable {
    /// Perform one exploration step using the given strategy.
    func step<S: ExplorationStrategy>(
        describer: ScreenDescribing, input: InputProviding, strategy: S.Type
    ) -> ExploreStepResult

    /// Record the exploration start time. Call once after the initial screen capture.
    func markStarted()

    /// Whether the exploration has completed (budget exhausted or all reachable screens visited).
    var completed: Bool { get }

    /// Current exploration statistics: screens discovered, edges, actions performed, elapsed time.
    var stats: (nodeCount: Int, edgeCount: Int, actionCount: Int, elapsedSeconds: Int) { get }

    /// The navigation graph tracking screen transitions and visited elements.
    var graph: any NavigationGraphing { get }

    /// Generate the final skill bundle from the exploration session.
    func generateBundle() -> SkillBundle

    /// Generate a human-readable exploration report summarizing what was explored.
    func generateReport() -> String
}

/// Abstracts the navigation graph used during app exploration.
/// Enables swappable graph implementations for testing and alternative strategies.
protocol NavigationGraphing: AnyObject, Sendable {

    // MARK: - Lifecycle

    /// Initialize the graph with the root screen, resetting all state.
    func start(
        rootElements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        hints: [String],
        screenshot: String,
        screenType: ScreenType
    )

    /// Record a navigation transition. Returns whether the screen is new, revisited, or duplicate.
    func recordTransition(
        elements: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        hints: [String],
        screenshot: String,
        actionType: String,
        elementText: String,
        displayLabel: String?,
        screenType: ScreenType,
        edgeType: EdgeType
    ) -> TransitionResult

    /// Export an immutable snapshot of the current graph state.
    func finalize() -> GraphSnapshot

    // MARK: - Properties

    /// Number of distinct screens discovered.
    var nodeCount: Int { get }

    /// Number of navigation edges recorded.
    var edgeCount: Int { get }

    /// Fingerprint of the current screen.
    var currentFingerprint: String { get }

    /// Fingerprint of the root (first) screen.
    var rootFingerprint: String { get }

    /// Whether the graph has been initialized with a root screen.
    var started: Bool { get }

    /// The set of labels marked globally visited (breadth_navigation items).
    var globalVisitedLabels: Set<String> { get }

    // MARK: - Node Access

    /// Get the node for a given fingerprint.
    func node(for fingerprint: String) -> ScreenNode?

    /// Get the most recent incoming edge that led to a given screen fingerprint.
    func incomingEdge(to fingerprint: String) -> NavigationEdge?

    /// Find a node with similar structural elements using title-aware similarity.
    func findMatchingNode(elements: [TapPoint]) -> String?

    /// Find a node matching the viewport using both Jaccard similarity and containment.
    func findMatchingNodeWithContainment(elements: [TapPoint]) -> String?

    // MARK: - Visited State

    /// Mark an element as visited on the specified screen.
    func markElementVisited(fingerprint: String, elementText: String)

    /// Update the current fingerprint after backtracking to sync graph state.
    func setCurrentFingerprint(_ fingerprint: String)

    // MARK: - Screen Plans

    /// Store a ranked exploration plan for a screen.
    func setScreenPlan(for fingerprint: String, plan: [RankedElement])

    /// Get the exploration plan for a screen, if one has been built.
    func screenPlan(for fingerprint: String) -> [RankedElement]?

    /// Get the next unvisited plan element, skipping per-screen and global visited sets.
    func nextPlannedElement(for fingerprint: String) -> RankedElement?

    /// Clear the exploration plan for a screen, forcing a rebuild on next access.
    func clearScreenPlan(for fingerprint: String)

    // MARK: - Scout Phase

    /// Record the result of scouting an element on a screen.
    func recordScoutResult(fingerprint: String, elementText: String, result: ScoutResult)

    /// Get all scout results for a screen.
    func scoutResults(for fingerprint: String) -> [String: ScoutResult]

    /// Get the current traversal phase for a screen.
    func traversalPhase(for fingerprint: String) -> TraversalPhase

    /// Set the traversal phase for a screen.
    func setTraversalPhase(for fingerprint: String, phase: TraversalPhase)

    // MARK: - Breadth Navigation

    /// Register breadth_navigation labels (e.g. tab bar items) for global tracking.
    func registerBreadthLabels(_ labels: Set<String>)

    /// Check if a displayLabel belongs to a breadth_navigation component.
    func isBreadthLabel(_ label: String) -> Bool

    /// Mark a breadth_navigation component as globally visited across all screens.
    func markGloballyVisited(label: String)

    // MARK: - Tap Area Cache

    /// Record a tap at the given coordinates on a screen.
    func recordTap(fingerprint: String, x: Double, y: Double)

    /// Check whether a point was already tapped on a screen (within proximity radius).
    func wasAlreadyTapped(fingerprint: String, x: Double, y: Double) -> Bool

    /// Number of tapped areas recorded for a screen.
    func tapCount(for fingerprint: String) -> Int

    // MARK: - Dead Edge Tracking

    /// Mark an edge as dead (tap had no effect on the screen).
    func markEdgeDead(fromFingerprint: String, displayLabel: String)

    // MARK: - Recovery Events

    /// Append a recovery event for post-hoc diagnosis.
    func appendRecoveryEvent(_ event: RecoveryEvent)

    // MARK: - Scroll Support

    /// Merge scrolled elements into a screen node. Returns novel count.
    func mergeScrolledElements(fingerprint: String, newElements: [TapPoint]) -> Int

    /// Get the number of scroll actions performed on a screen.
    func scrollCount(for fingerprint: String) -> Int

    /// Increment the scroll count for a screen.
    func incrementScrollCount(for fingerprint: String)

    /// Mark a screen as having infinite scroll (content never exhausts).
    func markInfiniteScroll(fingerprint: String)

    /// Mark a screen as scroll-exhausted (all content has been revealed).
    func markScrollExhausted(fingerprint: String)

    /// Check if a screen has been marked as having infinite scroll.
    func isInfiniteScroll(fingerprint: String) -> Bool

    /// Check if a screen has been marked as scroll-exhausted.
    func isScrollExhausted(fingerprint: String) -> Bool
}

/// Protocol for AI agent providers that can diagnose skill failures.
protocol AIAgentProviding {
    func diagnose(payload: DiagnosticPayload) -> AIDiagnosis?
}

/// What a backtracker did to go back one screen.
struct BackOutcome: Equatable, Sendable {
    /// The back action, as it was sent.
    enum Action: Equatable, Sendable {
        /// Tapped the "<" chevron OCR found, at window coordinates.
        case chevron(x: Double, y: Double)
        /// OCR found no chevron: tapped the target's fallback point.
        case fallbackPoint(x: Double, y: Double)
        /// Pressed a keyboard shortcut, such as "Cmd+[".
        case shortcut(String)
    }

    let action: Action
    /// Why the input layer refused the action; nil when it was sent.
    let error: String?

    /// Whether the back action was sent.
    var issued: Bool { error == nil }

    /// The action in words, for a tool's reply.
    var description: String {
        switch action {
        case .chevron(let x, let y):
            return "tapped the \"<\" back chevron at (\(Int(x.rounded())), \(Int(y.rounded())))"
        case .fallbackPoint(let x, let y):
            return "OCR found no \"<\" chevron, so tapped the usual back-button point "
                + "(\(Int(x.rounded())), \(Int(y.rounded())))"
        case .shortcut(let keys):
            return "pressed \(keys)"
        }
    }
}

/// Returns-to-previous-screen strategy. Varies per target: iPhone Mirroring must
/// OCR-detect a back chevron and tap it (iOS apps do not implement Cmd+[),
/// while native macOS apps can use Cmd+[ or similar keybindings.
protocol Backtracking: Sendable {
    /// Attempt to navigate one screen back. Returns what was sent, and whether
    /// it was (the caller verifies arrival separately via OCR).
    ///
    /// - Parameters:
    ///   - elements: Current screen OCR elements (used by OCR-based backtrackers
    ///     to locate the back chevron; ignored by keyboard-shortcut backtrackers).
    ///   - input: Input provider for issuing the back action.
    ///   - windowSize: Size of the target window in points (used for the
    ///     canonical-position fallback when OCR misses the chevron).
    ///   - fallback: Canonical back-button position as fractions of window
    ///     width and height. Orientation-sensitive for iPhone Mirroring;
    ///     ignored by keyboard-shortcut backtrackers.
    @discardableResult
    func tapBack(
        elements: [TapPoint],
        input: any InputProviding,
        windowSize: CGSize,
        fallback: BackButtonFallback
    ) -> BackOutcome
}

/// App lifecycle operations that vary per target: launch, force-quit before explore,
/// and open-URL semantics. iPhone Mirroring uses Spotlight-via-Mirroring + App Switcher
/// swipe-up; macOS apps use `open -a` and Cmd+Q.
protocol AppLifecycleHandling: Sendable {
    /// Launch the app by display name. Returns an error message on failure.
    func launch(appName: String, input: any InputProviding) -> String?
    /// Force-quit the app before a fresh explore run. Only called when APP.md
    /// declares `reset_before_explore: true`. Returns `nil` on success or an
    /// error message on failure (caller decides whether to abort the run).
    func forceQuitBeforeExplore(
        appName: String,
        bridge: any WindowBridging,
        input: any InputProviding,
        describer: any ScreenDescribing
    ) -> String?
}

/// Protocol for AI-guided exploration advice during plateau phases.
/// Abstracted for testability — production uses embacle, tests can inject stubs.
protocol ExplorationAdvising: Sendable {
    /// Given the current screen and exploration state, suggest elements to tap.
    ///
    /// - Parameters:
    ///   - screenshotBase64: Current screen screenshot for vision analysis.
    ///   - elements: OCR elements visible on the current screen.
    ///   - visitedElements: Elements already tapped on this screen.
    ///   - exploredScreenCount: Total screens discovered so far.
    /// - Returns: Ranked suggestions, or empty if the advisor cannot help.
    func suggest(
        screenshotBase64: String,
        elements: [TapPoint],
        visitedElements: Set<String>,
        exploredScreenCount: Int
    ) -> [ExplorationSuggestion]
}

// MARK: - Conformances

extension BFSExplorer: Exploring {}

extension DFSExplorer: Exploring {}

extension NavigationGraph: NavigationGraphing {}
