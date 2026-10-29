// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Proves both producers of a .compiled.json fingerprint the same moment: the screen
// ABOUTME: the skill starts from, before step 1 — `mirroir-mcp compile` and get_skill → save_compiled.

import Foundation
import HelperLib
import XCTest
@testable import mirroir_mcp

final class CompiledStartFingerprintTests: XCTestCase {

    private var tmpDir = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = NSTemporaryDirectory() + "start-fingerprint-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    private func screen(_ labels: String...) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: labels.enumerated().map { index, label in
                TapPoint(text: label, tapX: 200, tapY: 120 + Double(index) * 60, confidence: 0.9)
            },
            screenshotBase64: "img")
    }

    private func fingerprint(_ result: ScreenDescriber.DescribeResult) -> ScreenFingerprint {
        StructuralFingerprint.buildScreenFingerprint(elements: result.elements, icons: result.icons)
    }

    private var homeScreen: ScreenDescriber.DescribeResult {
        screen("Phone", "Mail", "Safari", "Music")
    }

    private var endScreen: ScreenDescriber.DescribeResult {
        screen("Alarms", "World Clock", "Stopwatch", "Timer")
    }

    private func writeSkill(_ name: String, _ content: String) throws -> String {
        let path = tmpDir + "/" + name
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func target(ocr: StubDescriber) -> any Target {
        makeTestRegistry(bridge: StubBridge(), input: StubInput(), ocrDescriber: ocr).activeTarget
    }

    // MARK: - mirroir-mcp compile

    func testCompileCommandFingerprintsTheScreenBeforeStepOne() throws {
        let path = try writeSkill("clock.yaml", "name: Clock\nsteps:\n  - assert_visible: \"Timer\"\n")
        let describer = StubDescriber()
        // The skill starts on the home screen; its step then sees the Clock app.
        describer.describeResults = [homeScreen, endScreen]
        let recording = RecordingDescriber(wrapping: describer)
        let executor = StepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: recording,
            capture: StubCapture(),
            config: StepExecutorConfig(waitForTimeoutSeconds: 1, settlingDelayMs: 0,
                                       screenshotDir: tmpDir, dryRun: false))

        let compiled = try XCTUnwrap(CompileCommand.compileSkill(
            skill: try SkillFileLoader.load(filePath: path), executor: executor,
            recordingDescriber: recording, filePath: path,
            windowWidth: 430, windowHeight: 942, orientation: "portrait"))

        XCTAssertEqual(compiled.screenFingerprint, fingerprint(homeScreen))
        XCTAssertNotEqual(compiled.screenFingerprint, fingerprint(endScreen))
    }

    // MARK: - get_skill → record_step → save_compiled

    func testSaveCompiledFingerprintsTheScreenGetSkillSawNotTheEndScreen() throws {
        let path = try writeSkill("clock.yaml", "name: Clock\nsteps:\n  - launch: \"Clock\"\n")
        let ocr = StubDescriber()
        ocr.describeResults = [homeScreen, endScreen]
        let target = target(ocr: ocr)
        let session = CompilationSession()

        // get_skill serves the skill before the AI runs step 1.
        MirroirMCP.markSkillStart(skillPath: path, content: "name: Clock\n",
                                  session: session, target: target)
        session.record(CompiledStep(index: 0, type: "launch", label: "Clock",
                                    hints: .passthrough()))
        let compiled = try MirroirMCP.compiledSkill(
            skillPath: path, session: session, target: target)

        XCTAssertEqual(compiled.screenFingerprint, fingerprint(homeScreen))
        XCTAssertEqual(ocr.describeCallCount, 1, "save_compiled must not read the end screen")
        XCTAssertEqual(session.stepCount, 0)
        XCTAssertNil(session.startFingerprint(for: path), "saving clears the start screen")
    }

    func testBothProducersRecordTheSameStartScreen() throws {
        let path = try writeSkill("clock.yaml", "name: Clock\nsteps:\n  - assert_visible: \"Timer\"\n")

        let describer = StubDescriber()
        describer.describeResults = [homeScreen, endScreen]
        let recording = RecordingDescriber(wrapping: describer)
        let executor = StepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: recording,
            capture: StubCapture(),
            config: StepExecutorConfig(waitForTimeoutSeconds: 1, settlingDelayMs: 0,
                                       screenshotDir: tmpDir, dryRun: false))
        let cli = try XCTUnwrap(CompileCommand.compileSkill(
            skill: try SkillFileLoader.load(filePath: path), executor: executor,
            recordingDescriber: recording, filePath: path,
            windowWidth: 430, windowHeight: 942, orientation: "portrait"))

        let ocr = StubDescriber()
        ocr.describeResults = [homeScreen, endScreen]
        let target = target(ocr: ocr)
        let session = CompilationSession()
        MirroirMCP.markSkillStart(skillPath: path, content: "name: Clock\n",
                                  session: session, target: target)
        session.record(CompiledStep(index: 0, type: "assert_visible", label: "Timer",
                                    hints: .assertion(delayMs: 10)))
        let mcp = try MirroirMCP.compiledSkill(skillPath: path, session: session, target: target)

        XCTAssertNotNil(cli.screenFingerprint)
        XCTAssertEqual(cli.screenFingerprint, mcp.screenFingerprint)
    }

    // MARK: - CompilationSession start screen

    /// A skill read again mid-run (after context compaction, say) keeps the screen
    /// read before step 1: once a step is recorded, the screen is not the start.
    func testStartScreenIsNotReplacedOnceAStepIsRecorded() throws {
        let session = CompilationSession()
        let start = fingerprint(homeScreen)
        session.markStart(skillPath: "/s.yaml") { start }
        session.record(CompiledStep(index: 0, type: "home", label: nil, hints: .passthrough()))

        var captured = false
        session.markStart(skillPath: "/s.yaml") {
            captured = true
            return self.fingerprint(self.endScreen)
        }

        XCTAssertFalse(captured, "no screen is read once a step is recorded")
        XCTAssertEqual(session.startFingerprint(for: "/s.yaml"), start)
    }

    func testStartScreenBelongsToTheSkillItWasReadFor() {
        let session = CompilationSession()
        let start = fingerprint(homeScreen)
        session.markStart(skillPath: "/a.yaml") { start }

        XCTAssertEqual(session.startFingerprint(for: "/a.yaml"), start)
        XCTAssertNil(session.startFingerprint(for: "/b.yaml"))
    }

    func testSaveWithoutGetSkillStoresNoFingerprintRatherThanTheEndScreen() throws {
        let path = try writeSkill("clock.yaml", "name: Clock\nsteps:\n  - home\n")
        let ocr = StubDescriber()
        ocr.describeResult = endScreen
        let session = CompilationSession()
        session.record(CompiledStep(index: 0, type: "home", label: nil, hints: .passthrough()))

        let compiled = try MirroirMCP.compiledSkill(
            skillPath: path, session: session, target: target(ocr: ocr))

        XCTAssertNil(compiled.screenFingerprint)
        XCTAssertEqual(ocr.describeCallCount, 0)
    }

    func testGameSkillIsNotFingerprinted() {
        let ocr = StubDescriber()
        ocr.describeResult = homeScreen
        let session = CompilationSession()

        MirroirMCP.markSkillStart(skillPath: "/game.md", content: "---\nkind: game\n---\n# Play\n",
                                  session: session, target: target(ocr: ocr))

        XCTAssertEqual(ocr.describeCallCount, 0)
        XCTAssertNil(session.startFingerprint(for: "/game.md"))
    }
}
