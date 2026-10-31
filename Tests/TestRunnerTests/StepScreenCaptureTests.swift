// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests `mirroir test` per-step screen capture: the --compiled-out flags, the report's screens and device,
// ABOUTME: and the compiled skill a passing run records — written only for a pass, never for a failure.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class StepScreenCaptureTests: XCTestCase {

    private var tmpDir = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = NSTemporaryDirectory() + "step-screens-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    private func write(_ name: String, _ content: String) throws -> String {
        let path = tmpDir + "/" + name
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func parseError(_ args: [String]) -> TestRunnerArgumentError? {
        do {
            _ = try TestRunner.parseArguments(args)
            return nil
        } catch {
            return error as? TestRunnerArgumentError
        }
    }

    // MARK: - Arguments

    func testCompiledFlagsParseTogether() throws {
        let config = try TestRunner.parseArguments(
            ["--compiled-out", "out.compiled.json", "--compiled-source", "x.ios.yaml", "block.yaml"])
        XCTAssertEqual(config.compiledOutPath, "out.compiled.json")
        XCTAssertEqual(config.compiledSourcePath, "x.ios.yaml")
        XCTAssertEqual(config.skillArgs, ["block.yaml"])
    }

    func testNeitherCompiledFlagLeavesBothUnset() throws {
        let config = try TestRunner.parseArguments(["block.yaml"])
        XCTAssertNil(config.compiledOutPath)
        XCTAssertNil(config.compiledSourcePath)
    }

    func testCompiledOutAloneIsRefused() {
        XCTAssertEqual(parseError(["--compiled-out", "o.json", "block.yaml"]),
                       .compiledFlagWithoutPartner(given: "--compiled-out", missing: "--compiled-source"))
    }

    func testCompiledSourceAloneIsRefused() {
        XCTAssertEqual(parseError(["--compiled-source", "x.yaml", "block.yaml"]),
                       .compiledFlagWithoutPartner(given: "--compiled-source", missing: "--compiled-out"))
    }

    func testCompiledOutWithTwoSkillsIsRefused() {
        XCTAssertEqual(parseError(["--compiled-out", "o.json", "--compiled-source", "x.yaml",
                                   "a.yaml", "b.yaml"]),
                       .compiledOutNeedsOneSkill(count: 2))
    }

    func testCompiledOutWithNoSkillIsRefused() {
        XCTAssertEqual(parseError(["--compiled-out", "o.json", "--compiled-source", "x.yaml"]),
                       .compiledOutNeedsOneSkill(count: 0))
    }

    func testCompiledOutWithDryRunIsRefused() {
        XCTAssertEqual(parseError(["--dry-run", "--compiled-out", "o.json",
                                   "--compiled-source", "x.yaml", "a.yaml"]),
                       .dryRunWithCompiledOut)
    }

    /// One argument that resolves to two skills (a glob) is refused before
    /// anything runs, and no compiled file appears.
    func testCompiledOutWithAGlobOfTwoSkillsRefusesTheRun() throws {
        _ = try write("a.yaml", "name: A\nsteps:\n  - home\n")
        _ = try write("b.yaml", "name: B\nsteps:\n  - home\n")
        let out = tmpDir + "/out.compiled.json"
        let code = TestRunner.run(arguments: [
            "--compiled-out", out, "--compiled-source", tmpDir + "/a.yaml", tmpDir + "/*.yaml",
        ])
        XCTAssertEqual(code, TestRunner.usageExitCode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    // MARK: - Recorder

    func testTheWalkRecordsTheStartAndEveryStepScreen() throws {
        let skill = try SkillFileLoader.load(filePath: try write("walk.yaml", ClockWalkDouble.skillYAML))
        let (result, screens) = ClockWalkDouble().run(skill)

        XCTAssertTrue(result.passed, result.failureReasons.joined(separator: "\n"))
        XCTAssertEqual(screens.start?.structuralTexts, ClockWalkDouble.home.sorted())
        XCTAssertEqual(screens.afterStep[0]?.structuralTexts, ClockWalkDouble.home.sorted())
        XCTAssertEqual(screens.afterStep[1]?.structuralTexts, ClockWalkDouble.alarms.sorted())
        XCTAssertEqual(screens.afterStep[2]?.structuralTexts, ClockWalkDouble.worldClock.sorted())
        XCTAssertEqual(screens.afterStep[3]?.structuralTexts, ClockWalkDouble.worldClock.sorted())
        XCTAssertEqual(screens.reportMap.keys.sorted(), ["0", "1", "2", "3", "start"])
    }

    /// A failed step left a screen and is read; the steps skipped after it are not.
    func testAFailedStepIsReadAndSkippedStepsAreNot() throws {
        let yaml = "name: Miss\nsteps:\n  - launch: \"Clock\"\n  - tap: \"Bedtime\"\n  - tap: \"Edit\"\n"
        let skill = try SkillFileLoader.load(filePath: try write("miss.yaml", yaml))
        let (result, screens) = ClockWalkDouble().run(skill)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(screens.afterStep.keys.sorted(), [0, 1])
    }

    // MARK: - Report

    func testReportCarriesScreensAndDeviceBesideTheCapture() throws {
        let fingerprint = StructuralFingerprint.buildScreenFingerprint(
            elements: ClockWalkDouble.elements(["Alarms", "Edit"]), icons: [])
        let screens = StepScreens(start: fingerprint, afterStep: [0: fingerprint])
        let data = try PlaywrightReportWriter.document(
            results: [skillResult()], screenCaptures: [0: "Alarms Edit\n"], captureKey: "ios",
            stepScreens: [0: screens],
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"))
        let captures = try decodeCaptures(data)

        let reported = try XCTUnwrap(captures["screens"] as? [String: [String: Any]])
        XCTAssertEqual(reported.keys.sorted(), ["0", "start"])
        let start = try XCTUnwrap(reported["start"])
        XCTAssertEqual(start["hash"] as? String, fingerprint.hash)
        XCTAssertEqual(start["iconCount"] as? Int, 0)
        XCTAssertEqual(start["structuralTexts"] as? [String], ["Alarms", "Edit"])
        let device = try XCTUnwrap(captures["device"] as? [String: Any])
        XCTAssertEqual(device["windowWidth"] as? Double, 410)
        XCTAssertEqual(device["windowHeight"] as? Double, 898)
        XCTAssertEqual(device["orientation"] as? String, "portrait")
    }

    /// A run that recorded no screens writes the captures a reader that
    /// predates them has always read: no `screens`, no `device`.
    func testReportWithoutScreensLeavesBothKeysOut() throws {
        let device = DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait")
        for stepScreens in [[:], [0: StepScreens()]] as [[Int: StepScreens]] {
            let captures = try decodeCaptures(try PlaywrightReportWriter.document(
                results: [skillResult()], screenCaptures: [:], captureKey: "ios",
                stepScreens: stepScreens, device: device))
            XCTAssertEqual(captures.keys.sorted(), ["cross_surface", "metrics"])
        }
    }

    // MARK: - Compiled skill

    func testAPassingRunWritesTheCompiledSkill() throws {
        let skillPath = try write("block.yaml", ClockWalkDouble.skillYAML)
        let source = try write("world-clock.ios.yaml", ClockWalkDouble.skillYAML + "# scenario\n")
        let out = tmpDir + "/world-clock.ios.compiled.json"
        let skill = try SkillFileLoader.load(filePath: skillPath)
        let phone = ClockWalkDouble()
        let (result, screens) = phone.run(skill)

        try CompiledRunRecord.write(
            skill: skill, result: result, screens: screens,
            device: CompileCommand.deviceInfo(of: phone.bridge),
            sourcePath: source, outputPath: out)

        let compiled = try JSONDecoder().decode(
            CompiledSkill.self, from: try Data(contentsOf: URL(fileURLWithPath: out)))
        XCTAssertEqual(compiled.version, 5)
        XCTAssertEqual(compiled.source.sha256, try CompiledSkillIO.sha256(of: source))
        XCTAssertNotEqual(compiled.source.sha256, try CompiledSkillIO.sha256(of: skillPath))
        XCTAssertEqual(compiled.device,
                       DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"))
        XCTAssertEqual(compiled.screenFingerprint, screens.start)
        XCTAssertEqual(compiled.steps.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(compiled.steps.map(\.type), ["target", "launch", "tap", "wait_for"])
        XCTAssertEqual(compiled.steps.map(\.label),
                       skill.steps.map { CompileCommand.compiledLabel($0) })
        for step in compiled.steps {
            XCTAssertEqual(step.hints?.compiledAction, .passthrough)
            XCTAssertEqual(step.hints?.arrivalFingerprint, screens.afterStep[step.index])
        }
    }

    func testAFailedRunWritesNothing() throws {
        let yaml = "name: Miss\nsteps:\n  - launch: \"Clock\"\n  - tap: \"Bedtime\"\n"
        let skillPath = try write("miss.yaml", yaml)
        let out = tmpDir + "/miss.compiled.json"
        let skill = try SkillFileLoader.load(filePath: skillPath)
        let phone = ClockWalkDouble()
        let (result, screens) = phone.run(skill)

        XCTAssertThrowsError(try CompiledRunRecord.write(
            skill: skill, result: result, screens: screens,
            device: CompileCommand.deviceInfo(of: phone.bridge),
            sourcePath: skillPath, outputPath: out)) { error in
            XCTAssertEqual(error as? CompiledRunRecordError, .runFailed(skill: "Miss"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    func testAPassingRunWithNoWindowWritesNothing() throws {
        let skillPath = try write("block.yaml", ClockWalkDouble.skillYAML)
        let out = tmpDir + "/block.compiled.json"
        let skill = try SkillFileLoader.load(filePath: skillPath)
        let (result, screens) = ClockWalkDouble().run(skill)

        XCTAssertThrowsError(try CompiledRunRecord.write(
            skill: skill, result: result, screens: screens, device: nil,
            sourcePath: skillPath, outputPath: out)) { error in
            XCTAssertEqual(error as? CompiledRunRecordError, .noWindow)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    func testAPassingRunWithAnUnreadStepScreenWritesNothing() throws {
        let skillPath = try write("block.yaml", ClockWalkDouble.skillYAML)
        let out = tmpDir + "/block.compiled.json"
        let skill = try SkillFileLoader.load(filePath: skillPath)
        let phone = ClockWalkDouble()
        var (result, screens) = phone.run(skill)
        XCTAssertTrue(result.passed)
        screens.afterStep[2] = nil

        XCTAssertThrowsError(try CompiledRunRecord.write(
            skill: skill, result: result, screens: screens,
            device: CompileCommand.deviceInfo(of: phone.bridge),
            sourcePath: skillPath, outputPath: out)) { error in
            XCTAssertEqual(error as? CompiledRunRecordError, .stepScreenUnread(index: 2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    func testAPassingRunWithAnUnreadStartScreenWritesNothing() throws {
        let skillPath = try write("block.yaml", ClockWalkDouble.skillYAML)
        let out = tmpDir + "/block.compiled.json"
        let skill = try SkillFileLoader.load(filePath: skillPath)
        let phone = ClockWalkDouble()
        var (result, screens) = phone.run(skill)
        screens.start = nil

        XCTAssertThrowsError(try CompiledRunRecord.write(
            skill: skill, result: result, screens: screens,
            device: CompileCommand.deviceInfo(of: phone.bridge),
            sourcePath: skillPath, outputPath: out)) { error in
            XCTAssertEqual(error as? CompiledRunRecordError, .startScreenUnread)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }

    // MARK: - Helpers

    private func skillResult() -> ConsoleReporter.SkillResult {
        ConsoleReporter.SkillResult(
            name: "walk", filePath: "walk.yaml",
            stepResults: [StepResult(step: .launch(appName: "Clock"), status: .passed,
                                     message: nil, durationSeconds: 1)],
            durationSeconds: 1)
    }

    private func decodeCaptures(_ data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let suite = try XCTUnwrap((root["suites"] as? [[String: Any]])?.first)
        let spec = try XCTUnwrap((suite["specs"] as? [[String: Any]])?.first)
        let test = try XCTUnwrap((spec["tests"] as? [[String: Any]])?.first)
        let run = try XCTUnwrap((test["results"] as? [[String: Any]])?.first)
        let attachment = try XCTUnwrap((run["attachments"] as? [[String: Any]])?.first)
        let body = try XCTUnwrap(attachment["body"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(Data(base64Encoded: body))) as? [String: Any])
    }
}
