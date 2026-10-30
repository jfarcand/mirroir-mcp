// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests how the CLI runners find and replay SKILL.md files: discovery, name resolution, step order.
// ABOUTME: Also checks that recompiling a SKILL.md from the CLI keeps every step intact.

import XCTest
import HelperLib
@testable import mirroir_mcp

extension SkillFileLoaderTests {

    private var yamlTwin: String {
        "name: Login YAML\nsteps:\n  - launch: \"Example\"\n"
    }

    // MARK: - Discovery

    func testDiscoverySkipsAnUncompiledSkillMdAndRunsItsYamlTwin() throws {
        _ = try write("login.md", loginMd)
        let yaml = try write("login.yaml", yamlTwin)

        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: [tmpDir]), [yaml])
    }

    func testDiscoverySkipsAStaleSkillMd() throws {
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: recordedLoginSteps)
        _ = try write("login.md", loginMd + "\nEdited.\n")

        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: [tmpDir]), [])
    }

    func testDiscoveryPrefersACompiledSkillMdOverItsYamlTwin() throws {
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: recordedLoginSteps)
        _ = try write("login.yaml", yamlTwin)

        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: [tmpDir]), [md])
    }

    // MARK: - Name resolution

    func testRunnerNameFallsBackToYamlWhenTheSkillMdIsUncompiled() throws {
        let md = try write("login.md", loginMd)
        let yaml = try write("login.yaml", yamlTwin)

        XCTAssertEqual(RunnerSkillResolver.resolve(name: "login", dirs: [tmpDir]), .run(yaml))
        // The MCP side, which an AI runs, still prefers the SKILL.md.
        XCTAssertEqual(MirroirMCP.resolveSkill(name: "login", dirs: [tmpDir]).path, md)
    }

    func testNameWithExtensionNeverResolvesToItsTwin() throws {
        _ = try write("login.md", loginMd)
        _ = try write("login.yaml", yamlTwin)

        // Not the YAML: the runner loads login.md, whose load says it is not compiled.
        XCTAssertEqual(RunnerSkillResolver.resolve(name: "login.md", dirs: [tmpDir]),
                       .unusable(tmpDir + "/login.md"))
    }

    func testANeverCompiledSkillMdDoesNotMakeItsLegacyYamlAmbiguous() throws {
        try FileManager.default.createDirectory(
            atPath: tmpDir + "/skills/apps", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: tmpDir + "/legacy/apps", withIntermediateDirectories: true)
        _ = try write("skills/apps/check-about.md", loginMd)
        let yaml = try write("legacy/apps/check-about.yaml", yamlTwin)

        // The mirroir-skills layout: a SKILL.md nobody compiled is not a CLI skill yet.
        XCTAssertEqual(RunnerSkillResolver.resolve(name: "check-about", dirs: [tmpDir]), .run(yaml))
    }

    func testRunnerExplainsANameThatIsOnlyAnUncompiledSkillMd() throws {
        let md = try write("login.md", loginMd)

        XCTAssertFalse(SkillFileLoader.isReplayable(filePath: md))
        XCTAssertThrowsError(try SkillFileLoader.load(filePath: md)) { error in
            XCTAssertTrue(error.localizedDescription.contains("has no compiled file"))
        }
    }

    func testASkillMdWithAToolOnlyStepIsRefusedByNameAndSkippedWithItsReasonOtherwise() throws {
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "press_back", label: nil, hints: nil),
        ])
        let yaml = try write("other.yaml", "name: Other\nsteps:\n  - home\n")

        XCTAssertEqual(SkillFileLoader.unreadableStep(filePath: md),
                       "step 0 (press_back): unknown step type")
        // Named: refused before running. Picked up implicitly: skipped, the rest runs.
        XCTAssertEqual(TestRunner.run(arguments: ["--dry-run", md]), 1)
        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: [tmpDir]), [yaml])
        XCTAssertEqual(try TestRunner.resolveSkillFiles([tmpDir + "/*"]), [yaml])
    }

    func testAYamlTwinRunsWhenItsSkillMdIsSkippedForAToolOnlyStep() throws {
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "press_back", label: nil, hints: nil),
        ])
        let yaml = try write("login.yaml", yamlTwin)

        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: [tmpDir]), [yaml])
    }

    func testSwitchTargetWithABareNameStillReplaysLive() {
        XCTAssertEqual(MirroirMCP.deriveHints(
            type: "switch_target", tapX: nil, tapY: nil, matchStrategy: nil,
            elapsedMs: nil, scrollCount: nil, scrollDirection: nil)?.compiledAction, .passthrough)
    }

    func testStoredLabelKeepsSecretsOutForEveryKindOfStep() {
        setenv("MIRROIR_LOADER_TEST_PASS", "hunter2", 1)
        defer { unsetenv("MIRROIR_LOADER_TEST_PASS") }
        let source = "Type ${MIRROIR_LOADER_TEST_PASS}"

        XCTAssertEqual(MirroirMCP.storedLabel("\"hunter2\"", type: "type", source: source),
                       "${MIRROIR_LOADER_TEST_PASS}")
        // A tool with no skill step type keeps its label, secret swapped all the same.
        XCTAssertEqual(MirroirMCP.storedLabel("hunter2", type: "type_text", source: source),
                       "${MIRROIR_LOADER_TEST_PASS}")
        // An incomplete label is kept as recorded rather than rewritten into something else.
        XCTAssertEqual(MirroirMCP.storedLabel("login_time", type: "measure", source: source),
                       "login_time")
    }

    func testSwitchTargetIsTheTargetStep() {
        let step = SkillParser.parseStep(key: "switch_target", rawValue: "{ kind: ios, app: \"Notes\" }")
        XCTAssertEqual(step.typeKey, "target")
        XCTAssertEqual(MirroirMCP.deriveHints(
            type: step.typeKey, tapX: nil, tapY: nil, matchStrategy: nil,
            elapsedMs: nil, scrollCount: nil, scrollDirection: nil)?.compiledAction, .passthrough)
    }

    func testAMeasureTimingAnUnreadableActionIsRefusedBeforeRunning() throws {
        let measure = SkillParser.parseStep(
            key: "measure", rawValue: "{ wiat_for: \"Home\", until: \"Dashboard\" }")
        let skill = SkillDefinition(name: "m", description: "", filePath: "m.yaml",
                                    steps: [measure], targets: [], kind: "")

        let findings = InvalidStepGate.scan(skills: [skill])

        XCTAssertEqual(findings.map(\.stepType), ["measure"])
        XCTAssertTrue(findings.first?.reason.contains("wiat_for") == true)
    }

    // MARK: - Step order

    func testAGapInRecordedIndicesIsRefused() throws {
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "home", label: nil, hints: .passthrough()),
            CompiledStep(index: 2, type: "shake", label: nil, hints: .passthrough()),
        ])

        XCTAssertThrowsError(try SkillFileLoader.load(filePath: md)) { error in
            guard case SkillFileLoaderError.staleCompiled(_, let reason) = error else {
                return XCTFail("expected staleCompiled, got \(error)")
            }
            XCTAssertTrue(reason.contains("index 1"), reason)
        }
    }

    func testOutOfOrderAndRetriedRecordsReplayOnePerIndexInOrder() throws {
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "tap", label: "General",
                         hints: .tap(x: 1, y: 1, strategy: "exact")),
            CompiledStep(index: 2, type: "tap", label: "About",
                         hints: .tap(x: 3, y: 3, strategy: "exact")),
            CompiledStep(index: 1, type: "wait_for", label: "General", hints: .passthrough()),
            CompiledStep(index: 2, type: "tap", label: "About",
                         hints: .tap(x: 4, y: 4, strategy: "exact")),
        ])

        let compiled = try XCTUnwrap(CompiledSkillIO.load(for: md))
        let skill = try SkillFileLoader.load(filePath: md)

        XCTAssertEqual(compiled.steps.map(\.index), [0, 1, 2])
        XCTAssertEqual(compiled.steps[2].hints?.tapX, 4)
        XCTAssertEqual(skill.steps.map(\.typeKey), compiled.steps.map(\.type))
    }

    func testSessionSavesOneRecordPerIndexInOrder() {
        let session = CompilationSession()
        session.record(CompiledStep(index: 1, type: "tap", label: "B", hints: nil))
        session.record(CompiledStep(index: 0, type: "tap", label: "A", hints: nil))
        session.record(CompiledStep(index: 1, type: "tap", label: "B2", hints: nil))

        XCTAssertEqual(session.finalizeAndClear().map(\.label), ["A", "B2"])
    }

    func testScrollReplaysInTheRecordedDirection() throws {
        let md = try write("privacy.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "scroll_to", label: "Privacy",
                         hints: .scrollSequence(count: 3, direction: "down")),
        ])

        guard case .scrollTo(let label, let direction, _) =
                try SkillFileLoader.load(filePath: md).steps.first else {
            return XCTFail("expected a scroll_to step")
        }
        XCTAssertEqual(label, "Privacy")
        XCTAssertEqual(direction, "down")
    }

    // MARK: - Recompiling from the CLI

    func testRecompilingASkillMdKeepsEveryStepIntact() throws {
        let md = try write("shortcuts.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "press_key", label: "l+command", hints: .passthrough()),
            CompiledStep(index: 1, type: "wait_for", label: "\"Address\" timeout: 30",
                         hints: .passthrough()),
            CompiledStep(index: 2, type: "long_press", label: "\"Photo\" duration: 1500",
                         hints: .passthrough()),
        ])
        let before = try SkillFileLoader.load(filePath: md)

        let describer = StubDescriber()
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Address", tapX: 100, tapY: 100, confidence: 0.99),
                       TapPoint(text: "Photo", tapX: 200, tapY: 300, confidence: 0.99)],
            screenshotBase64: "")
        let recording = RecordingDescriber(wrapping: describer)
        let executor = StepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: recording,
            capture: StubCapture(),
            config: StepExecutorConfig(waitForTimeoutSeconds: 1, settlingDelayMs: 0,
                                       screenshotDir: tmpDir, dryRun: false))
        let recompiled = try XCTUnwrap(CompileCommand.compileSkill(
            skill: before, executor: executor, recordingDescriber: recording,
            filePath: md, windowWidth: 430, windowHeight: 942, orientation: "portrait"))
        try CompiledSkillIO.save(recompiled, for: md)

        let after = try SkillFileLoader.load(filePath: md)
        XCTAssertEqual(after.steps.map { String(describing: $0) },
                       before.steps.map { String(describing: $0) })
        // A long press replays live: a compiled tap would make it a short tap.
        XCTAssertEqual(recompiled.steps[2].hints?.compiledAction, .passthrough)
    }
}
