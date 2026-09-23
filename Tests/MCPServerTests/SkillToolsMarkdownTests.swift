// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for skill discovery and resolution of SKILL.md files alongside YAML skills.
// ABOUTME: Covers findSkillFiles, discoverSkills, resolveSkill with .md and yamlOnly.

import XCTest
import HelperLib
@testable import mirroir_mcp

extension SkillToolsTests {

    // MARK: - findSkillFiles (.md + .yaml)

    func testFindSkillFilesIncludesMd() {
        createFile("a.yaml", content: "name: A")
        createFile("b.md", content: "---\nname: B\n---\n\nBody")
        createFile("c.txt", content: "not a skill")

        let results = MirroirMCP.findSkillFiles(in: tmpDir)
        XCTAssertTrue(results.contains("a.yaml"))
        XCTAssertTrue(results.contains("b.md"))
        XCTAssertFalse(results.contains("c.txt"))
    }

    func testFindSkillFilesMdBeforeYamlForSameStem() {
        createFile("test.yaml", content: "name: YAML")
        createFile("test.md", content: "---\nname: MD\n---\n\nBody")

        let results = MirroirMCP.findSkillFiles(in: tmpDir)
        // .md should come before .yaml for the same stem
        let mdIndex = results.firstIndex(of: "test.md")
        let yamlIndex = results.firstIndex(of: "test.yaml")
        XCTAssertNotNil(mdIndex)
        XCTAssertNotNil(yamlIndex)
        XCTAssertTrue(mdIndex! < yamlIndex!)
    }

    // MARK: - discoverSkills with .md

    func testDiscoverMdFiles() {
        // Create a skill dir structure that mimics what discoverSkills expects
        let skillDir = tmpDir + "/skills"
        createFile("skills/test.md",
                    content: "---\nname: MD Skill\n---\n\nDescription here.",
                    baseDir: tmpDir)

        // Directly test findSkillFiles and extractSkillHeader on the dir
        let files = MirroirMCP.findSkillFiles(in: skillDir)
        XCTAssertEqual(files, ["test.md"])

        let filePath = skillDir + "/" + files[0]
        let info = MirroirMCP.extractSkillHeader(from: filePath, source: "local")
        XCTAssertEqual(info.name, "MD Skill")
        XCTAssertEqual(info.description, "Description here.")
    }

    func testMdOverridesYamlInDiscovery() {
        // When both .md and .yaml exist with the same stem, .md wins
        let skillDir = tmpDir + "/skills"
        createFile("skills/test.yaml", content: "name: YAML Version\ndescription: from yaml",
                    baseDir: tmpDir)
        createFile("skills/test.md",
                    content: "---\nname: MD Version\n---\n\nFrom markdown.",
                    baseDir: tmpDir)

        let files = MirroirMCP.findSkillFiles(in: skillDir)
        // Both files should be found
        XCTAssertTrue(files.contains("test.md"))
        XCTAssertTrue(files.contains("test.yaml"))

        // Simulate discoverSkills dedup: first seen stem wins
        var seenStems = Set<String>()
        var results: [MirroirMCP.SkillInfo] = []
        for relPath in files {
            let stem = MirroirMCP.skillStem(relPath)
            if seenStems.contains(stem) { continue }
            seenStems.insert(stem)
            let filePath = skillDir + "/" + relPath
            let info = MirroirMCP.extractSkillHeader(from: filePath, source: "local")
            results.append(info)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "MD Version")
    }

    // MARK: - resolveSkill with .md

    func testResolveMdFile() {
        createFile("test.md", content: "---\nname: MD Test\n---\n\nBody")
        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "test", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.md"))
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveMdPreferredOverYaml() {
        createFile("test.yaml", content: "name: YAML")
        createFile("test.md", content: "---\nname: MD\n---\n\nBody")

        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "test", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.md"), "Expected .md to be preferred over .yaml")
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveMdWithExplicitExtension() {
        createFile("test.md", content: "---\nname: MD\n---\n\nBody")
        let (path, _) = MirroirMCP.resolveSkill(
            name: "test.md", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.md"))
    }

    func testResolveYamlStillWorksWhenNoMd() {
        createFile("test.yaml", content: "name: YAML Only")
        let (path, _) = MirroirMCP.resolveSkill(
            name: "test", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.yaml"))
    }

    func testResolveMdInSubdirectory() {
        createFile("apps/slack/send.md",
                    content: "---\nname: Send\n---\n\nBody")
        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "apps/slack/send", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("send.md"))
        XCTAssertTrue(ambiguous.isEmpty)
    }

    // MARK: - resolveSkill with yamlOnly

    func testResolveYamlOnlySkipsMd() {
        // When both .md and .yaml exist, yamlOnly: true returns the .yaml
        createFile("test.yaml", content: "name: YAML Version")
        createFile("test.md", content: "---\nname: MD Version\n---\n\nBody")

        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "test", dirs: [tmpDir], yamlOnly: true)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.yaml"),
            "yamlOnly should resolve to .yaml, got: \(path!)")
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveYamlOnlyPhase2() {
        // Basename resolution with yamlOnly: true finds YAML in subdirectory
        createFile("apps/slack/send.yaml", content: "name: Slack Send")
        createFile("apps/slack/send.md", content: "---\nname: Slack Send MD\n---\n\nBody")

        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "send", dirs: [tmpDir], yamlOnly: true)
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("send.yaml"),
            "yamlOnly Phase 2 should resolve to .yaml, got: \(path!)")
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveYamlOnlyMdOnlyFileNotFound() {
        // When only .md exists, yamlOnly: true should not find it
        createFile("test.md", content: "---\nname: MD Only\n---\n\nBody")

        let (path, ambiguous) = MirroirMCP.resolveSkill(
            name: "test", dirs: [tmpDir], yamlOnly: true)
        XCTAssertNil(path, "yamlOnly should not resolve .md-only skills")
        XCTAssertTrue(ambiguous.isEmpty)
    }

    func testResolveYamlOnlyDefaultFalse() {
        // Default behavior (yamlOnly not specified) still prefers .md
        createFile("test.yaml", content: "name: YAML")
        createFile("test.md", content: "---\nname: MD\n---\n\nBody")

        let (path, _) = MirroirMCP.resolveSkill(
            name: "test", dirs: [tmpDir])
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasSuffix("test.md"),
            "Default behavior should prefer .md")
    }
}
