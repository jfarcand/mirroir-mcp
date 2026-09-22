// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: End-to-end FakeMirroring tests for tab-first social-feed exploration on the Instagram pack.
// ABOUTME: Covers tab visit-once coverage, tab-aware returns, calibration scroll cap, and stable wait anchors.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Test-only decorator over the real `InputSimulation`: records every tap
/// coordinate while forwarding all calls unchanged (not a mock — every gesture
/// still reaches FakeMirroring). No production type exposes the physical tap
/// sequence, which the tab-return tests must assert on.
private final class TapRecordingInput: InputProviding, @unchecked Sendable {
    private let base: any InputProviding
    private let lock = NSLock()
    private var tapLog: [CGPoint] = []

    init(wrapping base: any InputProviding) {
        self.base = base
    }

    /// Ordered tap coordinates observed so far.
    var recordedTaps: [CGPoint] {
        lock.lock()
        defer { lock.unlock() }
        return tapLog
    }

    func tap(x: Double, y: Double, cursorMode: CursorMode?) -> String? {
        lock.lock()
        tapLog.append(CGPoint(x: x, y: y))
        lock.unlock()
        return base.tap(x: x, y: y, cursorMode: cursorMode)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
               durationMs: Int, cursorMode: CursorMode?) -> String? {
        base.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                   durationMs: durationMs, cursorMode: cursorMode)
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              durationMs: Int, cursorMode: CursorMode?) -> String? {
        base.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                  durationMs: durationMs, cursorMode: cursorMode)
    }

    func longPress(x: Double, y: Double, durationMs: Int, cursorMode: CursorMode?) -> String? {
        base.longPress(x: x, y: y, durationMs: durationMs, cursorMode: cursorMode)
    }

    func doubleTap(x: Double, y: Double, cursorMode: CursorMode?) -> String? {
        base.doubleTap(x: x, y: y, cursorMode: cursorMode)
    }

    func shake() -> TypeResult { base.shake() }
    func typeText(_ text: String) -> TypeResult { base.typeText(text) }
    func pressKey(keyName: String, modifiers: [String]) -> TypeResult {
        base.pressKey(keyName: keyName, modifiers: modifiers)
    }
    func launchApp(name: String) -> String? { base.launchApp(name: name) }
    func openURL(_ url: String) -> String? { base.openURL(url) }
    func touch(_ command: TouchCommand) -> Result<TouchOutcome, TouchSessionError> {
        base.touch(command)
    }
    func gesture(_ request: GestureRequest) -> String? { base.gesture(request) }
    func holdKeys(_ request: HeldKeysRequest) -> String? { base.holdKeys(request) }
}

/// Everything the tests need from the Instagram pack, resolved from data files
/// (APP.md + recipe) so no tab names, titles, or limits are hardcoded in Swift.
private struct InstagramContext {
    let description: AppDescription
    let tabs: [String]
    let rootTitle: String
    let recipeMatch: RecipeMatch?
}

/// End-to-end tests for the tab-first social-feed exploration fix against
/// FakeMirroring's Instagram pack: P1 tabs tapped first and exactly once;
/// P2 tab-aware backtrack (no chevron fallback); P2b icon-only bar anchors;
/// P3 recipe-capped calibration; P4 stable-only wait anchors.
///
/// Run with: `swift test --filter SocialFeedExplorationE2ETests`
final class SocialFeedExplorationE2ETests: XCTestCase {

    /// Scenario-menu item and APP.md `app:` name of the simulator pack under test.
    private static let appName = "Instagram"

    private var bridge: MirroringBridge!
    private var recorder: TapRecordingInput!
    private var describer: ScreenDescriber!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
        describer = ScreenDescriber(bridge: bridge, capture: ScreenCapture(bridge: bridge))
        recorder = TapRecordingInput(wrapping: InputSimulation(bridge: bridge))

        // Cold-launch the pack (Scenario menu force-quits + relaunches fresh).
        _ = bridge.triggerMenuAction(menu: "Scenario", item: Self.appName)
        usleep(1_000_000)
    }

    override func tearDown() {
        if let bridge = bridge {
            _ = bridge.triggerMenuAction(menu: "Scenario", item: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    // MARK: - Shared Setup Helpers

    /// Window size the explorer and the assertions share for zone math.
    private func windowSize() -> CGSize {
        bridge.getWindowInfo()?.size ?? CGSize(width: 410, height: 898)
    }

    /// Load the Instagram APP.md + its archetype recipe from mirroir-skills.
    private func loadInstagramContext() throws -> InstagramContext {
        guard let desc = AppDescriptionLoader.load(appName: Self.appName) else {
            XCTFail("APP.md for '\(Self.appName)' not found in mirroir-skills search paths")
            throw IntegrationTestError.elementNotFound("APP.md for \(Self.appName)")
        }
        XCTAssertGreaterThanOrEqual(desc.tabs.count, 3,
            "Instagram APP.md must declare a multi-tab Structure. Got: \(desc.tabs)")
        guard let simulator = desc.simulator else {
            XCTFail("Instagram APP.md must declare a ## Simulator block for FakeMirroring")
            throw IntegrationTestError.elementNotFound("Simulator block in \(Self.appName) APP.md")
        }
        let rootTitle = simulator.rootScreen?.title ?? ""
        XCTAssertFalse(rootTitle.isEmpty, "Simulator root screen must declare a title")

        // Same wiring as handleExplore: the APP.md archetype pre-selects the recipe.
        var match: RecipeMatch?
        if let archetype = desc.archetype,
           let recipe = RecipeLoader.loadAll().first(where: { $0.name == archetype }) {
            match = RecipeMatch(recipe: recipe, score: 100.0, reason: "APP.md archetype")
        }
        return InstagramContext(
            description: desc, tabs: desc.tabs, rootTitle: rootTitle, recipeMatch: match)
    }

    /// OCR the current screen with app-obstacle dismissal (same path the
    /// explorer uses) so the captured root screen is never an obstacle modal.
    private func describeCleanOrFail(
        _ ctx: InstagramContext, file: StaticString = #file, line: UInt = #line
    ) throws -> ScreenDescriber.DescribeResult {
        for attempt in 1...3 {
            if let result = ExplorerUtilities.dismissAlertIfPresent(
                describer: describer, input: recorder,
                obstacles: ctx.description.obstacles
            ) {
                return result
            }
            if attempt < 3 { usleep(500_000) }
        }
        XCTFail("describe() returned nil after 3 attempts", file: file, line: line)
        throw IntegrationTestError.describeReturnedNil
    }

    /// Start a session mirroring handleExplore: strategy, recipe match from the
    /// APP.md archetype, app description, then the initial root capture.
    private func startInstagramSession(
        _ ctx: InstagramContext, goal: String
    ) throws -> ExplorationSession {
        let session = ExplorationSession()
        session.start(appName: Self.appName, goal: goal)
        session.setStrategy("social")
        if let match = ctx.recipeMatch { session.setRecipeMatch(match) }
        session.setAppDescription(ctx.description)

        let result = try describeCleanOrFail(ctx)
        session.capture(
            elements: result.elements, hints: result.hints, icons: result.icons,
            actionType: nil, arrivedVia: nil, screenshotBase64: result.screenshotBase64)
        return session
    }

    /// Build a BFS explorer configured the way handleExplore does for a social
    /// app: mirroir-skills components + recipes, per-viewport mode, seeded RNG.
    private func makeExplorer(
        session: ExplorationSession,
        maxDepth: Int,
        maxScreens: Int = 12,
        maxTimeSeconds: Int = 240
    ) -> BFSExplorer {
        let skip = MirroirMCP.mergeSkipPatterns(
            builtIn: ExplorationBudget.builtInSkipPatterns, global: [],
            perApp: session.currentAppDescription?.skipElements ?? [])
        let budget = ExplorationBudget(
            maxDepth: maxDepth, maxScreens: maxScreens, maxTimeSeconds: maxTimeSeconds,
            maxActionsPerScreen: 8, scrollLimit: 2, skipPatterns: skip)
        return BFSExplorer(
            session: session, budget: budget, windowSize: windowSize(),
            componentDefinitions: ComponentLoader.loadAll(),
            bridge: bridge, seed: 42, skipCalibration: true,
            advisor: HeuristicExplorationAdvisor(), recipes: RecipeLoader.loadAll())
    }

    /// Drive the exploration loop to completion, capturing the finished bundle.
    private func runExploration(
        _ explorer: BFSExplorer, stepLimit: Int = 150
    ) -> (steps: [ExploreStepResult], bundle: SkillBundle?) {
        explorer.markStarted()
        var steps: [ExploreStepResult] = []
        var bundle: SkillBundle?
        while !explorer.completed && steps.count < stepLimit {
            let result = explorer.step(
                describer: describer, input: recorder, strategy: SocialAppStrategy.self)
            steps.append(result)
            if case .finished(let finished) = result {
                bundle = finished
                break
            }
        }
        return (steps, bundle)
    }

    /// Human-readable step trail for assertion failure messages.
    private func trail(_ steps: [ExploreStepResult]) -> String {
        steps.map { step -> String in
            switch step {
            case .continue(let d): return d
            case .paused(let r): return "paused: \(r)"
            case .trapped(let r): return "trapped: \(r)"
            case .backtracked: return "backtracked"
            case .finished: return "finished"
            }
        }.joined(separator: "\n  ")
    }

    /// Extract every X from `Wait for "X" to appear` lines in a SKILL.md body.
    private func waitAnchors(in skillMd: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"Wait for "([^"]+)" to appear"#)
        let range = NSRange(skillMd.startIndex..., in: skillMd)
        return regex.matches(in: skillMd, range: range).compactMap { match in
            Range(match.range(at: 1), in: skillMd).map { String(skillMd[$0]) }
        }
    }

    // MARK: - P1: All Tabs Visited Exactly Once

    /// Every APP.md-declared tab is plan-tapped exactly once, and every
    /// non-root tab produces a graph edge (a screen reached via that tab).
    func testAllTabsVisitedOnceP1() throws {
        let ctx = try loadInstagramContext()
        let session = try startInstagramSession(ctx, goal: "tab coverage")
        let explorer = makeExplorer(session: session, maxDepth: 1)
        let run = runExploration(explorer)

        XCTAssertTrue(explorer.completed,
            "Explorer should complete within budget. Steps:\n  \(trail(run.steps))")

        // Skip-listed tabs (e.g. the Créer composer tab) are declared for anchor
        // geometry but must never be tapped; only the rest are coverage targets.
        let budget = ExplorationBudget.default.mergedWith(ctx.description.skipElements)
        let explorableTabs = ctx.tabs.filter { !budget.shouldSkipElement(text: $0) }
        let skippedTabs = ctx.tabs.filter { budget.shouldSkipElement(text: $0) }
        XCTAssertGreaterThanOrEqual(explorableTabs.count, 3,
            "Most tabs must remain explorable. Skipped: \(skippedTabs)")

        // Every explorable tab was plan-tapped once (breadth one-tap-global tracking).
        let visited = explorer.graph.globalVisitedLabels
        for tab in explorableTabs {
            XCTAssertTrue(visited.contains(tab),
                "Tab \"\(tab)\" was never plan-tapped as a breadth target. " +
                "Globally visited: \(visited.sorted()). Steps:\n  \(trail(run.steps))")
        }

        // Every explorable non-root tab produced an edge — a screen reached via
        // that label. The root tab's own tap is a same-screen dead tap (no edge).
        let snapshot = explorer.graph.finalize()
        for tab in explorableTabs where tab != ctx.rootTitle {
            XCTAssertTrue(snapshot.edges.contains { $0.displayLabel == tab },
                "No screen was reached via tab \"\(tab)\". Edges: " +
                snapshot.edges.map { $0.displayLabel }.joined(separator: ", "))
        }
        XCTAssertGreaterThanOrEqual(snapshot.nodes.count, explorableTabs.count,
            "Root + each explorable non-root tab screen should be distinct graph " +
            "nodes. Got \(snapshot.nodes.count) nodes")

        // Safety: a Skip-listed tab must never be tapped and never gain an edge —
        // on the real app the composer tab opens the camera flow.
        for tab in skippedTabs {
            XCTAssertFalse(visited.contains(tab),
                "Skip-listed tab \"\(tab)\" was tapped — Skip must gate plan taps")
            XCTAssertFalse(snapshot.edges.contains { $0.displayLabel == tab },
                "Skip-listed tab \"\(tab)\" produced a navigation edge")
        }

        // Exactly once: the executed action log (cache skips excluded) must not
        // contain any tab label twice. Frontier path replays are not plan
        // actions and are intentionally not counted here.
        let report = explorer.reporter.snapshot()
        let executed = report.screenActions.values.flatMap { $0 }.filter { !$0.skippedByCache }
        for tab in ctx.tabs {
            let count = executed.filter { $0.label == tab }.count
            XCTAssertLessThanOrEqual(count, 1,
                "Tab \"\(tab)\" was plan-executed \(count) times — must be at most once")
        }
    }

    // MARK: - P2: Tab Return, Not Chevron Fallback

    /// Backtrack after a tab navigation goes through the tab bar (root-tab tap),
    /// never the top-left chevron fallback.
    ///
    /// Observability choice: no production type records input, so the recording
    /// decorator over the real InputSimulation is the strongest signal available.
    /// The chevron check is scoped to the window between the first tab-switch
    /// tap and its return tap: a tab return fires immediately after the switch,
    /// while post-return obstacle recovery (which may legitimately probe the
    /// fallback corner once) is outside that window and must not fail the test.
    func testTabReturnNotChevronFallbackP2() throws {
        let ctx = try loadInstagramContext()
        let session = try startInstagramSession(ctx, goal: "tab return")
        let explorer = makeExplorer(session: session, maxDepth: 1)
        let run = runExploration(explorer)

        XCTAssertTrue(explorer.completed,
            "Explorer should complete. Steps:\n  \(trail(run.steps))")

        // The tab navigations must be classified as .tab edges — that is what
        // routes backtracking through BFSTabReturn instead of the chevron path.
        let snapshot = explorer.graph.finalize()
        let tabEdges = snapshot.edges.filter { ctx.tabs.contains($0.displayLabel) }
        XCTAssertFalse(tabEdges.isEmpty,
            "At least one tab navigation edge expected. Steps:\n  \(trail(run.steps))")
        XCTAssertTrue(tabEdges.contains { $0.edgeType == .tab },
            "Tab navigations should be classified as .tab edges. Got: " +
            tabEdges.map { "\($0.displayLabel)=\($0.edgeType.rawValue)" }.joined(separator: ", "))

        // Physical tap sequence: after the first tab-bar tap outside the root
        // tab's column, the next tab-bar-band tap must be back in the root
        // column (the return), with no chevron-corner tap in between.
        let window = windowSize()
        let bandMinY = Double(window.height) * NavigationHintDetector.tabBarZoneFraction
        let rootColumnMaxX = Double(window.width) / Double(ctx.tabs.count)
        let taps = recorder.recordedTaps
        let bandTaps = taps.enumerated().filter { Double($0.element.y) >= bandMinY }
        guard let switchTap = bandTaps.first(where: { Double($0.element.x) >= rootColumnMaxX })
        else {
            XCTFail("No tab-switch tap recorded in the tab-bar band. " +
                "Taps: \(taps). Steps:\n  \(trail(run.steps))")
            return
        }
        let returnTap = bandTaps.first {
            $0.offset > switchTap.offset && Double($0.element.x) < rootColumnMaxX
        }
        XCTAssertNotNil(returnTap,
            "No root-tab return tap recorded after the tab switch at " +
            "(\(Int(switchTap.element.x)),\(Int(switchTap.element.y))) — backtrack " +
            "did not go through the tab bar. Band taps: " +
            bandTaps.map { "(\(Int($0.element.x)),\(Int($0.element.y)))" }.joined(separator: ", "))

        let windowEnd = returnTap?.offset ?? taps.count
        let chevronTaps = taps[(switchTap.offset + 1)..<windowEnd].filter {
            Double($0.x) <= Double(window.width) * 0.25
                && Double($0.y) <= Double(window.height) * 0.25
        }
        XCTAssertTrue(chevronTaps.isEmpty,
            "Chevron-fallback-region tap fired between tab switch and tab return: " +
            chevronTaps.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: ", "))
    }

    // MARK: - P3: Calibration Scroll Cap

    /// The social-feed recipe's calibration_scroll_limit caps the calibration
    /// scan, overriding the budget's much larger default.
    func testCalibrationCappedP3() throws {
        let ctx = try loadInstagramContext()
        guard let match = ctx.recipeMatch,
              let declaredLimit = match.recipe.navigationModel.calibrationScrollLimit else {
            XCTFail("The '\(ctx.description.archetype ?? "?")' recipe must declare " +
                "calibration_scroll_limit — P3 depends on it")
            return
        }

        let session = try startInstagramSession(ctx, goal: "calibration cap")
        let explorer = makeExplorer(session: session, maxDepth: 1)

        XCTAssertLessThan(declaredLimit, explorer.budget.calibrationScrollLimit,
            "Recipe cap (\(declaredLimit)) must undercut the budget default " +
            "(\(explorer.budget.calibrationScrollLimit)) or this test proves nothing")
        XCTAssertEqual(explorer.effectiveCalibrationScrollLimit, declaredLimit,
            "Recipe calibration_scroll_limit should be the effective cap")

        let run = runExploration(explorer)
        XCTAssertTrue(explorer.completed,
            "Explorer should complete. Steps:\n  \(trail(run.steps))")

        guard let summary = explorer.reporter.snapshot().calibrationSummary else {
            XCTFail("Calibration ran (skipCalibration only skips component detection) " +
                "so a calibration summary must exist")
            return
        }
        XCTAssertLessThanOrEqual(summary.scrollCount, declaredLimit,
            "Calibration performed \(summary.scrollCount) scrolls — the recipe " +
            "caps it at \(declaredLimit)")
    }

    // MARK: - P4: Stable Wait Anchors

    /// Generated skills only wait on stable anchors (APP.md tab names or
    /// simulator screen titles); screens without a stable anchor omit the wait
    /// step entirely.
    func testStableWaitAnchorsP4() throws {
        let ctx = try loadInstagramContext()
        XCTAssertEqual(ctx.recipeMatch?.recipe.navigationModel.scrollBehavior, "infinite",
            "social-feed recipe must declare infinite scroll — that is what forces " +
            "stable-only wait anchors")
        guard let simulator = ctx.description.simulator else { return }
        let stableSet = Set(
            (ctx.tabs + simulator.screens.values.map { $0.title }).map { $0.lowercased() })

        // Omission half, on real OCR data: a screen holding only content-zone
        // elements (header zone and tab band stripped, stable labels excluded)
        // has no stable anchor, so its wait step must be omitted entirely.
        let window = windowSize()
        let bandMinY = Double(window.height) * NavigationHintDetector.tabBarZoneFraction
        let probe = try describeCleanOrFail(ctx)
        let contentOnly = probe.elements.filter { el in
            el.tapY > LandmarkPicker.headerZoneRange.upperBound + 20
                && el.tapY < bandMinY
                && !stableSet.contains(
                    el.text.trimmingCharacters(in: .whitespaces).lowercased())
        }
        XCTAssertFalse(contentOnly.isEmpty,
            "Feed content elements expected below the header zone. OCR: " +
            probe.elements.map { "\($0.text)@\(Int($0.tapY))" }.joined(separator: ", "))
        let syntheticScreen = ExploredScreen(
            index: 0, elements: contentOnly, hints: [], actionType: nil,
            arrivedVia: nil, screenshotBase64: probe.screenshotBase64)
        let unstableMd = SkillMdGenerator.generate(
            appName: Self.appName, goal: "unstable anchor omission",
            screens: [syntheticScreen],
            recipeMatch: ctx.recipeMatch, appDescription: ctx.description)
        XCTAssertFalse(unstableMd.contains("Wait for"),
            "A screen without a stable anchor must omit the wait step. Got:\n\(unstableMd)")

        // Closed-set half: explore end-to-end and check every emitted wait
        // anchor against the stable set.
        let session = try startInstagramSession(ctx, goal: "stable anchors")
        let explorer = makeExplorer(session: session, maxDepth: 2, maxTimeSeconds: 420)
        let run = runExploration(explorer, stepLimit: 200)
        guard let bundle = run.bundle else {
            XCTFail("Exploration did not finish with a bundle. Steps:\n  \(trail(run.steps))")
            return
        }
        XCTAssertFalse(bundle.skills.isEmpty,
            "Exploration should generate at least one skill. Steps:\n  \(trail(run.steps))")
        for (name, content) in bundle.skills {
            for anchor in waitAnchors(in: content) {
                XCTAssertTrue(stableSet.contains(anchor.lowercased()),
                    "Skill '\(name)' waits on ephemeral anchor \"\(anchor)\" — " +
                    "allowed anchors are APP.md tabs and simulator screen titles: " +
                    "\(stableSet.sorted()). Content:\n\(content)")
            }
        }
    }

    // MARK: - P2b: Icon-Only Tab Bar

    /// With `tab_bar_style: icons` the bar carries no OCR text, yet exploration
    /// still reaches the tab screens via synthesized geometric anchors, and the
    /// describer reports the bar via the tab-bar hint.
    func testIconOnlyTabBarExploredP2b() throws {
        let ctx = try loadInstagramContext()
        guard let simulator = ctx.description.simulator else { return }
        XCTAssertEqual(simulator.tabBarStyle, .icons,
            "Instagram's Simulator block must declare 'tab_bar_style: icons' — " +
            "this test validates icon-only bar exploration and cannot run against " +
            "a labeled bar")

        // Gate: the rendering contract must actually be in effect — the tab-bar
        // band must contain zero OCR text. A labeled bar here means the icons
        // style is not active and the rest of the test would be meaningless.
        let window = windowSize()
        let bandMinY = Double(window.height) * NavigationHintDetector.tabBarZoneFraction
        let probe = try describeCleanOrFail(ctx)
        let bandTexts = probe.elements.filter {
            $0.tapY >= bandMinY
                && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        XCTAssertTrue(bandTexts.isEmpty,
            "tab_bar_style: icons is NOT active — OCR found text in the tab-bar band: " +
            bandTexts.map { "\"\($0.text)\"@(\(Int($0.tapX)),\(Int($0.tapY)))" }
                .joined(separator: ", "))

        // The describer must still report the bar from detected icon evidence.
        XCTAssertTrue(
            probe.hints.contains { $0.hasPrefix(NavigationHintDetector.tabBarHintPrefix) },
            "Describer hints must contain a \"\(NavigationHintDetector.tabBarHintPrefix)\" " +
            "hint from icon-band evidence. Hints: \(probe.hints), " +
            "icons detected: \(probe.icons.count)")

        // Exploration must still reach the tab screens via synthesized anchors.
        let session = try startInstagramSession(ctx, goal: "icon-only tabs")
        let explorer = makeExplorer(session: session, maxDepth: 1)
        let run = runExploration(explorer)
        XCTAssertTrue(explorer.completed,
            "Explorer should complete. Steps:\n  \(trail(run.steps))")

        let snapshot = explorer.graph.finalize()
        let tabDestinations = Set(snapshot.edges
            .filter { ctx.tabs.contains($0.displayLabel) }.map { $0.toFingerprint })
        XCTAssertGreaterThanOrEqual(tabDestinations.count, 3,
            "Icon-only exploration should visit at least 3 tab screens via " +
            "synthesized anchors. Reached \(tabDestinations.count) via: " +
            snapshot.edges.map { $0.displayLabel }.joined(separator: ", ") +
            ". Steps:\n  \(trail(run.steps))")
    }
}
