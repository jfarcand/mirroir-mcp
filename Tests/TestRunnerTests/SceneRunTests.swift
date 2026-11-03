// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests how a scene: step runs in mirroir test: the gate before any step, the report the runner reads, never compiled.
// ABOUTME: The report bytes are pinned to runner/src/target fixtures that the Rust contract tests read too.

import HelperLib
import XCTest
@testable import mirroir_mcp

final class SceneRunTests: XCTestCase {

    private var tmpDir = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "scene-run-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    private func write(_ name: String, _ content: String) throws -> String {
        let path = (tmpDir as NSString).appendingPathComponent(name)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private let budget = SceneBudget(maxFrames: 3, maxTokens: 200000, maxSeconds: 60)

    private func report(verdict: SceneVerdict, reason: SceneStopReason, skill: String) -> SceneReport {
        SceneReport(
            skill: skill, verdict: verdict, reason: reason, frames: 3,
            framesToPredicate: verdict == .pass ? 3 : nil,
            promptTokens: 72000, completionTokens: 150, totalTokens: 72150, seconds: 12.5,
            model: "scene-stub", responseModel: "scene-stub", rejectedReplies: 0,
            evidenceDir: "/tmp/mirroir-scene/scene-2")
    }

    private func result(skill: String, report scene: SceneReport, status: StepResult.StepStatus)
        -> ConsoleReporter.SkillResult {
        ConsoleReporter.SkillResult(
            name: skill, filePath: "\(skill).yaml",
            stepResults: [
                StepResult(step: .switchTarget(.ios(app: "Scene Frames")), status: .passed,
                           message: nil, durationSeconds: 0.5),
                StepResult(step: .launch(appName: "Scene Frames"), status: .passed,
                           message: nil, durationSeconds: 0.5),
                StepResult(step: .scene(skill: skill, budget: budget), status: status,
                           message: scene.failureLine, durationSeconds: 12, scene: scene),
            ],
            durationSeconds: 13)
    }

    // MARK: - Report contract

    func testAPassingSceneReportMatchesTheRunnerFixture() throws {
        let passing = result(
            skill: "scene-frames-reach",
            report: report(verdict: .pass, reason: .success, skill: "scene-frames-reach"),
            status: .passed)
        XCTAssertTrue(passing.passed)
        let data = try PlaywrightReportWriter.document(
            results: [passing], screenCaptures: [0: "GOAL\n"], captureKey: "ios")
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       try runnerFixture("mirroir-mcp-report-scene-pass.json"))
    }

    func testAnInconclusiveSceneReportMatchesTheRunnerFixture() throws {
        let inconclusive = result(
            skill: "scene-frames-impossible",
            report: report(verdict: .inconclusive, reason: .maxFrames, skill: "scene-frames-impossible"),
            status: .inconclusive)
        XCTAssertFalse(inconclusive.passed, "an inconclusive scene never passes its skill")
        let data = try PlaywrightReportWriter.document(
            results: [inconclusive], screenCaptures: [0: "MOVE FIRE\n"], captureKey: "ios")
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       try runnerFixture("mirroir-mcp-report-scene-inconclusive.json"))
    }

    private func runnerFixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runner/src/target/fixtures")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Gate

    private func skill(_ steps: [SkillStep]) -> SkillDefinition {
        SkillDefinition(name: "play", description: "", filePath: "play.yaml", steps: steps,
                        targets: [], kind: "")
    }

    private let header = SceneHeader(
        name: "reach", budget: SceneBudget(maxFrames: 10, maxTokens: 400000, maxSeconds: 180),
        controls: [SceneControl(name: "move", gesture: .tap(x: 0.2, y: 0.5))],
        objective: "Reach GOAL.", success: .visible("GOAL"), fail: nil)

    func testAPlayableSceneIsNotRefused() {
        let refusals = SceneStepGate.refusals(
            skills: [skill([.scene(skill: "reach", budget: budget)])], visionAvailable: true,
            load: { _ in .success(self.header) })
        XCTAssertEqual(refusals, [])
    }

    func testEveryUnplayableSceneIsRefusedBeforeAnyStep() {
        let wide = SceneBudget(maxFrames: 20, maxTokens: 400000, maxSeconds: 600)
        let refusals = SceneStepGate.refusals(
            skills: [skill([
                .scene(skill: "missing", budget: budget),
                .scene(skill: "reach", budget: wide),
                .measure(name: "m", action: .scene(skill: "reach", budget: budget), until: "GOAL",
                         maxSeconds: nil),
            ])],
            visionAvailable: false,
            load: { $0 == "missing" ? .failure(.notFound(name: $0)) : .success(self.header) })
        XCTAssertEqual(refusals.map(\.stepNumber), [1, 1, 2, 2, 3], "each scene step is refused for each reason")
        XCTAssertTrue(refusals[0].reason.contains("no vision model"), refusals[0].reason)
        XCTAssertTrue(refusals[1].reason.contains("no kind:game skill named 'missing'"), refusals[1].reason)
        XCTAssertTrue(refusals[3].reason.contains("max_frames, max_seconds exceed"), refusals[3].reason)
        XCTAssertTrue(refusals.last?.reason.contains("measure") ?? false)
    }

    func testASceneSkillIsFoundByNameAndAnOrdinarySkillIsNotOne() throws {
        _ = try write("reach.md", """
            ---
            version: 1
            name: Reach
            kind: game
            surface: scene
            playable: single-control
            controls: [move]
            budget: { max_frames: 10, max_tokens: 400000, max_seconds: 180 }
            success: { visible: "GOAL" }
            ---

            ## Objective

            Reach GOAL.

            ## Controls

            - move: tap at 0.2,0.5
            """)
        _ = try write("plain.yaml", "name: plain\napp: X\ndescription: d\nsteps:\n  - home\n")
        let loaded = try SceneSkills.load(name: "reach", dirs: [tmpDir]).get()
        XCTAssertEqual(loaded.success, .visible("GOAL"))
        guard case .failure(.notAGame) = SceneSkills.load(name: "plain", dirs: [tmpDir]) else {
            return XCTFail("an ordinary skill played as a scene")
        }
        guard case .failure(.notFound) = SceneSkills.load(name: "absent", dirs: [tmpDir]) else {
            return XCTFail("a missing scene skill was found")
        }
    }

    // MARK: - Execution

    func testADryRunNeverPassesAScene() {
        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 1, settlingDelayMs: 0, screenshotDir: tmpDir, dryRun: true)
        let executor = StepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: StubDescriber(),
            capture: StubCapture(), config: config)
        let result = executor.execute(
            step: .scene(skill: "reach", budget: budget), stepIndex: 0, skillName: "play")
        XCTAssertEqual(result.status, .notEvaluated)
    }

    func testASceneWithoutAVisionModelFails() {
        let config = StepExecutorConfig(
            waitForTimeoutSeconds: 1, settlingDelayMs: 0, screenshotDir: tmpDir, dryRun: false)
        let executor = StepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: StubDescriber(),
            capture: StubCapture(), config: config)
        let result = executor.execute(
            step: .scene(skill: "reach", budget: budget), stepIndex: 0, skillName: "play")
        XCTAssertEqual(result.status, .failed)
    }

    func testInconclusiveFailsAndStopsTheSkill() {
        XCTAssertTrue(StepResult.StepStatus.inconclusive.isFailure)
        XCTAssertFalse(StepResult.StepStatus.notEvaluated.isFailure)
        XCTAssertFalse(StepResult.StepStatus.skipped.isFailure)
    }

    func testAKindGameSkillGivenToMirroirTestIsAHardRefusal() throws {
        let game = try write("game.md", "---\nname: Game\nkind: game\n---\n\nWatch.\n")
        let plain = try write("plain.yaml", "name: plain\napp: X\ndescription: d\nsteps:\n  - home\n")
        XCTAssertEqual(TestRunner.run(arguments: ["--dry-run", plain, game]), 1,
                       "a game skill beside an ordinary one must not let the run pass")
    }

    // MARK: - Never compiled

    func testACompiledSceneStepIsRefused() {
        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: "x", compiledAt: "2026-11-03T00:00:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: [CompiledStep(index: 0, type: "scene",
                                 label: "{ skill: reach, max_frames: 1, max_tokens: 1, max_seconds: 1 }",
                                 hints: StepHints.passthrough())])
        guard case .invalid(_, let reason) = SkillFileLoader.steps(from: compiled).first else {
            return XCTFail("a compiled scene step would be played")
        }
        XCTAssertTrue(reason.contains("never compiled"), reason)
    }

    func testASceneStepIsNeverRecorded() {
        XCTAssertNotNil(MirroirMCP.recordProblem(.scene(skill: "reach", budget: budget)))
    }

    // MARK: - Vision request

    func testTheVisionClientSendsTheFrameAndReadsUsageAndModel() throws {
        final class Captured: @unchecked Sendable { var body: Data? }
        let captured = Captured()
        let config = AgentConfig(
            name: "stub", mode: .api, provider: .openai, model: "scene-model",
            apiKeyEnvVar: nil, baseURL: "http://127.0.0.1:1", systemPrompt: nil,
            maxTokens: 300, command: nil, args: nil)
        let client = AgentVisionClient(agentConfig: config, send: { _, _, _, body, _ in
            captured.body = body
            return Data(#"{"model":"scene-model-2026","choices":[{"message":{"content":"{}"}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#.utf8)
        })
        let reply = client.complete(
            systemPrompt: "play", image: ChatCompletionImage(pngBase64: "aGk=", caption: "Frame 1."),
            timeoutSeconds: 5)
        XCTAssertEqual(reply?.usage?.totalTokens, 12)
        XCTAssertEqual(reply?.responseModel, "scene-model-2026")
        let body = try XCTUnwrap(captured.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "scene-model")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "play")
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Frame 1.")
        let image = try XCTUnwrap(content.last?["image_url"] as? [String: Any])
        XCTAssertEqual(image["url"] as? String, "data:image/png;base64,aGk=")
    }
}
