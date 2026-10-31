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
                return unfinished(
                    "\(summary)\n\nExploration paused after \(stats.actionCount) actions, " +
                    "\(stats.nodeCount) screens in \(stats.elapsedSeconds)s.\n\n\(report)",
                    outcome: "paused: \(reason)", appName: appName, emit: emit)
            case .finished(let bundle):
                // Persist the completed graph for future incremental runs
                let snapshot = explorer.graph.finalize()
                GraphPersistence.save(snapshot: snapshot, bundleID: appName)
                var resultText = ExplorationResultFormatter.formatExploreResult(
                    bundle: bundle, explorer: explorer)
                if emit {
                    // Emit every interesting path as its own iOS flow.
                    let flows = GraphPathFinder.findInterestingPaths(in: snapshot).map {
                        MirroirAppTreeEmitter.Flow(
                            name: $0.name,
                            screens: GraphPathFinder.pathToExploredScreens(
                                path: $0.edges, snapshot: snapshot))
                    }
                    do {
                        resultText += try emitNote(
                            appName: appName, flows: flows, outputDir: outputDir)
                    } catch {
                        return emitFailure(resultText: resultText, error: error)
                    }
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
                    return unfinished(
                        "\(stepResults.joined(separator: "\n"))\n\nExploration stopped after " +
                        "\(maxTrapRecoveries) trap recoveries — a screen kept trapping the " +
                        "explorer.\n\n\(report)",
                        outcome: "stopped after \(maxTrapRecoveries) trap recoveries",
                        appName: appName, emit: emit)
                }
                _ = ctx.lifecycle.forceQuitBeforeExplore(
                    appName: appName, bridge: ctx.bridge,
                    input: ctx.input, describer: ctx.ocrDescriber)
                if case .failure(let failure) = MirroirMCP.launchAndWait(appName: appName, ctx: ctx) {
                    let report = explorer.generateReport()
                    let snapshot = explorer.graph.finalize()
                    GraphPersistence.save(snapshot: snapshot, bundleID: appName)
                    return unfinished(
                        "\(stepResults.joined(separator: "\n"))\n\nExploration stopped — could " +
                        "not relaunch after trap: \(failure.message)\n\n\(report)",
                        outcome: "could not relaunch after trap: \(failure.message)",
                        appName: appName, emit: emit)
                }
                DebugLog.log("explore",
                    "trap recovery: relaunched '\(appName)' to root, continuing")
            }
        }

        // The explorer reported completion without a `.finished` step result.
        return unfinished(
            stepResults.joined(separator: "\n"),
            outcome: "completed without a finished result", appName: appName, emit: emit)
    }

    /// The result for an exploration that stopped short of `.finished`: its
    /// text as-is when no emit was asked for, an emit failure when one was —
    /// an emit that wrote nothing is never a success.
    static func unfinished(
        _ resultText: String, outcome: String, appName: String, emit: Bool
    ) -> MCPToolResult {
        guard emit else { return .text(resultText) }
        return emitFailure(
            resultText: resultText,
            error: MirroirAppTreeEmitter.EmitError.explorationUnfinished(
                appName: appName, outcome: outcome))
    }

    /// Emit the runner-consumable `.mirroir/` iOS leg for `flows` and return
    /// the MCP-text note appended to the result.
    ///
    /// - Throws: whatever `MirroirAppTreeEmitter.emit` throws — an empty walk,
    ///   no consumer root, no flow the scenario grammar can express. The
    ///   caller turns it into an error result: an emit that was asked for and
    ///   wrote nothing is a failure, never a note on a success.
    static func emitNote(
        appName: String, flows: [MirroirAppTreeEmitter.Flow], outputDir: String?
    ) throws -> String {
        let result = try MirroirAppTreeEmitter.emit(
            appName: appName, flows: flows, outputDir: outputDir)
        let scenarios = result.scenarioPaths.map { "    \($0.path)" }.joined(separator: "\n")
        let dropped = result.dropped.isEmpty ? "" :
            "  dropped (a step no replay can perform; no scenario written):\n" +
            MirroirAppTreeEmitter.droppedList(result.dropped) + "\n"
        return "\n\n---\nEmitted .mirroir/ iOS leg:\n" +
            "  scenarios (ios blocks mirroir-run hands to mirroir-mcp test on macOS):\n" +
            "\(scenarios)\n" + dropped +
            "  sample: \(result.sampleNote)\n" +
            "  plan: \(result.planNote)\n" +
            "  drift defaults: \(result.driftDefaultsNote)\n" +
            "  run it: mirroir-run (from the consumer repo, iPhone Mirroring connected)"
    }

    /// `result` with `note` closing its first text block, under a rule;
    /// `result` unchanged when `note` is nil. Error status is kept.
    static func appendingNote(_ note: String?, to result: MCPToolResult) -> MCPToolResult {
        guard let note else { return result }
        var content = result.content
        if let index = content.firstIndex(where: {
            if case .text = $0 { return true }
            return false
        }), case .text(let text) = content[index] {
            content[index] = .text(text + "\n\n---\n" + note)
        } else {
            content.insert(.text(note), at: 0)
        }
        return MCPToolResult(content: content, isError: result.isError)
    }

    /// The error result for an `emit: true` call whose emit failed: the
    /// exploration's own text, then why nothing runnable was written, then
    /// `trailer` — guidance the caller still needs, such as the next goal.
    static func emitFailure(resultText: String, error: Error, trailer: String = "") -> MCPToolResult {
        .error("\(resultText)\n\n---\nemit failed: \(error.localizedDescription)\(trailer)")
    }

}
