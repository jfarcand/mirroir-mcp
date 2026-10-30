// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Action handlers for the generate_skill MCP tool (start/capture/finish/explore).
// ABOUTME: Extracted from GenerateSkillTools.swift to keep the tool registration file focused on schema.

import AppKit
import Foundation
import HelperLib

extension MirroirMCP {

    // MARK: - Action Handlers

    static func handleStart(
        args: [String: JSONValue],
        session: ExplorationSession,
        registry: TargetRegistry
    ) -> MCPToolResult {
        guard let appName = args["app_name"]?.asString(), !appName.isEmpty else {
            return .error("Missing required parameter: app_name (for start action)")
        }

        if session.active {
            return .error(
                "An exploration session is already active for '\(session.currentAppName)'. " +
                "Call finish first or start a new session.")
        }

        let (ctx, err) = registry.resolveForTool(args)
        guard let ctx else { return err! }

        // Skip Spotlight launch if iPhone is already showing the target app
        // (matched via persisted graph root fingerprint). Saves ~3s per call
        // and avoids stealing focus while a user is mid-flow inside the app.
        let result: ScreenDescriber.DescribeResult
        switch describeIfAlreadyForeground(appName: appName, ctx: ctx, logTag: "start")
            ?? launchAndDescribe(appName: appName, ctx: ctx) {
        case .success(let first):
            result = first
        case .failure(let failure):
            return .error(failure.message)
        }

        // Parse goal(s) and start session
        let goal = args["goal"]?.asString() ?? ""
        let goals = args["goals"]?.asStringArray() ?? []
        session.start(appName: appName, goal: goal, goals: goals)

        // Detect and store strategy
        let explicitStrategy = args["strategy"]?.asString()
        let strategyChoice = StrategyDetector.detect(
            targetType: ctx.targetType,
            appName: appName,
            explicitStrategy: explicitStrategy
        )
        session.setStrategy(strategyChoice.rawValue)

        // Capture first screen (no action since this is the initial screen)
        session.capture(
            elements: result.elements,
            hints: result.hints,
            icons: result.icons,
            actionType: nil,
            arrivedVia: nil,
            screenshotBase64: result.screenshotBase64
        )

        // Generate mode-specific preamble
        let modeName = session.currentMode == .discovery ? "Discovery" : "Goal-driven"
        var preamble = "Exploration started for '\(appName)' (\(modeName) mode). Screen 1 captured."
        if !goals.isEmpty {
            preamble += " Manifest: \(goals.count) goals queued."
        }

        let description = ExplorationGuidanceHelper.formatScreenDescription(
            elements: result.elements,
            hints: result.hints,
            preamble: preamble
        )

        // Generate initial guidance
        let guidance = ExplorationGuide.analyze(
            mode: session.currentMode,
            goal: session.currentGoal,
            elements: result.elements,
            hints: result.hints,
            startElements: nil,
            actionLog: [],
            screenCount: 1,
            isMobile: ctx.profile.coordinateSystem == .mobile
        )

        let guidanceText = ExplorationGuide.formatGuidance(guidance)

        return MCPToolResult(
            content: [
                .text(description + guidanceText),
                .image(result.screenshotBase64, mimeType: "image/png"),
            ],
            isError: false
        )
    }

    static func handleCapture(
        args: [String: JSONValue],
        session: ExplorationSession,
        registry: TargetRegistry
    ) -> MCPToolResult {
        guard session.active else {
            return .error("No active exploration session. Call generate_skill with action=\"start\" first.")
        }

        let (ctx, err) = registry.resolveForTool(args)
        guard let ctx else { return err! }

        // OCR current screen
        guard let result = ctx.describer.describe() else {
            return .error("Failed to capture/analyze screen. Is the target window visible?")
        }

        let arrivedVia = args["arrived_via"]?.asString()
        let actionType = args["action_type"]?.asString()

        let accepted = session.capture(
            elements: result.elements,
            hints: result.hints,
            icons: result.icons,
            actionType: actionType,
            arrivedVia: arrivedVia,
            screenshotBase64: result.screenshotBase64
        )

        if !accepted {
            // Still provide guidance even on duplicate rejection — use strategy if graph available
            let guidance = ExplorationGuidanceHelper.generateGuidance(
                session: session, elements: result.elements,
                icons: result.icons, hints: result.hints,
                isMobile: ctx.profile.coordinateSystem == .mobile
            )
            let guidanceText = ExplorationGuide.formatGuidance(guidance)

            return .text(
                "Screen unchanged \u{2014} capture skipped (duplicate of previous screen). " +
                "Try a different action before capturing again." + guidanceText)
        }

        let screenNum = session.screenCount
        let preamble = "Screen \(screenNum) captured" +
            (arrivedVia.map { " (arrived via \"\($0)\")" } ?? "") + "."

        let description = ExplorationGuidanceHelper.formatScreenDescription(
            elements: result.elements,
            hints: result.hints,
            preamble: preamble
        )

        // Generate guidance for the agent — prefer strategy-based when graph available
        let guidance = ExplorationGuidanceHelper.generateGuidance(
            session: session, elements: result.elements,
            icons: result.icons, hints: result.hints,
            isMobile: ctx.profile.coordinateSystem == .mobile
        )

        let guidanceText = ExplorationGuide.formatGuidance(guidance)

        return MCPToolResult(
            content: [
                .text(description + guidanceText),
                .image(result.screenshotBase64, mimeType: "image/png"),
            ],
            isError: false
        )
    }

    static func handleFinish(
        session: ExplorationSession, emit: Bool, outputDir: String?
    ) -> MCPToolResult {
        guard session.active else {
            return .error("No active exploration session. Call generate_skill with action=\"start\" first.")
        }

        guard session.screenCount > 0 else {
            return .error("No screens captured. Use capture action before finishing.")
        }

        // Check for remaining goals before finalize (which advances the queue)
        let remaining = session.remainingGoals
        let goalNum = session.currentGoalIndex + 1
        let totalGoals = session.totalGoals

        guard let data = session.finalize() else {
            return .error("Failed to finalize exploration session.")
        }

        // Use SkillBundleGenerator for multi-path graphs, single skill otherwise
        let bundle = SkillBundleGenerator.generate(
            appName: data.appName,
            goal: data.goal,
            snapshot: data.graphSnapshot,
            allScreens: data.screens,
            recipeMatch: session.currentRecipeMatch,
            appDescription: session.currentAppDescription
        )

        var text = ExplorationResultFormatter.formatBundle(
            bundle, preamble: "Generated \(bundle.skills.count) skills from exploration:")

        // finalize() has already advanced the goal queue, so the next-goal
        // guidance closes every result — a failed emit included — or the agent
        // would retry finish on a session that moved on.
        var goalNote = AppDescriptionLoader.load(appName: data.appName).refusalNote
            .map { "\n\n---\n\($0)" } ?? ""
        if !remaining.isEmpty {
            goalNote += "\n\n---\nGoal \(goalNum)/\(totalGoals) complete. "
            goalNote += "Next goal: \"\(remaining[0])\". "
            goalNote += "Session auto-advanced \u{2014} call capture to continue, or finish again when done."
            if remaining.count > 1 {
                goalNote += "\nRemaining after next: " +
                    remaining.dropFirst().map { "\"\($0)\"" }.joined(separator: ", ")
            }
        }

        if emit {
            do {
                text += try ExplorationLoopRunner.emitNote(
                    appName: data.appName,
                    flows: [MirroirAppTreeEmitter.Flow(name: data.goal, screens: data.screens)],
                    outputDir: outputDir)
            } catch {
                return ExplorationLoopRunner.emitFailure(
                    resultText: text, error: error, trailer: goalNote)
            }
        }
        return .text(text + goalNote)
    }

    // MARK: - Explore Handler

    static func handleExplore(
        args: [String: JSONValue],
        session: ExplorationSession,
        registry: TargetRegistry,
        server: MCPServer,
        policy: PermissionPolicy,
        appMdSearchPaths: [String] = AppDescriptionLoader.searchPaths()
    ) -> MCPToolResult {
        guard let appName = args["app_name"]?.asString(), !appName.isEmpty else {
            return .error("Missing required parameter: app_name (for explore action)")
        }

        if session.active {
            return .error(
                "An exploration session is already active for '\(session.currentAppName)'. " +
                "Call finish first.")
        }

        let (ctx, err) = registry.resolveForTool(args)
        guard let ctx else { return err! }

        // Permission checks must run BEFORE any destructive action. A blocked
        // app should never have its current session force-quit/reset, even
        // if reset_before_explore is set in APP.md.
        if case .denied(let reason) = policy.checkAppLaunch(appName) {
            return .error(reason)
        }
        let requiredTools = ["tap", "swipe", "type_text", "press_key"]
        let denied = policy.toolsDenied(for: appName, requiredTools: requiredTools)
        if !denied.isEmpty {
            return .error(
                "Cannot explore '\(appName)': permissions.json perApp rules deny "
                + "tools needed by the explorer: \(denied.joined(separator: ", ")). "
                + "Adjust perApp.\(appName).deny to permit exploration.")
        }

        // Load APP.md description — needed below to check reset_before_explore.
        // Every result from here on carries the refused-APP.md note, if any.
        let appMd = AppDescriptionLoader.load(appName: appName, searchPaths: appMdSearchPaths)
        let appDesc = appMd.description

        // A playable game is never BFS-explored: driving a scene starts matches
        // and burns frames, and a game scene is scripted by a kind:game skill,
        // not discovered. Only ordinary and observe-only apps are explorable.
        // Runs before any force-quit/launch so the game app is left untouched.
        if let appDesc, !appDesc.allowsExploration {
            return ExplorationLoopRunner.appendingNote(appMd.refusalNote, to: .text(
                "Exploration skipped: '\(appName)' is declared playable "
                + "(\(appDesc.playable ?? "")) in its APP.md — a game is driven "
                + "by a kind:game skill, not the explorer. App left untouched."))
        }

        // Force-quit the app before launching if APP.md requests it.
        // Ensures a clean start for apps with overlays or stateful UI
        // (TikTok, Instagram). Delegates to the target's lifecycle so all
        // dismissal paths share the OCR-based App Switcher card locator.
        let mustReset = appDesc?.resetBeforeExplore == true
        if mustReset {
            DebugLog.log("explore", "reset_before_explore: force-quitting '\(appName)' before launch")
            if let resetError = ctx.lifecycle.forceQuitBeforeExplore(
                appName: appName,
                bridge: ctx.bridge,
                input: ctx.input,
                describer: ctx.ocrDescriber
            ) {
                // Non-fatal here because the Spotlight launch below re-fronts
                // the target and the post-launch foreground guard aborts if it
                // did not take. A failed dismissal is NOT free of side effects:
                // the drag can tap-select a different card (observed: Mail),
                // so continuing without the guard would tap into a foreign app.
                DebugLog.log("explore",
                    "reset_before_explore skipped for '\(appName)': \(resetError) — "
                    + "relying on relaunch + foreground guard")
            }
        }

        // Skip Spotlight launch if iPhone is already showing the target app.
        // reset_before_explore always relaunches; otherwise we OCR-fingerprint
        // the current screen against the persisted graph root and skip on match.
        // No match launches behind the foreground guard (see launchInForeground).
        let firstResult: ScreenDescriber.DescribeResult
        let foreground = mustReset
            ? nil : describeIfAlreadyForeground(appName: appName, ctx: ctx, logTag: "explore")
        switch foreground ?? launchInForeground(appName: appName, ctx: ctx) {
        case .success(let result):
            firstResult = result
        case .failure(let failure):
            return ExplorationLoopRunner.appendingNote(appMd.refusalNote, to: .error(failure.message))
        }

        // Budget + skip-list merge. Built-ins, the global permissions.json list,
        // and the per-app APP.md list are combined with APP.md taking precedence
        // on duplicates so per-app casing survives.
        let maxDepth = args["max_depth"]?.asInt() ?? ExplorationBudget.default.maxDepth
        let maxScreens = args["max_screens"]?.asInt() ?? ExplorationBudget.default.maxScreens
        let maxTime = args["max_time"]?.asInt() ?? ExplorationBudget.default.maxTimeSeconds
        let extraPatterns = policy.config?.skipElements ?? []
        let appSkipPatterns = appDesc?.skipElements ?? []
        let mergedSkip = mergeSkipPatterns(
            builtIn: ExplorationBudget.builtInSkipPatterns,
            global: extraPatterns,
            perApp: appSkipPatterns
        )
        DebugLog.log("explore",
            "skip patterns: \(mergedSkip.count) total "
            + "(built-in \(ExplorationBudget.builtInSkipPatterns.count), "
            + "permissions.json \(extraPatterns.count), "
            + "APP.md \(appSkipPatterns.count))")
        let budget = ExplorationBudget(
            maxDepth: maxDepth,
            maxScreens: maxScreens,
            maxTimeSeconds: maxTime,
            maxActionsPerScreen: ExplorationBudget.default.maxActionsPerScreen,
            scrollLimit: ExplorationBudget.default.scrollLimit,
            skipPatterns: mergedSkip
        )

        let goal = args["goal"]?.asString() ?? ""
        let fresh = args["fresh"]?.asBool() ?? true
        let seed = args["seed"]?.asInt().map { UInt64($0) }
        let skipCalibration = args["skip_calibration"]?.asBool() ?? false
        let explorerChoice = args["explorer"]?.asString() ?? "bfs"
        let emit = args["emit"]?.asBool() ?? false
        let outputDir = args["output_dir"]?.asString()
        let explicitStrategy = args["strategy"]?.asString()
        let strategyChoice = StrategyDetector.detect(
            targetType: ctx.targetType,
            appName: appName,
            explicitStrategy: explicitStrategy
        )

        // Handle graph persistence: delete on fresh, log if existing
        if fresh {
            GraphPersistence.delete(bundleID: appName)
        } else if let existing = GraphPersistence.load(bundleID: appName) {
            DebugLog.log("explore", "Loaded persisted graph: \(existing.nodes.count) nodes, " +
                "\(existing.edges.count) edges, \(existing.deadEdges.count) dead edges")
        }

        session.start(appName: appName, goal: goal)
        session.setStrategy(strategyChoice.rawValue)
        if let desc = appDesc {
            session.setAppDescription(desc)
            DebugLog.log("explore",
                "APP.md loaded for '\(appName)': \(desc.skipElements.count) skip, " +
                "\(desc.obstacles.count) obstacles, mode=\(desc.obstacleMode.rawValue)")
        }

        // Capture first screen
        session.capture(
            elements: firstResult.elements, hints: firstResult.hints,
            icons: firstResult.icons, actionType: nil, arrivedVia: nil,
            screenshotBase64: firstResult.screenshotBase64
        )

        // Create explorer (BFS or DFS) and run exploration loop
        let windowSize = ctx.bridge.getWindowInfo()?.size ?? CGSize(width: 410, height: 890)
        let explorer: any Exploring
        if explorerChoice == "dfs" {
            explorer = DFSExplorer(
                session: session, budget: budget, windowSize: windowSize,
                backtracker: ctx.backtracker,
                profile: ctx.profile,
                bridge: ctx.bridge
            )
        } else {
            let componentDefinitions = ComponentLoader.loadAll()
            let recipeDefinitions = RecipeLoader.loadAll()

            // APP.md archetype: look up recipe by name and pre-set on session.
            // This bypasses auto-detection — the developer's declaration wins.
            if let archetypeName = appDesc?.archetype,
               let recipe = recipeDefinitions.first(where: { $0.name == archetypeName }) {
                let match = RecipeMatch(recipe: recipe, score: 100.0, reason: "APP.md archetype")
                session.setRecipeMatch(match)
                let refined = RecipeMatcher.strategyFromRecipe(recipe, fallback: strategyChoice)
                session.setStrategy(refined.rawValue)
                DebugLog.log("explore", "archetype from APP.md: '\(archetypeName)' " +
                    "(nav=\(recipe.navigationModel.type), strategy=\(refined.rawValue))")
            }
            let detectionMode = ComponentDetectionMode(rawValue: EnvConfig.componentDetection) ?? .llmFirstScreen
            let classifier = detectionMode.buildClassifier(
                server: server, agentConfig: AIAgentRegistry.resolveConfigured())
            let advisor: any ExplorationAdvising = AIAgentRegistry.embeddedAgentModel()
                .map { VisionExplorationAdvisor(model: $0) } ?? HeuristicExplorationAdvisor()
            explorer = BFSExplorer(
                session: session, budget: budget, windowSize: windowSize,
                componentDefinitions: componentDefinitions,
                classifier: classifier,
                bridge: ctx.bridge,
                seed: seed,
                skipCalibration: skipCalibration,
                advisor: advisor,
                recipes: recipeDefinitions,
                backtracker: ctx.backtracker,
                profile: ctx.profile
            )
        }
        explorer.markStarted()

        let result = ExplorationLoopRunner.run(
            explorer: explorer,
            strategyChoice: strategyChoice,
            ctx: ctx,
            appName: appName,
            emit: emit,
            outputDir: outputDir,
            initialLines: [
                "Autonomous \(explorerChoice.uppercased()) exploration started for '\(appName)'.",
                "Budget: depth=\(maxDepth), screens=\(maxScreens), time=\(maxTime)s",
            ]
        )
        return ExplorationLoopRunner.appendingNote(appMd.refusalNote, to: result)
    }

    /// Merge three layers of skip patterns with duplicate collapsing.
    /// Order of precedence is preserved so logs can attribute a match to its
    /// authoritative source (per-app wins over global wins over built-in).
    static func mergeSkipPatterns(
        builtIn: [String], global: [String], perApp: [String]
    ) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        // Per-app first so it claims the canonical casing when permissions.json
        // uses different capitalization for the same pattern.
        for pattern in perApp + global + builtIn {
            let key = pattern.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(pattern)
        }
        return merged
    }

}
