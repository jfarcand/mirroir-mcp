// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests save_compiled emit=true: the skill's .compiled.json plus a .mirroir/ iOS scenario,
// ABOUTME: never a .compiled.json inside .mirroir/, and an emit failure as an error carrying the save text.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SaveCompiledEmitTests: XCTestCase {

    private var base: URL!
    private var skillsDir: URL!
    private var consumer: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("save-compiled-emit-\(UUID().uuidString)")
        skillsDir = base.appendingPathComponent("skills")
        consumer = base.appendingPathComponent("consumer")
        for dir in [skillsDir!, consumer!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func points(_ labels: [String]) -> [TapPoint] {
        labels.enumerated().map { index, text in
            TapPoint(text: text, tapX: 200, tapY: 120 + Double(index) * 60, confidence: 0.95)
        }
    }

    private func read(_ labels: [String]) -> CompiledScreenRead {
        let elements = points(labels)
        return CompiledScreenRead(
            fingerprint: StructuralFingerprint.buildScreenFingerprint(elements: elements, icons: []),
            elements: elements)
    }

    private func writeSkill(_ name: String, _ steps: [String]) throws -> String {
        let path = skillsDir.appendingPathComponent(name).path
        let body = "name: Clock\nsteps:\n" + steps.map { "  - \($0)\n" }.joined()
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// A session as get_skill and record_step leave it: the start screen,
    /// then each step with the screen read after it.
    private func session(
        skillPath: String, steps: [(type: String, label: String?, after: [String])]
    ) -> CompilationSession {
        let session = CompilationSession()
        session.markStart(skillPath: skillPath) { self.read(["Phone", "Mail", "Clock"]) }
        for (index, step) in steps.enumerated() {
            session.record(CompiledStep(
                index: index, type: step.type, label: step.label, hints: .passthrough()))
            session.noteScreen(read(step.after), after: index)
        }
        return session
    }

    private var target: any Target {
        makeTestRegistry(bridge: StubBridge(), input: StubInput(), ocrDescriber: StubDescriber())
            .activeTarget
    }

    private func text(_ result: MCPToolResult) -> String {
        result.content.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }

    /// Every `.compiled.json` under `dir`, recursively.
    private func compiledFiles(under dir: URL) -> [String] {
        let walker = FileManager.default.enumerator(atPath: dir.path)
        return (walker?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".compiled.json") }
    }

    func testEmitWritesTheCompiledCacheAndTheScenarioButNoCompiledFileInTheTree() throws {
        let skillPath = try writeSkill("add-alarm.yaml", ["launch: \"Clock\"", "tap: \"Add Alarm\""])
        let compiling = session(skillPath: skillPath, steps: [
            ("launch", "Clock", ["Alarms", "Edit", "Add Alarm"]),
            ("tap", "Add Alarm", ["Cancel", "Save", "Repeat"]),
        ])

        let result = SaveCompiledHandler.save(
            skillName: "add-alarm", skillPath: skillPath, emit: true, outputDir: consumer.path,
            session: compiling, target: target)

        XCTAssertFalse(result.isError, text(result))
        let compiledPath = CompiledSkillIO.compiledPath(for: skillPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiledPath), text(result))
        XCTAssertTrue(text(result).hasPrefix("Saved \(compiledPath)\n"), text(result))
        XCTAssertTrue(text(result).contains("Emitted .mirroir/ iOS leg:"), text(result))

        let scenario = consumer.appendingPathComponent(
            ".mirroir/apps/clock/scenarios/add-alarm.ios.yaml")
        let yaml = try String(contentsOf: scenario, encoding: .utf8)
        XCTAssertTrue(yaml.contains(
            "  - reset_app: \"Clock\"\n  - launch: \"Clock\"\n  - tap: \"Add Alarm\"\n"), yaml)
        XCTAssertTrue(compiledFiles(under: consumer.appendingPathComponent(".mirroir")).isEmpty,
                      "the runner replays the scenario live; the tree holds no speed cache")
        XCTAssertEqual(compiling.stepCount, 0, "saving clears the session")
    }

    func testWithoutEmitNothingIsWrittenIntoTheConsumerRepo() throws {
        let skillPath = try writeSkill("add-alarm.yaml", ["launch: \"Clock\"", "tap: \"Add Alarm\""])
        let result = SaveCompiledHandler.save(
            skillName: "add-alarm", skillPath: skillPath, emit: false, outputDir: consumer.path,
            session: session(skillPath: skillPath, steps: [
                ("launch", "Clock", ["Alarms", "Add Alarm"]),
                ("tap", "Add Alarm", ["Cancel", "Repeat"]),
            ]), target: target)

        XCTAssertFalse(result.isError, text(result))
        XCTAssertFalse(text(result).contains("Emitted"), text(result))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: consumer.appendingPathComponent(".mirroir").path))
    }

    func testAnEmitFailureIsAnErrorCarryingTheSavedTextAndWritesNoScenario() throws {
        let skillPath = try writeSkill("edit.yaml", ["tap: \"Edit\""])
        let result = SaveCompiledHandler.save(
            skillName: "edit", skillPath: skillPath, emit: true, outputDir: consumer.path,
            session: session(skillPath: skillPath, steps: [("tap", "Edit", ["Done"])]),
            target: target)

        XCTAssertTrue(result.isError)
        let compiledPath = CompiledSkillIO.compiledPath(for: skillPath)
        XCTAssertTrue(text(result).hasPrefix("Saved \(compiledPath)\n"), text(result))
        XCTAssertTrue(text(result).contains(
            "emit failed: \(CompiledWalkBuilder.WalkError.noLaunchPrologue.localizedDescription)"),
                      text(result))
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiledPath),
                      "the speed cache is written before the emit is tried")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: consumer.appendingPathComponent(".mirroir").path))
    }

    func testAFormatterRefusalNamesTheStep() throws {
        let skillPath = try writeSkill("note.yaml", ["launch: \"Clock\"", "remember: \"the alarm\""])
        let result = SaveCompiledHandler.save(
            skillName: "note", skillPath: skillPath, emit: true, outputDir: consumer.path,
            session: session(skillPath: skillPath, steps: [
                ("launch", "Clock", ["Alarms", "Add Alarm"]),
                ("remember", "the alarm", ["Alarms", "Add Alarm"]),
            ]), target: target)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(text(result).contains("\"remember\" is an AI-only step"), text(result))
    }
}
