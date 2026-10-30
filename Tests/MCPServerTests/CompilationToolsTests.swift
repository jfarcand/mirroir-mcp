// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AI-driven compilation tools: record_step, save_compiled, and get_skill status.
// ABOUTME: Verifies session accumulation, hint derivation, file output, and compilation status reporting.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class CompilationToolsTests: XCTestCase {

    private var tmpDir: String!

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "compilation-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    // MARK: - CompilationSession

    func testRecordStepAccumulatesSteps() {
        let session = CompilationSession()

        session.record(CompiledStep(
            index: 0, type: "launch", label: "Settings", hints: .passthrough()))
        session.record(CompiledStep(
            index: 1, type: "tap", label: "General",
            hints: .tap(x: 205, y: 340, strategy: "exact")))
        session.record(CompiledStep(
            index: 2, type: "wait_for", label: "About",
            hints: .passthrough()))

        XCTAssertEqual(session.stepCount, 3)
    }

    func testFinalizeAndClearReturnsStepsAndClears() {
        let session = CompilationSession()
        session.record(CompiledStep(
            index: 0, type: "launch", label: "App", hints: .passthrough()))
        session.record(CompiledStep(
            index: 1, type: "tap", label: "OK",
            hints: .tap(x: 100, y: 200, strategy: "exact")))

        let steps = session.finalizeAndClear()
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].type, "launch")
        XCTAssertEqual(steps[1].type, "tap")

        // Session should be empty after finalize
        XCTAssertEqual(session.stepCount, 0)
        let stepsAfter = session.finalizeAndClear()
        XCTAssertTrue(stepsAfter.isEmpty)
    }

    // MARK: - deriveHints

    func testDeriveHintsTapWithCoordinates() {
        let hints = MirroirMCP.deriveHints(
            type: "tap", tapX: 205, tapY: 340,
            matchStrategy: "exact",
            elapsedMs: nil, scrollCount: nil, scrollDirection: nil)

        XCTAssertNotNil(hints)
        XCTAssertEqual(hints?.compiledAction, .tap)
        XCTAssertEqual(hints?.tapX, 205)
        XCTAssertEqual(hints?.tapY, 340)
        XCTAssertEqual(hints?.matchStrategy, "exact")
    }

    func testDeriveHintsTapCarriesTheScreenACoordinateTapReached() {
        let arrival = ScreenFingerprint(hash: "h", structuralTexts: ["General"], iconCount: 2)
        let hints = MirroirMCP.deriveHints(
            type: "tap", tapX: 40, tapY: 880, matchStrategy: nil,
            elapsedMs: nil, scrollCount: nil, scrollDirection: nil, arrival: arrival)
        XCTAssertEqual(hints?.arrivalFingerprint, arrival)
    }

    func testDeriveHintsTapWithoutCoordinatesButElapsed() {
        let hints = MirroirMCP.deriveHints(
            type: "tap", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: 500, scrollCount: nil, scrollDirection: nil)

        // A sleep would pass without tapping: replay it live instead.
        XCTAssertEqual(hints?.compiledAction, .passthrough)
    }

    func testDeriveHintsTapWithoutAnything() {
        let hints = MirroirMCP.deriveHints(
            type: "tap", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: nil, scrollCount: nil, scrollDirection: nil)

        // Replayed live: the element is found by OCR.
        XCTAssertEqual(hints?.compiledAction, .passthrough)
    }

    /// A wait_for replays live, polling for its element: a recorded delay would pass
    /// without looking at the screen.
    func testDeriveHintsWaitForReplaysLive() {
        let hints = MirroirMCP.deriveHints(
            type: "wait_for", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: 2000, scrollCount: nil, scrollDirection: nil)

        XCTAssertEqual(hints?.compiledAction, .passthrough)
        XCTAssertNil(hints?.observedDelayMs)
    }

    func testDeriveHintsAssertVisible() {
        let hints = MirroirMCP.deriveHints(
            type: "assert_visible", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: 300, scrollCount: nil, scrollDirection: nil)

        XCTAssertNotNil(hints)
        XCTAssertEqual(hints?.compiledAction, .assertion)
        XCTAssertEqual(hints?.observedDelayMs, 300)
    }

    func testDeriveHintsAssertNotVisible() {
        let hints = MirroirMCP.deriveHints(
            type: "assert_not_visible", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: 100, scrollCount: nil, scrollDirection: nil)

        XCTAssertNotNil(hints)
        XCTAssertEqual(hints?.compiledAction, .assertion)
        XCTAssertEqual(hints?.observedDelayMs, 100)
    }

    func testDeriveHintsScrollTo() {
        let hints = MirroirMCP.deriveHints(
            type: "scroll_to", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: nil, scrollCount: 3, scrollDirection: "up")

        XCTAssertNotNil(hints)
        XCTAssertEqual(hints?.compiledAction, .scrollSequence)
        XCTAssertEqual(hints?.scrollCount, 3)
        XCTAssertEqual(hints?.scrollDirection, "up")
    }

    func testDeriveHintsScrollToDefaults() {
        let hints = MirroirMCP.deriveHints(
            type: "scroll_to", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: nil, scrollCount: nil, scrollDirection: nil)

        XCTAssertNotNil(hints)
        XCTAssertEqual(hints?.compiledAction, .scrollSequence)
        XCTAssertEqual(hints?.scrollCount, 1)
        XCTAssertEqual(hints?.scrollDirection, "up")
    }

    func testDeriveHintsPassthroughTypes() {
        let passthroughTypes = [
            "launch", "type", "press_key", "swipe", "home", "open_url",
            "shake", "reset_app", "set_network", "screenshot", "target",
            "long_press", "drag",
        ]

        for stepType in passthroughTypes {
            let hints = MirroirMCP.deriveHints(
                type: stepType, tapX: nil, tapY: nil,
                matchStrategy: nil,
                elapsedMs: nil, scrollCount: nil, scrollDirection: nil)

            XCTAssertNotNil(hints, "Expected passthrough hints for type '\(stepType)'")
            XCTAssertEqual(hints?.compiledAction, .passthrough,
                "Expected passthrough action for type '\(stepType)'")
        }
    }

    func testDeriveHintsMeasure() {
        let hints = MirroirMCP.deriveHints(
            type: "measure", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: 3500, scrollCount: nil, scrollDirection: nil)

        // Replayed live: a sleep would pass without running the action or the check.
        XCTAssertEqual(hints?.compiledAction, .passthrough)
    }

    func testDeriveHintsUnknownType() {
        let hints = MirroirMCP.deriveHints(
            type: "remember", tapX: nil, tapY: nil,
            matchStrategy: nil,
            elapsedMs: nil, scrollCount: nil, scrollDirection: nil)

        XCTAssertNil(hints, "Unknown/AI-only types should return nil hints")
    }

    // MARK: - save_compiled file I/O

    func testSaveCompiledWritesFile() throws {
        let skillPath = createSkillFile("test.md", content: "# Test\nSteps here")

        // Build and save a compiled skill
        let hash = try CompiledSkillIO.sha256(of: skillPath)
        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: hash, compiledAt: "2026-02-21T10:00:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: [
                CompiledStep(index: 0, type: "launch", label: "Settings",
                             hints: .passthrough()),
                CompiledStep(index: 1, type: "tap", label: "General",
                             hints: .tap(x: 205, y: 340, strategy: "exact")),
            ]
        )

        try CompiledSkillIO.save(compiled, for: skillPath)

        let compiledPath = CompiledSkillIO.compiledPath(for: skillPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiledPath))

        // Verify it can be loaded back
        let loaded = try CompiledSkillIO.load(for: skillPath)
        XCTAssertEqual(loaded, compiled)
    }

    func testSaveCompiledClearsSession() {
        let session = CompilationSession()
        session.record(CompiledStep(
            index: 0, type: "launch", label: "App", hints: .passthrough()))
        session.record(CompiledStep(
            index: 1, type: "tap", label: "OK",
            hints: .tap(x: 100, y: 200, strategy: "exact")))

        XCTAssertEqual(session.stepCount, 2)

        let steps = session.finalizeAndClear()
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(session.stepCount, 0)
    }

    // MARK: - compilationStatus

    func testGetSkillReportsNotCompiled() {
        let skillPath = createSkillFile("test.md", content: "# Test\nBody")

        let status = MirroirMCP.compilationStatus(for: skillPath)
        XCTAssertTrue(status.contains("[Not compiled"),
            "Expected [Not compiled], got: \(status)")
    }

    func testGetSkillReportsFresh() throws {
        let skillPath = createSkillFile("fresh.md", content: "# Fresh\nBody")

        let hash = try CompiledSkillIO.sha256(of: skillPath)
        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: hash, compiledAt: "2026-02-21T10:00:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: [
                CompiledStep(index: 0, type: "launch", label: "App",
                             hints: .passthrough()),
            ]
        )
        try CompiledSkillIO.save(compiled, for: skillPath)

        let status = MirroirMCP.compilationStatus(for: skillPath)
        XCTAssertEqual(status, "[Compiled: fresh]")
    }

    func testGetSkillReportsStale() throws {
        let skillPath = createSkillFile("stale.md", content: "# Original\nBody")

        // Compile with the original content
        let hash = try CompiledSkillIO.sha256(of: skillPath)
        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: hash, compiledAt: "2026-02-21T10:00:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: []
        )
        try CompiledSkillIO.save(compiled, for: skillPath)

        // Modify the source file
        try "# Modified\nDifferent body".write(
            toFile: skillPath, atomically: true, encoding: .utf8)

        let status = MirroirMCP.compilationStatus(for: skillPath)
        XCTAssertTrue(status.contains("[Compiled: stale"),
            "Expected [Compiled: stale], got: \(status)")
        XCTAssertTrue(status.contains("changed"),
            "Expected staleness reason to mention 'changed', got: \(status)")
    }

    func testCompilationStatusIgnoresDimensions() throws {
        // compilationStatus should only check version + hash, not dimensions.
        // This validates the fix for the circular dimension comparison bug where
        // compiled.device dimensions were used as "current" dimensions.
        let skillPath = createSkillFile("dimensions.md", content: "# Dimensions\nBody")

        let hash = try CompiledSkillIO.sha256(of: skillPath)
        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: hash, compiledAt: "2026-02-21T10:00:00Z"),
            device: DeviceInfo(windowWidth: 999, windowHeight: 1, orientation: "landscape"),
            steps: [
                CompiledStep(index: 0, type: "launch", label: "App",
                             hints: .passthrough()),
            ]
        )
        try CompiledSkillIO.save(compiled, for: skillPath)

        // compilationStatus should report fresh because hash matches,
        // even though dimensions are unusual — dimension check is deferred to the test runner
        let status = MirroirMCP.compilationStatus(for: skillPath)
        XCTAssertEqual(status, "[Compiled: fresh]",
            "compilationStatus should not check dimensions; got: \(status)")
    }

    func testCompilationStatusDetectsVersionMismatch() throws {
        let skillPath = createSkillFile("version.md", content: "# Version\nBody")

        let hash = try CompiledSkillIO.sha256(of: skillPath)
        let compiled = CompiledSkill(
            version: 999,
            source: SourceInfo(sha256: hash, compiledAt: "2026-02-21T10:00:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: []
        )
        try CompiledSkillIO.save(compiled, for: skillPath)

        let status = MirroirMCP.compilationStatus(for: skillPath)
        XCTAssertTrue(status.contains("[Compiled: stale"),
            "Expected stale for version mismatch, got: \(status)")
        XCTAssertTrue(status.contains("version"),
            "Expected reason to mention version, got: \(status)")
    }

    func testCompilationStatusReportsAnUndecodableOldFileAsStale() throws {
        // A version-3 file using the removed "sleep" action no longer decodes;
        // get_skill must say it is stale, not that the skill was never compiled.
        let skillPath = createSkillFile("old.md", content: "# Old\nBody")
        let json = """
            {"version": 3, "source": {"sha256": "x", "compiledAt": "2026-02-21T10:00:00Z"},
             "device": {"windowWidth": 410, "windowHeight": 898, "orientation": "portrait"},
             "steps": [{"index": 0, "type": "wait_for", "label": "Home",
                        "hints": {"compiledAction": "sleep", "observedDelayMs": 500}}]}
            """
        try json.write(toFile: CompiledSkillIO.compiledPath(for: skillPath),
                       atomically: true, encoding: .utf8)

        let status = MirroirMCP.compilationStatus(for: skillPath)
        XCTAssertTrue(status.contains("[Compiled: stale"), "got: \(status)")
        XCTAssertTrue(status.contains("version 3"), "got: \(status)")
    }

    func testCompiledPathForMdMatchesYamlPattern() {
        // Verify that .md files get .compiled.json just like .yaml files
        let mdPath = CompiledSkillIO.compiledPath(for: "apps/test.md")
        let yamlPath = CompiledSkillIO.compiledPath(for: "apps/test.yaml")
        XCTAssertEqual(mdPath, "apps/test.compiled.json")
        XCTAssertEqual(yamlPath, "apps/test.compiled.json")
    }

    // MARK: - Helpers

    @discardableResult
    private func createSkillFile(
        _ relativePath: String,
        content: String
    ) -> String {
        let fullPath = tmpDir + "/" + relativePath
        let dir = (fullPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try? content.write(toFile: fullPath, atomically: true, encoding: .utf8)
        return fullPath
    }
}
