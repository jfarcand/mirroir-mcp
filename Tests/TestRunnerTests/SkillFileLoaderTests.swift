// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for SkillFileLoader: a SKILL.md loads its steps from its compiled file, a YAML skill from its body.
// ABOUTME: Covers rebuilt steps, missing and stale compiled files, kind:game, and `mirroir test` on a SKILL.md.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SkillFileLoaderTests: XCTestCase {

    var tmpDir = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "skill-loader-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    let loginMd = """
        ---
        version: 1
        name: Login
        app: Example
        ---

        Launch Example, sign in, and check the home screen shows.

        ## Steps

        1. Launch **Example**
        2. Tap "Sign In"
        3. Type the user name and press Return
        """

    func write(_ name: String, _ content: String) throws -> String {
        let path = tmpDir + "/" + name
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Compile `skillPath` the way save_compiled does: the steps recorded while an
    /// AI ran it, stamped with the source file's hash.
    func saveCompiled(for skillPath: String, steps: [CompiledStep],
                              version: Int = CompiledSkill.currentVersion) throws {
        let compiled = CompiledSkill(
            version: version,
            source: SourceInfo(sha256: try CompiledSkillIO.sha256(of: skillPath),
                               compiledAt: "2026-10-23T00:00:00Z"),
            device: DeviceInfo(windowWidth: 430, windowHeight: 942, orientation: "portrait"),
            steps: steps)
        try CompiledSkillIO.save(compiled, for: skillPath)
    }

    var recordedLoginSteps: [CompiledStep] {
        [
            CompiledStep(index: 0, type: "launch", label: "Example", hints: .passthrough()),
            CompiledStep(index: 1, type: "tap", label: "Sign In",
                         hints: .tap(x: 215, y: 600, confidence: 0.98, strategy: "exact")),
            CompiledStep(index: 2, type: "type", label: "alice", hints: .passthrough()),
            CompiledStep(index: 3, type: "press_key", label: "return", hints: .passthrough()),
            CompiledStep(index: 4, type: "home", label: nil, hints: .passthrough()),
        ]
    }

    // MARK: - SKILL.md

    func testSkillMdStepsAreRebuiltFromItsCompiledFile() throws {
        let path = try write("login.md", loginMd)
        try saveCompiled(for: path, steps: recordedLoginSteps)

        let skill = try SkillFileLoader.load(filePath: path)

        XCTAssertEqual(skill.name, "Login")
        XCTAssertEqual(skill.filePath, path)
        XCTAssertEqual(skill.steps.map(\.displayName), [
            SkillStep.launch(appName: "Example").displayName,
            SkillStep.tap(label: "Sign In").displayName,
            SkillStep.type(text: "alice").displayName,
            SkillStep.pressKey(keyName: "return", modifiers: []).displayName,
            SkillStep.home.displayName,
        ])
    }

    func testRecordedStepsReplayInIndexOrder() throws {
        let path = try write("login.md", loginMd)
        try saveCompiled(for: path, steps: recordedLoginSteps.reversed())

        let skill = try SkillFileLoader.load(filePath: path)

        XCTAssertEqual(skill.steps.first?.typeKey, "launch")
        XCTAssertEqual(skill.steps.last?.typeKey, "home")
    }

    func testPressKeyLabelCarriesModifiers() throws {
        let path = try write("address.md", loginMd)
        try saveCompiled(for: path, steps: [
            CompiledStep(index: 0, type: "press_key", label: "l+command", hints: .passthrough()),
        ])

        let skill = try SkillFileLoader.load(filePath: path)

        guard case .pressKey(let key, let modifiers) = skill.steps.first else {
            return XCTFail("expected a press_key step, got \(skill.steps)")
        }
        XCTAssertEqual(key, "l")
        XCTAssertEqual(modifiers, ["command"])
    }

    func testUnknownRecordedTypeBecomesAnInvalidStep() throws {
        let path = try write("odd.md", loginMd)
        try saveCompiled(for: path, steps: [
            CompiledStep(index: 0, type: "teleport", label: "Mars", hints: nil),
        ])

        let skill = try SkillFileLoader.load(filePath: path)

        guard case .invalid(let type, _) = skill.steps.first else {
            return XCTFail("expected an invalid step, got \(skill.steps)")
        }
        XCTAssertEqual(type, "teleport")
    }

    func testSkillMdWithoutCompiledFileIsRefused() throws {
        let path = try write("login.md", loginMd)

        XCTAssertThrowsError(try SkillFileLoader.load(filePath: path)) { error in
            guard case SkillFileLoaderError.notCompiled(let failed) = error else {
                return XCTFail("expected notCompiled, got \(error)")
            }
            XCTAssertEqual(failed, path)
            XCTAssertTrue(error.localizedDescription.contains("record_step"))
        }
    }

    func testSkillMdEditedAfterCompilingIsRefused() throws {
        let path = try write("login.md", loginMd)
        try saveCompiled(for: path, steps: recordedLoginSteps)
        _ = try write("login.md", loginMd + "\n4. Tap \"Profile\"\n")

        XCTAssertThrowsError(try SkillFileLoader.load(filePath: path)) { error in
            guard case SkillFileLoaderError.staleCompiled(_, let reason) = error else {
                return XCTFail("expected staleCompiled, got \(error)")
            }
            XCTAssertTrue(reason.contains("changed"))
        }
    }

    func testSkillMdCompiledByAnOlderFormatIsRefused() throws {
        let path = try write("login.md", loginMd)
        try saveCompiled(for: path, steps: recordedLoginSteps,
                         version: CompiledSkill.currentVersion - 1)

        XCTAssertThrowsError(try SkillFileLoader.load(filePath: path)) { error in
            guard case SkillFileLoaderError.staleCompiled(_, let reason) = error else {
                return XCTFail("expected staleCompiled, got \(error)")
            }
            XCTAssertTrue(reason.contains("version"))
        }
    }

    func testGameSkillMdLoadsWithoutACompiledFile() throws {
        let path = try write("scene.md", """
            ---
            name: Scene Probe
            kind: game
            ---

            Watch the playfield.
            """)

        let skill = try SkillFileLoader.load(filePath: path)

        XCTAssertEqual(skill.kind, "game")
        XCTAssertTrue(skill.steps.isEmpty)
    }

    // MARK: - YAML

    func testYamlSkillLoadsItsOwnSteps() throws {
        let path = try write("settings.yaml", """
            name: Settings
            steps:
              - launch: "Settings"
              - tap: "General"
            """)

        let skill = try SkillFileLoader.load(filePath: path)

        XCTAssertEqual(skill.steps.map(\.typeKey), ["launch", "tap"])
    }

    // MARK: - mirroir test

    func testDryRunReplaysACompiledSkillMd() throws {
        let path = try write("login.md", loginMd)
        try saveCompiled(for: path, steps: recordedLoginSteps)

        XCTAssertEqual(TestRunner.run(arguments: ["--dry-run", "--no-compiled", path]), 0)
    }

    func testRunFailsOnAnUncompiledSkillMd() throws {
        let path = try write("login.md", loginMd)

        XCTAssertEqual(TestRunner.run(arguments: ["--dry-run", path]), 1)
    }

    func testRunRefusesWhenOnlyGameSkillsAreGiven() throws {
        let path = try write("scene.md", "---\nname: Scene\nkind: game\n---\n\nWatch.\n")

        XCTAssertEqual(TestRunner.run(arguments: ["--dry-run", path]), 1)
    }

    func testBareNameResolvesASkillMd() throws {
        let path = try write("login.md", loginMd)

        let (resolved, ambiguous) = MirroirMCP.resolveSkill(name: "login", dirs: [tmpDir])

        XCTAssertEqual(resolved, path)
        XCTAssertTrue(ambiguous.isEmpty)
    }
}
