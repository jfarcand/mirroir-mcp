// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Drives the autonomous exploration step loop: strategy dispatch, trap recovery, persistence.
// ABOUTME: Extracted from GenerateSkillHandlers so the handler file stays focused on argument handling.

import Foundation
import HelperLib

/// Runs an explorer to completion for `generate_skill(action: "explore")`:
/// dispatches steps through the detected strategy, recovers from trapped
/// screens by force-quit + relaunch, persists the graph snapshot, and formats
/// the final MCP result (including the optional `.mirroir/` emit note).
enum ExplorationLoopRunner {

    /// Bounds how many times we force-quit + relaunch to escape a
    /// self-re-arming screen (e.g. the Story camera) before giving up.
    private static let maxTrapRecoveries = 3

    static func run(
        explorer: any Exploring,
        strategyChoice: StrategyChoice,
        ctx: TargetContext,
        appName: String,
        goal: String,
        emit: Bool,
        outputDir: String?,
        initialLines: [String]
    ) -> MCPToolResult {
        var stepResults = initialLines

        // Trap recovery counter: bounds how many times we force-quit + relaunch to
        // escape a self-re-arming screen (e.g. the Story camera) before giving up.
        var trapRecoveries = 0

        // Run exploration loop using detected strategy
        while !explorer.completed {
            let result: ExploreStepResult
            switch strategyChoice {
            case .social:
                result = explorer.step(
                    describer: ctx.describer, input: ctx.input,
                    strategy: SocialAppStrategy.self)
            case .desktop:
                result = explorer.step(
                    describer: ctx.describer, input: ctx.input,
                    strategy: DesktopAppStrategy.self)
            case .mobile:
                result = explorer.step(
                    describer: ctx.describer, input: ctx.input,
                    strategy: MobileAppStrategy.self)
            }

            switch result {
            case .continue(let desc):
                stepResults.append(desc)
                DebugLog.log("explore", "step \(stepResults.count): \(desc)")
            case .backtracked(_, _):
                stepResults.append("Backtracked to parent screen.")
                DebugLog.log("explore", "step \(stepResults.count): backtracked")
            case .paused(let reason):
                stepResults.append("Paused: \(reason)")
                let stats = explorer.stats
                let summary = stepResults.joined(separator: "\n")
                let report = explorer.generateReport()
                // Persist partial graph for future incremental runs
                let snapshot = explorer.graph.finalize()
                GraphPersistence.save(snapshot: snapshot, bundleID: appName)
                return .text(
                    "\(summary)\n\nExploration paused after \(stats.actionCount) actions, " +
                    "\(stats.nodeCount) screens in \(stats.elapsedSeconds)s.\n\n\(report)")
            case .finished(let bundle):
                // Persist the completed graph for future incremental runs
                let snapshot = explorer.graph.finalize()
                GraphPersistence.save(snapshot: snapshot, bundleID: appName)
                var resultText = ExplorationResultFormatter.formatExploreResult(
                    bundle: bundle, explorer: explorer)
                if emit {
                    // Emit the primary explored path as the iOS leg, named after the path.
                    let primary = GraphPathFinder.findInterestingPaths(in: snapshot).first
                    let screens = primary.map {
                        GraphPathFinder.pathToExploredScreens(path: $0.edges, snapshot: snapshot)
                    } ?? []
                    let flow = primary?.name ?? goal
                    resultText += emitNote(
                        appName: appName, flow: flow, screens: screens, outputDir: outputDir)
                }
                return .text(resultText)
            case .trapped(let reason):
                // The explorer hit a screen it cannot dismiss in-app (e.g. the
                // Story camera). It has already reset its position to root; physically
                // escape by force-quitting (the only reliable exit) and cold-relaunching
                // to the feed, then continue exploring.
                trapRecoveries += 1
                stepResults.append("Trapped: \(reason) — force-quitting and relaunching to recover")
                DebugLog.log("explore",
                    "trapped (\(trapRecoveries)/\(maxTrapRecoveries)): \(reason)")
                if trapRecoveries > maxTrapRecoveries {
                    let report = explorer.generateReport()
                    let snapshot = explorer.graph.finalize()
                    GraphPersistence.save(snapshot: snapshot, bundleID: appName)
                    return .text(
                        "\(stepResults.joined(separator: "\n"))\n\nExploration stopped after " +
                        "\(maxTrapRecoveries) trap recoveries — a screen kept trapping the " +
                        "explorer.\n\n\(report)")
                }
                _ = ctx.lifecycle.forceQuitBeforeExplore(
                    appName: appName, bridge: ctx.bridge,
                    input: ctx.input, describer: ctx.describer)
                if case .failure(let failure) = MirroirMCP.launchAndWait(appName: appName, ctx: ctx) {
                    let report = explorer.generateReport()
                    let snapshot = explorer.graph.finalize()
                    GraphPersistence.save(snapshot: snapshot, bundleID: appName)
                    return .text(
                        "\(stepResults.joined(separator: "\n"))\n\nExploration stopped — could " +
                        "not relaunch after trap: \(failure.message)\n\n\(report)")
                }
                DebugLog.log("explore",
                    "trap recovery: relaunched '\(appName)' to root, continuing")
            }
        }

        // Should not reach here, but just in case
        return .text(stepResults.joined(separator: "\n"))
    }

    /// Emit the runner-consumable `.mirroir/` iOS leg for a finished flow and
    /// return an MCP-text note appended to the result. Returns an empty string
    /// when there is nothing to emit, and a non-fatal note when emit fails.
    static func emitNote(
        appName: String, flow: String, screens: [ExploredScreen], outputDir: String?
    ) -> String {
        guard !screens.isEmpty else { return "" }
        do {
            let result = try MirroirAppTreeEmitter.emit(
                appName: appName, flow: flow, screens: screens, outputDir: outputDir)
            return "\n\n---\nEmitted .mirroir/ iOS leg:\n" +
                "  scenario: \(result.scenarioPath.path) " +
                "(the captured walk; it names an ios surface mirroir-run does not drive)\n" +
                "  baseline: \(result.baselinePath.path) " +
                "(the web leg's cross_surface: step compares its scrape against this)\n" +
                "  plan: \(result.planNote)"
        } catch {
            return "\n\n(emit skipped: \(error.localizedDescription))"
        }
    }

}
