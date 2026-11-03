// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
// ABOUTME: Integration test playing the real SceneLoop against FakeMirroring's Scene Frames pack: real OCR, real taps.
// ABOUTME: Proves the CI scene skills' calibrated controls land and the predicates read the frames; the model is a stub.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Stands in for the scene's vision model, which is paid and non-deterministic:
/// it names the same control on every frame, with a fixed token cost.
private struct ScriptedVision: VisionCompleting {
    let model = "scene-stub"
    let control: String

    func complete(systemPrompt: String, image: ChatCompletionImage, timeoutSeconds: Int) -> ChatCompletionReply? {
        ChatCompletionReply(
            text: #"{"control": "\#(control)", "rationale": "scripted"}"#,
            usage: ChatCompletionUsage(promptTokens: 24000, completionTokens: 50, totalTokens: 24050),
            responseModel: model)
    }
}

final class SceneLoopIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
        guard IntegrationTestHelper.ensureWindowReady(bridge: bridge) else {
            throw IntegrationTestError.windowNotCapturable
        }
        // A cold Scene Frames, on its first frame.
        IntegrationTestHelper.resetScenario(bridge: bridge, to: "Scene Frames")
        usleep(800_000)
    }

    override func tearDown() {
        if let bridge = bridge {
            IntegrationTestHelper.resetScenario(bridge: bridge, to: "Settings")
            usleep(500_000)
            IntegrationTestHelper.ensureWindowReady(bridge: bridge)
        }
        super.tearDown()
    }

    /// The CI scene skill as checked in beside the sample that runs it.
    private func header() throws -> SceneHeader {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runner/samples/game-scene/skills/scene-frames-reach.md").path
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return try SceneHeaderParser.parse(content: content, name: "scene-frames-reach").get()
    }

    private func play(control: String) throws -> SceneReport {
        let capture = ScreenCapture(bridge: bridge)
        let describer = ScreenDescriber(bridge: bridge, capture: capture)
        let loop = SceneLoop(dependencies: .init(
            bridge: bridge, describer: describer,
            input: InputSimulation(bridge: bridge, pasteVerifier: describer),
            vision: ScriptedVision(control: control),
            now: { CFAbsoluteTimeGetCurrent() }, sleep: { usleep($0) },
            settleMs: 500, imageWidth: 400, callTimeoutSeconds: 30))
        let evidence = SceneEvidenceWriter(
            baseDir: NSTemporaryDirectory() + "mirroir-scene-integration-\(UUID().uuidString)",
            skillName: "scene-frames-reach", stepIndex: 0)
        return loop.run(
            header: try header(),
            budget: SceneBudget(maxFrames: 6, maxTokens: 400000, maxSeconds: 120),
            evidence: evidence)
    }

    func testMovingWalksTheFramesToTheGoal() throws {
        let report = try play(control: "move")
        XCTAssertEqual(report.verdict, .pass, "reason \(report.reason.rawValue), evidence \(report.evidenceDir)")
        XCTAssertEqual(report.framesToPredicate, 3, "MOVE on frames 1, 2 and 3 reaches GOAL")
        XCTAssertEqual(report.totalTokens, 3 * 24050)
        let log = try String(
            contentsOfFile: (report.evidenceDir as NSString).appendingPathComponent("frames.jsonl"),
            encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 3, "one evidence line per frame")
    }

    func testFiringOnTheFirstFrameMeetsTheFailPredicate() throws {
        let report = try play(control: "fire")
        XCTAssertEqual(report.verdict, .fail, "reason \(report.reason.rawValue), evidence \(report.evidenceDir)")
        XCTAssertEqual(report.reason, .fail)
        XCTAssertEqual(report.frames, 1)
    }
}
