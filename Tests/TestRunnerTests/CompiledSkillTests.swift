// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for CompiledSkill data model, JSON serialization, staleness detection.
// ABOUTME: Validates path derivation, SHA-256 hashing, and version/dimension mismatch handling.

import XCTest
@testable import mirroir_mcp

final class CompiledSkillTests: XCTestCase {

    // MARK: - JSON Round-Trip

    func testJSONRoundTrip() throws {
        let compiled = CompiledSkill(
            version: 1,
            source: SourceInfo(sha256: "abc123", compiledAt: "2026-02-19T14:30:00Z"),
            device: DeviceInfo(windowWidth: 410.0, windowHeight: 898.0, orientation: "portrait"),
            steps: [
                CompiledStep(index: 0, type: "launch", label: "Settings", hints: .passthrough()),
                CompiledStep(index: 1, type: "tap", label: "General",
                             hints: .tap(x: 205.0, y: 340.5, confidence: 0.98, strategy: "exact")),
                CompiledStep(index: 2, type: "wait_for", label: "About",
                             hints: .sleep(delayMs: 1200)),
                CompiledStep(index: 3, type: "scroll_to", label: "Model",
                             hints: .scrollSequence(count: 3, direction: "up")),
                CompiledStep(index: 4, type: "remember", label: nil, hints: nil),
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(compiled)
        let decoded = try JSONDecoder().decode(CompiledSkill.self, from: data)

        XCTAssertEqual(compiled, decoded)
    }

    func testJSONContainsExpectedKeys() throws {
        let compiled = CompiledSkill(
            version: 1,
            source: SourceInfo(sha256: "hash", compiledAt: "2026-01-01T00:00:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: [
                CompiledStep(index: 0, type: "tap", label: "OK",
                             hints: .tap(x: 100, y: 200, confidence: 0.95, strategy: "exact"))
            ]
        )

        let data = try JSONEncoder().encode(compiled)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"version\""))
        XCTAssertTrue(json.contains("\"sha256\""))
        XCTAssertTrue(json.contains("\"compiledAction\""))
        XCTAssertTrue(json.contains("\"tapX\""))
        XCTAssertTrue(json.contains("\"tapY\""))
    }

    // MARK: - Path Derivation

    func testCompiledPathFromYAML() {
        let result = CompiledSkillIO.compiledPath(for: "apps/settings/check-about.yaml")
        XCTAssertEqual(result, "apps/settings/check-about.compiled.json")
    }

    func testCompiledPathFromYAMLWithPath() {
        let result = CompiledSkillIO.compiledPath(for: "/home/user/skills/login.yaml")
        XCTAssertEqual(result, "/home/user/skills/login.compiled.json")
    }

    func testCompiledPathFromMd() {
        let result = CompiledSkillIO.compiledPath(for: "apps/settings/check-about.md")
        XCTAssertEqual(result, "apps/settings/check-about.compiled.json")
    }

    // MARK: - SHA-256

    func testSHA256Consistency() {
        let data1 = Data("hello world".utf8)
        let data2 = Data("hello world".utf8)
        XCTAssertEqual(CompiledSkillIO.sha256(data: data1),
                       CompiledSkillIO.sha256(data: data2))
    }

    func testSHA256DifferentInputs() {
        let hash1 = CompiledSkillIO.sha256(data: Data("hello".utf8))
        let hash2 = CompiledSkillIO.sha256(data: Data("world".utf8))
        XCTAssertNotEqual(hash1, hash2)
    }

    func testSHA256Length() {
        let hash = CompiledSkillIO.sha256(data: Data("test".utf8))
        XCTAssertEqual(hash.count, 64) // SHA-256 = 32 bytes = 64 hex chars
    }

    // MARK: - Staleness Detection

    func testFreshWhenHashAndDimensionsMatch() throws {
        let tempDir = NSTemporaryDirectory() + "compiled-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yamlPath = tempDir + "/test.yaml"
        let yamlContent = "name: test\nsteps:\n  - tap: \"OK\"\n"
        try yamlContent.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let hash = try CompiledSkillIO.sha256(of: yamlPath)

        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: hash, compiledAt: "2026-02-19T14:30:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: []
        )

        let result = CompiledSkillIO.checkStaleness(
            compiled: compiled, skillPath: yamlPath,
            windowWidth: 410, windowHeight: 898)
        XCTAssertEqual(result, .fresh)
    }

    func testStaleWhenHashChanged() throws {
        let tempDir = NSTemporaryDirectory() + "compiled-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yamlPath = tempDir + "/test.yaml"
        try "original content".write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: "stale-hash", compiledAt: "2026-02-19T14:30:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: []
        )

        let result = CompiledSkillIO.checkStaleness(
            compiled: compiled, skillPath: yamlPath,
            windowWidth: 410, windowHeight: 898)
        if case .stale(let reason) = result {
            XCTAssertTrue(reason.contains("changed"))
        } else {
            XCTFail("Expected stale result")
        }
    }

    func testStaleWhenDimensionsChanged() throws {
        let tempDir = NSTemporaryDirectory() + "compiled-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yamlPath = tempDir + "/test.yaml"
        let content = "test content"
        try content.write(toFile: yamlPath, atomically: true, encoding: .utf8)
        let hash = try CompiledSkillIO.sha256(of: yamlPath)

        let compiled = CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(sha256: hash, compiledAt: "2026-02-19T14:30:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: []
        )

        // Different window dimensions
        let result = CompiledSkillIO.checkStaleness(
            compiled: compiled, skillPath: yamlPath,
            windowWidth: 390, windowHeight: 844)
        if case .stale(let reason) = result {
            XCTAssertTrue(reason.contains("dimensions"))
        } else {
            XCTFail("Expected stale result for dimension mismatch")
        }
    }

    func testStaleWhenVersionMismatch() throws {
        let compiled = CompiledSkill(
            version: 999,
            source: SourceInfo(sha256: "anything", compiledAt: "2026-02-19T14:30:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: []
        )

        let result = CompiledSkillIO.checkStaleness(
            compiled: compiled, skillPath: "/nonexistent.yaml",
            windowWidth: 410, windowHeight: 898)
        if case .stale(let reason) = result {
            XCTAssertTrue(reason.contains("version"))
        } else {
            XCTFail("Expected stale result for version mismatch")
        }
    }

    // MARK: - File I/O

    func testSaveAndLoad() throws {
        let tempDir = NSTemporaryDirectory() + "compiled-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let yamlPath = tempDir + "/test.yaml"
        try "content".write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let compiled = CompiledSkill(
            version: 1,
            source: SourceInfo(sha256: "abc", compiledAt: "2026-02-19T14:30:00Z"),
            device: DeviceInfo(windowWidth: 410, windowHeight: 898, orientation: "portrait"),
            steps: [
                CompiledStep(index: 0, type: "tap", label: "OK",
                             hints: .tap(x: 100, y: 200, confidence: 0.95, strategy: "exact"))
            ]
        )

        try CompiledSkillIO.save(compiled, for: yamlPath)
        let loaded = try CompiledSkillIO.load(for: yamlPath)

        XCTAssertEqual(loaded, compiled)
    }

    func testLoadReturnsNilForMissingFile() throws {
        let result = try CompiledSkillIO.load(for: "/nonexistent/test.yaml")
        XCTAssertNil(result)
    }

    // MARK: - StepHints Factory Methods

    func testTapHints() {
        let hints = StepHints.tap(x: 100, y: 200, confidence: 0.95, strategy: "exact")
        XCTAssertEqual(hints.compiledAction, .tap)
        XCTAssertEqual(hints.tapX, 100)
        XCTAssertEqual(hints.tapY, 200)
        XCTAssertEqual(hints.confidence, 0.95)
        XCTAssertEqual(hints.matchStrategy, "exact")
        XCTAssertNil(hints.observedDelayMs)
    }

    func testSleepHints() {
        let hints = StepHints.sleep(delayMs: 1200)
        XCTAssertEqual(hints.compiledAction, .sleep)
        XCTAssertEqual(hints.observedDelayMs, 1200)
        XCTAssertNil(hints.tapX)
    }

    func testScrollSequenceHints() {
        let hints = StepHints.scrollSequence(count: 3, direction: "up")
        XCTAssertEqual(hints.compiledAction, .scrollSequence)
        XCTAssertEqual(hints.scrollCount, 3)
        XCTAssertEqual(hints.scrollDirection, "up")
    }

    func testPassthroughHints() {
        let hints = StepHints.passthrough()
        XCTAssertEqual(hints.compiledAction, .passthrough)
        XCTAssertNil(hints.tapX)
        XCTAssertNil(hints.observedDelayMs)
        XCTAssertNil(hints.scrollCount)
    }

    // MARK: - SkillStep Accessors

    func testTypeKey() {
        XCTAssertEqual(SkillStep.launch(appName: "Settings").typeKey, "launch")
        XCTAssertEqual(SkillStep.tap(label: "OK").typeKey, "tap")
        XCTAssertEqual(SkillStep.type(text: "hello").typeKey, "type")
        XCTAssertEqual(SkillStep.pressKey(keyName: "return", modifiers: []).typeKey, "press_key")
        XCTAssertEqual(SkillStep.swipe(direction: "up").typeKey, "swipe")
        XCTAssertEqual(SkillStep.waitFor(label: "X", timeoutSeconds: nil).typeKey, "wait_for")
        XCTAssertEqual(SkillStep.assertVisible(label: "X").typeKey, "assert_visible")
        XCTAssertEqual(SkillStep.assertNotVisible(label: "X").typeKey, "assert_not_visible")
        XCTAssertEqual(SkillStep.screenshot(label: "X").typeKey, "screenshot")
        XCTAssertEqual(SkillStep.home.typeKey, "home")
        XCTAssertEqual(SkillStep.openURL(url: "https://x").typeKey, "open_url")
        XCTAssertEqual(SkillStep.shake.typeKey, "shake")
        XCTAssertEqual(SkillStep.scrollTo(label: "X", direction: "up", maxScrolls: 10).typeKey, "scroll_to")
        XCTAssertEqual(SkillStep.resetApp(appName: "X").typeKey, "reset_app")
        XCTAssertEqual(SkillStep.setNetwork(mode: "wifi_on").typeKey, "set_network")
        XCTAssertEqual(SkillStep.skipped(stepType: "remember", reason: "AI").typeKey, "remember")
    }

    func testLabelValue() {
        XCTAssertEqual(SkillStep.launch(appName: "Settings").labelValue, "Settings")
        XCTAssertEqual(SkillStep.tap(label: "OK").labelValue, "OK")
        XCTAssertNil(SkillStep.home.labelValue)
        XCTAssertNil(SkillStep.shake.labelValue)
        XCTAssertNil(SkillStep.skipped(stepType: "remember", reason: "AI").labelValue)
    }
}
