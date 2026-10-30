// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that generate_skill with emit=true never returns a success that wrote nothing.
// ABOUTME: Covers an explore that pauses and a multi-goal finish whose emit fails.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// An explorer that pauses on its first step, standing in for a calibration
/// or capture failure the real explorers report as `.paused`.
private final class PausingExplorer: Exploring, @unchecked Sendable {
    let graph: any NavigationGraphing = NavigationGraph()
    private(set) var completed = false

    func step<S: ExplorationStrategy>(
        describer: ScreenDescribing, input: InputProviding, strategy: S.Type
    ) -> ExploreStepResult {
        completed = true
        return .paused(reason: "calibration failed")
    }

    func markStarted() {}

    var stats: (nodeCount: Int, edgeCount: Int, actionCount: Int, elapsedSeconds: Int) {
        (0, 0, 0, 0)
    }

    func generateBundle() -> SkillBundle {
        SkillBundle(appName: "Paused", skills: [], manifest: nil)
    }

    func generateReport() -> String { "report" }
}

final class ExploreEmitResultTests: XCTestCase {

    private func resultText(_ result: MCPToolResult) -> String {
        result.content.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }

    private func runPausing(emit: Bool) throws -> MCPToolResult {
        let appName = "mirroir-paused-\(UUID().uuidString)"
        defer { GraphPersistence.delete(bundleID: appName) }
        let ctx = try XCTUnwrap(makeTestRegistry(bridge: StubBridge(), input: StubInput()).resolve())
        return ExplorationLoopRunner.run(
            explorer: PausingExplorer(), strategyChoice: .mobile, ctx: ctx,
            appName: appName, emit: emit, outputDir: nil, initialLines: [])
    }

    /// A paused explore asked to emit is an error naming why nothing was
    /// written; without emit it stays the plain paused report.
    func testAPausedExploreWithEmitIsAnError() throws {
        let emitted = try runPausing(emit: true)
        XCTAssertTrue(emitted.isError, resultText(emitted))
        XCTAssertTrue(resultText(emitted).contains("Exploration paused after"), resultText(emitted))
        XCTAssertTrue(resultText(emitted).contains(
            "emit failed: emit requested but the exploration of mirroir-paused-"), resultText(emitted))
        XCTAssertTrue(resultText(emitted).contains(
            "did not finish (paused: calibration failed); nothing was emitted"), resultText(emitted))

        let plain = try runPausing(emit: false)
        XCTAssertFalse(plain.isError, resultText(plain))
        XCTAssertFalse(resultText(plain).contains("emit failed"), resultText(plain))
    }

    /// finish has already advanced the goal queue when its emit fails, so the
    /// error still tells the agent the session moved on to the next goal.
    func testAFailedEmitOnFinishStillNamesTheNextGoal() {
        let session = ExplorationSession()
        session.start(appName: "Clock", goal: "", goals: ["add alarm", "set timer"])
        _ = session.capture(
            elements: [TapPoint(text: "Alarms", tapX: 100, tapY: 100, confidence: 0.95)],
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "")
        _ = session.capture(
            elements: [TapPoint(text: "Cancel", tapX: 50, tapY: 100, confidence: 0.95)],
            hints: [], actionType: "remember", arrivedVia: "note", screenshotBase64: "")

        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-goals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let result = MirroirMCP.handleFinish(session: session, emit: true, outputDir: base.path)

        XCTAssertTrue(result.isError, resultText(result))
        let text = resultText(result)
        XCTAssertTrue(text.contains("emit failed: emit requested but no flow of Clock can replay"), text)
        XCTAssertTrue(text.contains(": step 1: \"remember\" is an AI-only step"), text)
        XCTAssertTrue(text.contains("Goal 1/2 complete. Next goal: \"set timer\"."), text)
        XCTAssertTrue(session.active, "the session advanced to the next goal")
    }
}
