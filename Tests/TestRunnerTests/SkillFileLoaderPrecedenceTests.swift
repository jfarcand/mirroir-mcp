// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests which skill file the CLI runners pick across skill dirs, globs, and YAML/SKILL.md twins.
// ABOUTME: Also covers ${VAR} placeholders in compiled labels and recorded indices below 0.

import XCTest
import HelperLib
@testable import mirroir_mcp

extension SkillFileLoaderTests {

    private func makeDir(_ name: String) throws -> String {
        let dir = tmpDir + "/" + name
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func compiledMd(in dir: String, _ name: String) throws -> String {
        let path = dir + "/" + name
        try loginMd.write(toFile: path, atomically: true, encoding: .utf8)
        try saveCompiled(for: path, steps: recordedLoginSteps)
        return path
    }

    // MARK: - Precedence across skill dirs

    func testAnUncompiledLocalSkillMdIsNotReplacedByAFartherCopy() throws {
        let local = try makeDir("local")
        let global = try makeDir("global")
        try loginMd.write(toFile: local + "/login.md", atomically: true, encoding: .utf8)
        _ = try compiledMd(in: global, "login.md")

        // The local SKILL.md is the file the name means; its load error is reported.
        XCTAssertEqual(RunnerSkillResolver.resolve(name: "login", dirs: [local, global]),
                       .unusable(local + "/login.md"))
        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: [local, global]), [])
    }

    func testAYamlTwinBesideAnUncompiledSkillMdRunsBeforeAFartherCopy() throws {
        let local = try makeDir("local")
        let global = try makeDir("global")
        try loginMd.write(toFile: local + "/login.md", atomically: true, encoding: .utf8)
        let yaml = local + "/login.yaml"
        try "name: Login\nsteps:\n  - home\n".write(toFile: yaml, atomically: true, encoding: .utf8)
        _ = try compiledMd(in: global, "login.md")

        XCTAssertEqual(RunnerSkillResolver.resolve(name: "login", dirs: [local, global]), .run(yaml))
        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: [local, global]), [yaml])
    }

    func testTheRunnerRunsTheFartherSkillMdThatGetSkillCompiled() throws {
        let local = try makeDir("local")
        let global = try makeDir("global")
        try "name: Login\nsteps:\n  - home\n".write(
            toFile: local + "/login.yaml", atomically: true, encoding: .utf8)
        let md = try compiledMd(in: global, "login.md")

        // get_skill and save_compiled pick the SKILL.md; the runner runs the same file.
        XCTAssertEqual(MirroirMCP.resolveSkill(name: "login", dirs: [local, global]).path, md)
        XCTAssertEqual(RunnerSkillResolver.resolve(name: "login", dirs: [local, global]), .run(md))
        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: [local, global]), [md])
    }

    func testAnUncompiledFartherSkillMdDoesNotHideANearerYaml() throws {
        let local = try makeDir("local/apps")
        let global = try makeDir("global/apps")
        let yaml = local + "/check-about.yaml"
        try "name: About\nsteps:\n  - home\n".write(toFile: yaml, atomically: true, encoding: .utf8)
        try loginMd.write(toFile: global + "/check-about.md", atomically: true, encoding: .utf8)
        let dirs = [tmpDir + "/local", tmpDir + "/global"]

        XCTAssertEqual(RunnerSkillResolver.resolve(name: "apps/check-about", dirs: dirs), .run(yaml))
        XCTAssertEqual(RunnerSkillResolver.resolve(name: "check-about", dirs: dirs), .run(yaml))
        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: dirs), [yaml])
    }

    func testANestedSkillByPathAndInDiscoveryIsTheSkillMdByBasenameTheLocalYaml() throws {
        let local = try makeDir("local/apps/x")
        let global = try makeDir("global/apps/x")
        try "name: Foo\nsteps:\n  - home\n".write(
            toFile: local + "/foo.yaml", atomically: true, encoding: .utf8)
        let md = try compiledMd(in: global, "foo.md")
        let dirs = [tmpDir + "/local", tmpDir + "/global"]

        // A path weighs .md across dirs first; a basename lets the nearer dir win, as
        // list_skills shows it. The runner resolves each the way get_skill does.
        XCTAssertEqual(MirroirMCP.resolveSkill(name: "apps/x/foo", dirs: dirs).path, md)
        XCTAssertEqual(RunnerSkillResolver.resolve(name: "apps/x/foo", dirs: dirs), .run(md))
        XCTAssertEqual(TestRunner.discoverAllSkillFiles(in: dirs), [md])
        let localYaml = tmpDir + "/local/apps/x/foo.yaml"
        XCTAssertEqual(MirroirMCP.resolveSkill(name: "foo", dirs: dirs).path, localYaml)
        XCTAssertEqual(RunnerSkillResolver.resolve(name: "foo", dirs: dirs), .run(localYaml))
    }

    func testMcpResolutionStillFindsTheOtherFormatByBasename() throws {
        let nested = try makeDir("apps")
        let md = nested + "/only.md"
        try loginMd.write(toFile: md, atomically: true, encoding: .utf8)

        XCTAssertEqual(MirroirMCP.resolveSkill(name: "only.yaml", dirs: [tmpDir]).path, md)
    }

    func testCompileRefusesASkillMdWithACoordinateOnlyTap() throws {
        let md = try write("icon.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "tap", label: nil,
                         hints: .tap(x: 40, y: 880, confidence: 0, strategy: "unknown")),
        ])
        XCTAssertTrue(CompileCommand.hasCoordinateOnlyTap(try SkillFileLoader.load(filePath: md)))

        let yaml = try write("settings.yaml", "name: S\nsteps:\n  - tap: \"General\"\n")
        XCTAssertFalse(CompileCommand.hasCoordinateOnlyTap(try SkillFileLoader.load(filePath: yaml)))
    }

    func testCompileTakesSkillMdFilesOnlyWhenNamed() throws {
        let md = try compiledMd(in: tmpDir, "login.md")
        let twin = try write("login.yaml", "name: Login\nsteps:\n  - home\n")
        let other = try write("other.yaml", "name: Other\nsteps:\n  - home\n")

        XCTAssertEqual(CompileCommand.filesToCompile([md, twin, other], named: []), [other])
        XCTAssertEqual(CompileCommand.filesToCompile([md, other], named: [md]), [md, other])
    }

    // MARK: - Globs

    func testGlobKeepsCompiledSkillMdFilesAndSkipsTheRest() throws {
        let compiled = try compiledMd(in: tmpDir, "login.md")
        _ = try write("draft.md", loginMd)
        let yaml = try write("settings.yaml", "name: Settings\nsteps:\n  - home\n")

        let files = try TestRunner.resolveSkillFiles([tmpDir + "/*"])

        XCTAssertEqual(files, [compiled, yaml])
    }

    // MARK: - YAML/SKILL.md twins share one compiled file

    func testCompilingAYamlTwinWouldOverwriteTheSkillMdsRecordedSteps() throws {
        let md = try compiledMd(in: tmpDir, "login.md")
        let yaml = try write("login.yaml", "name: Login\nsteps:\n  - home\n")

        XCTAssertEqual(CompiledSkillIO.skillMdTwinOwningCompiledFile(for: yaml), md)
        XCTAssertNil(CompiledSkillIO.skillMdTwinOwningCompiledFile(for: md))
    }

    func testAYamlCompiledFileBelongsToTheYaml() throws {
        _ = try write("login.md", loginMd)
        let yaml = try write("login.yaml", "name: Login\nsteps:\n  - home\n")
        try saveCompiled(for: yaml, steps: [
            CompiledStep(index: 0, type: "home", label: nil, hints: .passthrough()),
        ])

        XCTAssertNil(CompiledSkillIO.skillMdTwinOwningCompiledFile(for: yaml))
    }

    // MARK: - ${VAR} placeholders

    func testCompiledLabelPlaceholdersResolveOnlyWhenLoadingToRun() throws {
        setenv("MIRROIR_LOADER_TEST_USER", "alice", 1)
        defer { unsetenv("MIRROIR_LOADER_TEST_USER") }
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "type", label: "${MIRROIR_LOADER_TEST_USER}",
                         hints: .passthrough()),
        ])

        let toRun = try SkillFileLoader.load(filePath: md)
        let placeholders = try SkillFileLoader.load(filePath: md, substitutingEnv: false)

        XCTAssertEqual(toRun.steps.first?.labelValue, "alice")
        XCTAssertEqual(placeholders.steps.first?.labelValue, "${MIRROIR_LOADER_TEST_USER}")
    }

    func testAPlaceholderValueKeepsItsOwnQuotesOnReplay() throws {
        setenv("MIRROIR_LOADER_TEST_QUOTED", "'s3cret'", 1)
        defer { unsetenv("MIRROIR_LOADER_TEST_QUOTED") }
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: 0, type: "type", label: "${MIRROIR_LOADER_TEST_QUOTED}",
                         hints: .passthrough()),
            CompiledStep(index: 1, type: "drag",
                         label: "{ from: \"${MIRROIR_LOADER_TEST_QUOTED}\", to: \"Trash\" }",
                         hints: .passthrough()),
        ])

        let steps = try SkillFileLoader.load(filePath: md).steps

        XCTAssertEqual(steps.first?.labelValue, "'s3cret'")
        XCTAssertEqual(steps.last?.labelValue, "'s3cret'")
    }

    func testANeverCompiledRootSkillMdLetsANestedYamlOfThatNameRun() throws {
        _ = try write("login.md", loginMd)
        let nested = try makeDir("apps/x")
        let yaml = nested + "/login.yaml"
        try "name: Login\nsteps:\n  - home\n".write(toFile: yaml, atomically: true, encoding: .utf8)

        XCTAssertEqual(RunnerSkillResolver.resolve(name: "login", dirs: [tmpDir]), .run(yaml))
    }

    func testAStaleSkillMdIsReportedEvenBesideANeverCompiledNamesake() throws {
        let staleDir = try makeDir("apps/a")
        let md = try compiledMd(in: staleDir, "foo.md")
        try (loginMd + "\nEdited.\n").write(toFile: md, atomically: true, encoding: .utf8)
        let draft = try makeDir("apps/b")
        try loginMd.write(toFile: draft + "/foo.md", atomically: true, encoding: .utf8)

        XCTAssertEqual(RunnerSkillResolver.resolve(name: "foo", dirs: [tmpDir]), .unusable(md))
    }

    func testAnUnusableSkillMdIsReportedNotSwappedForAnotherSkillOfThatBasename() throws {
        let staleDir = try makeDir("apps/a")
        let md = try compiledMd(in: staleDir, "check.md")
        try (loginMd + "\nEdited.\n").write(toFile: md, atomically: true, encoding: .utf8)
        let other = try makeDir("apps/b")
        try "name: Other\nsteps:\n  - home\n".write(
            toFile: other + "/check.yaml", atomically: true, encoding: .utf8)

        // By path: stops at the stale SKILL.md, whose load then says why.
        XCTAssertEqual(RunnerSkillResolver.resolve(name: "apps/a/check", dirs: [tmpDir]), .unusable(md))
        // By basename: two different skills, ambiguous as MCP resolution says.
        guard case .ambiguous(let matches) = RunnerSkillResolver.resolve(name: "check", dirs: [tmpDir]) else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(matches.count, 2)
    }

    func testCompilingKeepsPlaceholdersOutOfTheCompiledFile() throws {
        setenv("MIRROIR_LOADER_TEST_SECRET", "hunter2", 1)
        defer { unsetenv("MIRROIR_LOADER_TEST_SECRET") }
        let yaml = try write("secret.yaml",
                             "name: Secret\nsteps:\n  - type: \"${MIRROIR_LOADER_TEST_SECRET}\"\n")
        let skill = try SkillFileLoader.load(filePath: yaml)
        XCTAssertEqual(skill.steps.first?.labelValue, "hunter2")

        let recording = RecordingDescriber(wrapping: StubDescriber())
        let executor = StepExecutor(
            bridge: StubBridge(), input: StubInput(), describer: recording,
            capture: StubCapture(),
            config: StepExecutorConfig(waitForTimeoutSeconds: 1, settlingDelayMs: 0,
                                       screenshotDir: tmpDir, dryRun: false))
        let compiled = try XCTUnwrap(CompileCommand.compileSkill(
            skill: skill, executor: executor, recordingDescriber: recording,
            filePath: yaml, windowWidth: 430, windowHeight: 942, orientation: "portrait"))

        XCTAssertEqual(compiled.steps.first?.label, "${MIRROIR_LOADER_TEST_SECRET}")
    }

    func testARecordedValueGetsItsPlaceholderBackOnlyWhenWhole() {
        setenv("MIRROIR_LOADER_TEST_PASS", "hunter2", 1)
        defer { unsetenv("MIRROIR_LOADER_TEST_PASS") }
        let source = """
            1. Type ${MIRROIR_LOADER_TEST_PASS} in Password
            2. Turn Wi-Fi ${MIRROIR_LOADER_TEST_WIFI:-on}
            3. Leave ${MIRROIR_LOADER_TEST_NOT_SET} alone
            """

        XCTAssertEqual(MirroirMCP.envPlaceholder(resolvingTo: "hunter2", in: source),
                       "${MIRROIR_LOADER_TEST_PASS}")
        // A default is written in the skill itself: labels equal to it stay as they are.
        XCTAssertNil(MirroirMCP.envPlaceholder(resolvingTo: "on", in: source))
        // A value inside a longer label is left alone: "Done" must not become D${...}e.
        XCTAssertNil(MirroirMCP.envPlaceholder(resolvingTo: "Done", in: source))
        XCTAssertNil(MirroirMCP.envPlaceholder(resolvingTo: "${MIRROIR_LOADER_TEST_NOT_SET}",
                                               in: source))
    }

    func testQuotedAndStructuredLabelsGetTheirPlaceholdersFieldByField() {
        setenv("MIRROIR_LOADER_TEST_PASS", "hunter2", 1)
        setenv("MIRROIR_LOADER_TEST_USER", "jane", 1)
        defer {
            unsetenv("MIRROIR_LOADER_TEST_PASS")
            unsetenv("MIRROIR_LOADER_TEST_USER")
        }
        let source = "Type ${MIRROIR_LOADER_TEST_PASS}, wait for ${MIRROIR_LOADER_TEST_USER}"
        func stored(_ type: String, _ label: String) -> String? {
            SkillParser.parseStep(key: type, rawValue: label)
                .mappingValues { MirroirMCP.envPlaceholder(resolvingTo: $0, in: source) ?? $0 }
                .replayValue
        }

        XCTAssertEqual(stored("type", "\"hunter2\""), "${MIRROIR_LOADER_TEST_PASS}")
        XCTAssertEqual(stored("wait_for", "\"jane\" timeout: 10"),
                       "\"${MIRROIR_LOADER_TEST_USER}\" timeout: 10")
        XCTAssertEqual(stored("tap", "Done"), "Done")
    }

    func testANameWithItsExtensionStopsAtTheNearerUnusableFile() throws {
        let local = try makeDir("local")
        let global = try makeDir("global")
        try loginMd.write(toFile: local + "/login.md", atomically: true, encoding: .utf8)
        try "name: Login\nsteps:\n  - home\n".write(
            toFile: local + "/login.yaml", atomically: true, encoding: .utf8)
        _ = try compiledMd(in: global, "login.md")

        XCTAssertEqual(RunnerSkillResolver.resolve(name: "login.md", dirs: [local, global]),
                       .unusable(local + "/login.md"))
    }

    func testAGlobRunsACompiledSkillMdInsteadOfItsYamlTwin() throws {
        let md = try compiledMd(in: tmpDir, "login.md")
        _ = try write("login.yaml", "name: Login\nsteps:\n  - home\n")

        XCTAssertEqual(try TestRunner.resolveSkillFiles([tmpDir + "/*"]), [md])
    }

    // MARK: - Indices below 0

    func testNegativeRecordedIndicesAreRefusedWithoutCrashing() throws {
        let md = try write("login.md", loginMd)
        try saveCompiled(for: md, steps: [
            CompiledStep(index: -1, type: "home", label: nil, hints: .passthrough()),
        ])

        XCTAssertEqual(CompiledSkillIO.missingIndices(
            CompiledSkillIO.normalizedSteps([CompiledStep(index: -1, type: "home", label: nil,
                                                          hints: nil)])), [])
        // A huge index is reported as one range, without building it.
        let gaps = CompiledSkillIO.missingIndices([
            CompiledStep(index: 0, type: "home", label: nil, hints: nil),
            CompiledStep(index: Int.max, type: "home", label: nil, hints: nil),
        ])
        XCTAssertEqual(CompiledSkillIO.describe(gaps), "1...\(Int.max - 1)")
        XCTAssertThrowsError(try SkillFileLoader.load(filePath: md)) { error in
            XCTAssertTrue(error.localizedDescription.contains("below 0"),
                          error.localizedDescription)
        }
    }
}
