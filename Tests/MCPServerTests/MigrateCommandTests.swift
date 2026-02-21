// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for MigrateCommand: YAML scenario to SKILL.md conversion.
// ABOUTME: Validates step conversion, conditions, repeats, env var preservation, and comments.

import XCTest
@testable import mirroir_mcp

final class MigrateCommandTests: XCTestCase {

    // MARK: - Simple Scenario

    func testMigrateSimpleScenario() {
        let yaml = """
        name: Read Device Info
        app: Settings
        description: Navigate to Settings > General > About
        ios_min: "17.0"
        locale: "en_US"
        tags: ["settings", "device-info"]

        steps:
          - launch: "Settings"
          - wait_for: "General"
          - tap: "General"
          - screenshot: "device_info"
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        // Check front matter
        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("version: 1"))
        XCTAssertTrue(md.contains("name: Read Device Info"))
        XCTAssertTrue(md.contains("app: Settings"))
        XCTAssertTrue(md.contains("ios_min: \"17.0\""))
        XCTAssertTrue(md.contains("locale: \"en_US\""))
        XCTAssertTrue(md.contains("tags: [\"settings\", \"device-info\"]"))

        // Check description
        XCTAssertTrue(md.contains("Navigate to Settings > General > About"))

        // Check steps
        XCTAssertTrue(md.contains("## Steps"))
        XCTAssertTrue(md.contains("1. Launch **Settings**"))
        XCTAssertTrue(md.contains("2. Wait for \"General\" to appear"))
        XCTAssertTrue(md.contains("3. Tap \"General\""))
        XCTAssertTrue(md.contains("4. Screenshot: \"device_info\""))
    }

    // MARK: - Conditions

    func testMigrateWithConditions() {
        let yaml = """
        name: Email Triage
        app: Mail
        description: Triage emails
        tags: ["mail"]

        steps:
          - launch: "Mail"
          - wait_for: "Inbox"
          - condition:
              if_visible: "Unread"
              then:
                - tap: "Unread"
                - screenshot: "opened_unread"
              else:
                - screenshot: "empty_inbox"
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        XCTAssertTrue(md.contains("1. Launch **Mail**"))
        XCTAssertTrue(md.contains("2. Wait for \"Inbox\" to appear"))
        XCTAssertTrue(md.contains("3. If \"Unread\" is visible:"))
        XCTAssertTrue(md.contains("   1. Tap \"Unread\""))
        XCTAssertTrue(md.contains("   2. Screenshot: \"opened_unread\""))
        XCTAssertTrue(md.contains("   Otherwise:"))
        XCTAssertTrue(md.contains("   1. Screenshot: \"empty_inbox\""))
    }

    // MARK: - Repeats

    func testMigrateWithRepeats() {
        let yaml = """
        name: Batch Archive
        app: Mail
        description: Archive all emails
        tags: ["mail"]

        steps:
          - launch: "Mail"
          - repeat:
              while_visible: "Unread"
              max: 20
              steps:
                - tap: "Unread"
                - tap: "Archive"
          - screenshot: "done"
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        XCTAssertTrue(md.contains("1. Launch **Mail**"))
        XCTAssertTrue(md.contains("2. Repeat while \"Unread\" is visible (max 20):"))
        XCTAssertTrue(md.contains("   1. Tap \"Unread\""))
        XCTAssertTrue(md.contains("   2. Tap \"Archive\""))
        XCTAssertTrue(md.contains("3. Screenshot: \"done\""))
    }

    // MARK: - Environment Variables

    func testMigratePreservesEnvVars() {
        let yaml = """
        name: Send Message
        app: Slack
        description: Send a DM
        tags: ["slack"]

        steps:
          - launch: "Slack"
          - tap: "${RECIPIENT}"
          - type: "${MESSAGE:-Hey!}"
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        XCTAssertTrue(md.contains("Tap \"${RECIPIENT}\""))
        XCTAssertTrue(md.contains("Type \"${MESSAGE:-Hey!}\""))
    }

    // MARK: - Comments

    func testMigrateWithComments() {
        let yaml = """
        # This scenario tests basic Settings navigation
        name: Check About
        app: Settings
        description: Check device info
        tags: ["settings"]

        steps:
          - launch: "Settings"
          - tap: "General"
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        XCTAssertTrue(md.contains("> Note: This scenario tests basic Settings navigation"))
    }

    // MARK: - Block Scalar Description

    func testMigrateBlockScalarDescription() {
        let yaml = """
        name: Multi Line
        app: Mail
        description: >
          This is a long description
          that spans multiple lines
          in folded style.
        tags: ["mail"]

        steps:
          - launch: "Mail"
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        XCTAssertTrue(md.contains(
            "This is a long description that spans multiple lines in folded style."))
    }

    // MARK: - All Step Types

    func testMigrateAllStepTypes() {
        let yaml = """
        name: All Steps
        app: Test
        description: Test all step types
        tags: ["test"]

        steps:
          - launch: "TestApp"
          - tap: "Button"
          - type: "hello"
          - wait_for: "Label"
          - assert_visible: "Text"
          - assert_not_visible: "Hidden"
          - screenshot: "capture"
          - press_key: "return"
          - press_key: "l+command"
          - press_home: true
          - open_url: "https://example.com"
          - shake
          - scroll_to: "Bottom"
          - reset_app: "TestApp"
          - set_network: "wifi_off"
          - target: "secondary"
          - remember: "Note the value displayed"
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        XCTAssertTrue(md.contains("Launch **TestApp**"))
        XCTAssertTrue(md.contains("Tap \"Button\""))
        XCTAssertTrue(md.contains("Type \"hello\""))
        XCTAssertTrue(md.contains("Wait for \"Label\" to appear"))
        XCTAssertTrue(md.contains("Verify \"Text\" is visible"))
        XCTAssertTrue(md.contains("Verify \"Hidden\" is NOT visible"))
        XCTAssertTrue(md.contains("Screenshot: \"capture\""))
        XCTAssertTrue(md.contains("Press **Return**"))
        XCTAssertTrue(md.contains("Press **Cmd+L**"))
        XCTAssertTrue(md.contains("Press Home"))
        XCTAssertTrue(md.contains("Open URL: https://example.com"))
        XCTAssertTrue(md.contains("Shake the device"))
        XCTAssertTrue(md.contains("Scroll until \"Bottom\" is visible"))
        XCTAssertTrue(md.contains("Force-quit **TestApp**"))
        XCTAssertTrue(md.contains("Turn off Wi-Fi"))
        XCTAssertTrue(md.contains("Switch to target \"secondary\""))
        XCTAssertTrue(md.contains("Remember: Note the value displayed"))
    }

    // MARK: - Nested Conditions

    func testMigrateNestedConditions() {
        let yaml = """
        name: Nested
        app: Mail
        description: Nested conditions
        tags: ["mail"]

        steps:
          - launch: "Mail"
          - condition:
              if_visible: "Unread"
              then:
                - tap: "Unread"
                - condition:
                    if_visible: "Urgent"
                    then:
                      - tap: "Flag"
                    else:
                      - tap: "Archive"
              else:
                - screenshot: "empty"
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        XCTAssertTrue(md.contains("2. If \"Unread\" is visible:"))
        XCTAssertTrue(md.contains("   1. Tap \"Unread\""))
        XCTAssertTrue(md.contains("   2. If \"Urgent\" is visible:"))
        XCTAssertTrue(md.contains("      1. Tap \"Flag\""))
        XCTAssertTrue(md.contains("      Otherwise:"))
        XCTAssertTrue(md.contains("      1. Tap \"Archive\""))
        XCTAssertTrue(md.contains("   Otherwise:"))
    }

    // MARK: - File Migration

    func testMigrateFileCreatesOutput() throws {
        let tmpDir = NSTemporaryDirectory() + "migrate-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let yamlPath = tmpDir + "/test.yaml"
        let yaml = """
        name: File Test
        app: Settings
        description: Test file migration
        tags: ["test"]

        steps:
          - launch: "Settings"
          - tap: "General"
        """
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let result = MigrateCommand.migrateFile(filePath: yamlPath, outputDir: nil, dryRun: false)
        XCTAssertTrue(result)

        let mdPath = tmpDir + "/test.md"
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdPath))

        let mdContent = try String(contentsOfFile: mdPath, encoding: .utf8)
        XCTAssertTrue(mdContent.contains("name: File Test"))
        XCTAssertTrue(mdContent.contains("Launch **Settings**"))
    }

    func testMigrateDryRunDoesNotWriteFile() throws {
        let tmpDir = NSTemporaryDirectory() + "migrate-dryrun-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let yamlPath = tmpDir + "/test.yaml"
        let yaml = """
        name: Dry Run Test
        description: Should not write
        tags: ["test"]

        steps:
          - launch: "App"
        """
        try yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)

        let result = MigrateCommand.migrateFile(filePath: yamlPath, outputDir: nil, dryRun: true)
        XCTAssertTrue(result)

        let mdPath = tmpDir + "/test.md"
        XCTAssertFalse(FileManager.default.fileExists(atPath: mdPath))
    }

    // MARK: - Network Modes

    func testMigrateNetworkModes() {
        XCTAssertEqual(
            MigrateCommand.formatSimpleStep(key: "set_network", value: "airplane_on"),
            "Turn on Airplane Mode")
        XCTAssertEqual(
            MigrateCommand.formatSimpleStep(key: "set_network", value: "airplane_off"),
            "Turn off Airplane Mode")
        XCTAssertEqual(
            MigrateCommand.formatSimpleStep(key: "set_network", value: "wifi_on"),
            "Turn on Wi-Fi")
        XCTAssertEqual(
            MigrateCommand.formatSimpleStep(key: "set_network", value: "cellular_off"),
            "Turn off Cellular")
    }

    // MARK: - Output Dir Path Preservation

    func testResolveOutputPathPreservesSubdirectories() {
        // When --dir provides the base, subdirectory structure should be preserved
        let result = MigrateCommand.resolveOutputPath(
            yamlPath: "/src/scenarios/apps/settings/check-about.yaml",
            outputDir: "/output",
            sourceBaseDir: "/src/scenarios")

        XCTAssertEqual(result, "/output/apps/settings/check-about.md")
    }

    func testResolveOutputPathPreservesSubdirsWithTrailingSlash() {
        let result = MigrateCommand.resolveOutputPath(
            yamlPath: "/src/scenarios/apps/settings/check-about.yaml",
            outputDir: "/output",
            sourceBaseDir: "/src/scenarios/")

        XCTAssertEqual(result, "/output/apps/settings/check-about.md")
    }

    func testResolveOutputPathFlattensWithoutBaseDir() {
        // When no base dir (individual files), only filename is used
        let result = MigrateCommand.resolveOutputPath(
            yamlPath: "/somewhere/apps/settings/check-about.yaml",
            outputDir: "/output",
            sourceBaseDir: nil)

        XCTAssertEqual(result, "/output/check-about.md")
    }

    func testResolveOutputPathNextToSourceWithoutOutputDir() {
        let result = MigrateCommand.resolveOutputPath(
            yamlPath: "/src/scenarios/apps/check-about.yaml",
            outputDir: nil,
            sourceBaseDir: nil)

        XCTAssertEqual(result, "/src/scenarios/apps/check-about.md")
    }

    func testMigrateOutputDirPreservesDirectoryStructure() throws {
        let tmpDir = NSTemporaryDirectory() + "migrate-outdir-\(UUID().uuidString)"
        let srcDir = tmpDir + "/src"
        let outDir = tmpDir + "/out"
        try FileManager.default.createDirectory(
            atPath: srcDir + "/apps/settings", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: srcDir + "/workflows", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let yaml1 = "name: About\napp: Settings\ndescription: Check\n\nsteps:\n  - launch: \"Settings\"\n"
        let yaml2 = "name: Morning\napp: Waze\ndescription: Routine\n\nsteps:\n  - launch: \"Waze\"\n"
        try yaml1.write(toFile: srcDir + "/apps/settings/about.yaml",
                        atomically: true, encoding: .utf8)
        try yaml2.write(toFile: srcDir + "/workflows/morning.yaml",
                        atomically: true, encoding: .utf8)

        // Migrate with sourceBaseDir
        let r1 = MigrateCommand.migrateFile(
            filePath: srcDir + "/apps/settings/about.yaml",
            outputDir: outDir, sourceBaseDir: srcDir, dryRun: false)
        let r2 = MigrateCommand.migrateFile(
            filePath: srcDir + "/workflows/morning.yaml",
            outputDir: outDir, sourceBaseDir: srcDir, dryRun: false)

        XCTAssertTrue(r1)
        XCTAssertTrue(r2)

        // Subdirectory structure should be preserved
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outDir + "/apps/settings/about.md"),
            "Expected apps/settings/about.md in output dir")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outDir + "/workflows/morning.md"),
            "Expected workflows/morning.md in output dir")
    }

    func testMigrateOutputDirNoCollisionForSameFilename() throws {
        // Two files with the same filename in different subdirs should not collide
        let tmpDir = NSTemporaryDirectory() + "migrate-collision-\(UUID().uuidString)"
        let srcDir = tmpDir + "/src"
        let outDir = tmpDir + "/out"
        try FileManager.default.createDirectory(
            atPath: srcDir + "/apps/mail", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: srcDir + "/apps/slack", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let yaml1 = "name: Mail Login\napp: Mail\ndescription: Login\n\nsteps:\n  - launch: \"Mail\"\n"
        let yaml2 = "name: Slack Login\napp: Slack\ndescription: Login\n\nsteps:\n  - launch: \"Slack\"\n"
        try yaml1.write(toFile: srcDir + "/apps/mail/login.yaml",
                        atomically: true, encoding: .utf8)
        try yaml2.write(toFile: srcDir + "/apps/slack/login.yaml",
                        atomically: true, encoding: .utf8)

        let r1 = MigrateCommand.migrateFile(
            filePath: srcDir + "/apps/mail/login.yaml",
            outputDir: outDir, sourceBaseDir: srcDir, dryRun: false)
        let r2 = MigrateCommand.migrateFile(
            filePath: srcDir + "/apps/slack/login.yaml",
            outputDir: outDir, sourceBaseDir: srcDir, dryRun: false)

        XCTAssertTrue(r1)
        XCTAssertTrue(r2)

        // Both files should exist in separate subdirectories
        let mailContent = try String(contentsOfFile: outDir + "/apps/mail/login.md", encoding: .utf8)
        let slackContent = try String(contentsOfFile: outDir + "/apps/slack/login.md", encoding: .utf8)
        XCTAssertTrue(mailContent.contains("Mail Login"))
        XCTAssertTrue(slackContent.contains("Slack Login"))
    }

    // MARK: - No Steps

    func testMigrateNoSteps() {
        let yaml = """
        name: Empty
        app: Test
        description: No steps
        tags: ["test"]
        """

        let md = MigrateCommand.convertYAMLToSkillMd(content: yaml, filePath: "test.yaml")

        XCTAssertTrue(md.contains("name: Empty"))
        XCTAssertFalse(md.contains("## Steps"))
    }
}
