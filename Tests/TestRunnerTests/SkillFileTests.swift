// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Integration tests that load all real skill files and validate parsing.
// ABOUTME: Ensures every shipped skill (YAML or SKILL.md) parses without errors and uses only recognized step types.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SkillFileTests: XCTestCase {

    private static var projectRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TestRunnerTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // project root
            .path
    }

    private static var skillsDir: String {
        projectRoot + "/.mirroir-mcp/skills"
    }

    // MARK: - Global validation

    func testAllSkillFilesParse() throws {
        let stems = skillStems()
        XCTAssertFalse(stems.isEmpty, "No skill files found in \(Self.skillsDir)")

        for stem in stems {
            let skill = try parseSkill(stem)
            XCTAssertFalse(skill.name.isEmpty, "\(stem): empty name")
            // YAML files have parsed steps; .md files have empty steps (natural language)
            if skill.filePath.hasSuffix(".yaml") {
                XCTAssertFalse(skill.steps.isEmpty, "\(stem): no steps")
            } else {
                XCTAssertFalse(skill.description.isEmpty, "\(stem): empty description")
            }
        }
    }

    func testSkillCount() {
        let stems = skillStems()
        XCTAssertEqual(stems.count, 24, "Expected 24 skills, got \(stems.count): \(stems)")
    }

    func testNoUnexpectedUnknownSteps() throws {
        let knownAIOnlyTypes: Set<String> = [
            "remember", "condition", "repeat", "verify", "summarize",
        ]
        // long_press is used in share-recent — not built into the parser on purpose
        let expectedUnknownTypes: Set<String> = ["long_press"]

        let files = yamlFilesSkippingLegacy()
        for file in files {
            let fullPath = Self.skillsDir + "/" + file
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            let skill = SkillParser.parse(content: content, filePath: fullPath)
            for step in skill.steps {
                if case .skipped(let stepType, let reason) = step {
                    let allowed = knownAIOnlyTypes.contains(stepType)
                        || expectedUnknownTypes.contains(stepType)
                    XCTAssertTrue(allowed,
                        "\(file): unexpected unknown step '\(stepType)' (\(reason))")
                }
            }
        }
    }

    // MARK: - Individual skill validation: apps/

    func testCheckAbout() throws {
        let s = try parseSkill("apps/settings/check-about")
        XCTAssertEqual(s.name, "Read Device Info")
        XCTAssertFalse(s.description.isEmpty)
        if !s.steps.isEmpty {
            XCTAssertTrue(s.description.contains("Settings"))
            XCTAssertEqual(s.steps.count, 9)
            assertStepKinds(s.steps, [
                "launch", "wait_for", "tap", "wait_for", "tap",
                "wait_for", "remember", "assert_visible", "screenshot",
            ], file: "check-about")
        }
    }

    func testCheckAboutFr() throws {
        let s = try parseSkill("apps/settings/check-about-fr")
        XCTAssertEqual(s.name, "Vérifier l'écran À propos")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 7)
        }
    }

    func testSetTimer() throws {
        let s = try parseSkill("apps/clock/set-timer")
        XCTAssertEqual(s.name, "Set Timer")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 8)
            assertContains(s, "assert_visible")
        }
    }

    func testSetAlarm() throws {
        let s = try parseSkill("apps/clock/set-alarm")
        XCTAssertEqual(s.name, "Set Alarm")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 10)
            assertContains(s, "type")
        }
    }

    func testCheckToday() throws {
        let s = try parseSkill("apps/calendar/check-today")
        XCTAssertEqual(s.name, "Read Today's Schedule")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 6)
            assertContains(s, "remember")
        }
    }

    func testCreateEvent() throws {
        let s = try parseSkill("apps/calendar/create-event")
        XCTAssertEqual(s.name, "Create Calendar Event")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 11)
        }
    }

    func testCheckForecast() throws {
        let s = try parseSkill("apps/weather/check-forecast")
        XCTAssertEqual(s.name, "Read Weather Forecast")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 8)
            assertContains(s, "swipe")
            assertContains(s, "remember")
        }
    }

    func testAddCity() throws {
        let s = try parseSkill("apps/weather/add-city")
        XCTAssertEqual(s.name, "Add City to Weather")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 12)
        }
    }

    func testSendMessage() throws {
        let s = try parseSkill("apps/slack/send-message")
        XCTAssertEqual(s.name, "Send Slack Message")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 11)
            assertContains(s, "press_key")
        }
    }

    func testCheckUnread() throws {
        let s = try parseSkill("apps/slack/check-unread")
        XCTAssertEqual(s.name, "Read Unread Slack Messages")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 6)
        }
    }

    func testSaveDirections() throws {
        let s = try parseSkill("apps/maps/save-directions")
        XCTAssertEqual(s.name, "Get Directions and Travel Time")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 11)
        }
    }

    func testShareRecent() throws {
        let s = try parseSkill("apps/photos/share-recent")
        XCTAssertEqual(s.name, "Share Recent Photo")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 16)
            // long_press is intentionally an unknown step type (AI-only gesture)
            let longPress = s.steps.filter {
                if case .skipped(let t, _) = $0, t == "long_press" { return true }
                return false
            }
            XCTAssertEqual(longPress.count, 1,
                "Expected exactly 1 long_press step in share-recent")
        }
    }

    func testListApps() throws {
        let s = try parseSkill("apps/settings/list-apps")
        XCTAssertEqual(s.name, "List Installed Apps")
        XCTAssertTrue(s.description.contains("iPhone Storage"))
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 14)
            assertContains(s, "remember")
            assertContains(s, "swipe")
        }
    }

    func testInstallApp() throws {
        let s = try parseSkill("apps/appstore/install-app")
        XCTAssertEqual(s.name, "Install App from App Store")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 17)
            assertContains(s, "condition")
            assertContains(s, "press_key")
        }
    }

    func testUninstallApp() throws {
        let s = try parseSkill("apps/settings/uninstall-app")
        XCTAssertEqual(s.name, "Uninstall App")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 13)
            assertContains(s, "scroll_to")
        }
    }

    // MARK: - Individual skill validation: apps/mail

    func testEmailTriage() throws {
        let s = try parseSkill("apps/mail/email-triage")
        XCTAssertEqual(s.name, "Email Triage")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 13)
            // Two nested condition blocks are flattened by the parser
            let conditions = s.steps.filter {
                if case .skipped(let t, _) = $0, t == "condition" { return true }
                return false
            }
            XCTAssertEqual(conditions.count, 2, "Expected 2 nested conditions")
        }
    }

    func testBatchArchive() throws {
        let s = try parseSkill("apps/mail/batch-archive")
        XCTAssertEqual(s.name, "Batch Archive Inbox")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 12)
            assertContains(s, "repeat")
            assertContains(s, "assert_not_visible")
        }
    }

    // MARK: - Individual skill validation: testing/

    func testLoginFlow() throws {
        let s = try parseSkill("testing/expo-go/login-flow")
        XCTAssertEqual(s.name, "Expo Go Login Flow")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 20)
            assertContains(s, "condition")
        }
    }

    func testShakeDebugMenu() throws {
        let s = try parseSkill("testing/expo-go/shake-debug-menu")
        XCTAssertEqual(s.name, "Expo Go Debug Menu")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 7)
            assertContains(s, "shake")
        }
    }

    func testQASmokePack() throws {
        let s = try parseSkill("testing/expo-go/qa-smoke-pack")
        XCTAssertEqual(s.name, "Visual Regression Test")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 15)
            assertContains(s, "remember")
        }
    }

    // MARK: - Individual skill validation: workflows/

    func testCommuteETA() throws {
        let s = try parseSkill("workflows/commute-eta-notify")
        XCTAssertEqual(s.name, "Commute ETA Notification")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 26)
            assertContains(s, "home")
            assertContains(s, "press_key")
            assertContains(s, "remember")
        }
    }

    func testMorningBriefing() throws {
        let s = try parseSkill("workflows/morning-briefing")
        XCTAssertEqual(s.name, "Morning Briefing")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 25)
            assertContains(s, "home")
            assertContains(s, "remember")
        }
    }

    func testStandupAutoposter() throws {
        let s = try parseSkill("workflows/standup-autoposter")
        XCTAssertEqual(s.name, "Standup Autoposter")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 20)
            assertContains(s, "home")
            assertContains(s, "press_key")
        }
    }

    // MARK: - Individual skill validation: ci/

    func testFakeMirroringCheck() throws {
        let s = try parseSkill("ci/fake-mirroring-check")
        XCTAssertEqual(s.name, "FakeMirroring smoke test")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 10)
            assertContains(s, "home")
            assertContains(s, "assert_not_visible")
        }
    }

    // MARK: - Step type coverage across all skills

    func testAllExecutableStepTypesCovered() throws {
        let files = yamlFilesSkippingLegacy()
        var seenTypes: Set<String> = []

        for file in files {
            let fullPath = Self.skillsDir + "/" + file
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            let skill = SkillParser.parse(content: content, filePath: fullPath)
            for step in skill.steps {
                seenTypes.insert(stepKind(step))
            }
        }

        // When no YAML files exist (CI with .md-only), skip step-type coverage
        guard !files.isEmpty else { return }

        // Step types that appear in at least one real skill
        let expectedInSkills: Set<String> = [
            "launch", "tap", "type", "press_key", "swipe",
            "wait_for", "assert_visible", "assert_not_visible",
            "screenshot", "home", "shake", "scroll_to",
            "remember", "condition", "repeat", "long_press",
        ]
        for expected in expectedInSkills {
            XCTAssertTrue(seenTypes.contains(expected),
                "Step type '\(expected)' not found in any skill")
        }

        // These types are only tested synthetically (SkillParserTests),
        // not used in any shipped skill yet:
        // open_url, scroll_to, reset_app, set_network, measure
    }

    // MARK: - Header extraction from real files

    func testAllFilesHaveValidHeaders() throws {
        let stems = skillStems()

        for stem in stems {
            let path = try resolveSkillPath(stem)
            let info = MirroirMCP.extractSkillHeader(
                from: path, source: "local")
            XCTAssertFalse(info.name.isEmpty, "\(stem): empty header name")
        }
    }

    func testAllSkillsHaveDescriptions() throws {
        let stems = skillStems()

        for stem in stems {
            let path = try resolveSkillPath(stem)
            let info = MirroirMCP.extractSkillHeader(
                from: path, source: "local")
            XCTAssertFalse(info.description.isEmpty,
                "\(stem): description parsed as empty")
            XCTAssertFalse(info.description.contains("\n"),
                "\(stem): description should be a single line")
        }
    }

    // MARK: - Env var pattern validation

    func testEnvVarPatternsAreWellFormed() throws {
        let envVarPattern = try NSRegularExpression(pattern: "\\$\\{([^}]+)\\}")
        let stems = skillStems()

        for stem in stems {
            let path = try resolveSkillPath(stem)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let range = NSRange(content.startIndex..., in: content)
            let matches = envVarPattern.matches(in: content, range: range)

            for match in matches {
                let varRange = Range(match.range(at: 1), in: content)!
                let varExpr = String(content[varRange])

                // Format: VAR_NAME or VAR_NAME:-default
                let parts = varExpr.split(separator: ":", maxSplits: 1)
                let varName = String(parts[0])
                XCTAssertTrue(
                    varName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" },
                    "\(stem): env var '\(varName)' contains invalid characters")
                XCTAssertTrue(varName == varName.uppercased(),
                    "\(stem): env var '\(varName)' should be UPPER_SNAKE_CASE")
            }
        }
    }

    func testEnvVarSubstitutionOnRealContent() throws {
        let path = try resolveSkillPath("apps/slack/send-message")
        let content = try String(contentsOfFile: path, encoding: .utf8)

        // Set env vars and verify substitution
        setenv("RECIPIENT", "Alice", 1)
        setenv("MESSAGE", "Hi there!", 1)
        defer {
            unsetenv("RECIPIENT")
            unsetenv("MESSAGE")
        }

        let substituted = MirroirMCP.substituteEnvVars(in: content)
        XCTAssertTrue(substituted.contains("Alice"),
            "RECIPIENT not substituted")
        XCTAssertTrue(substituted.contains("Hi there!"),
            "MESSAGE not substituted")
        XCTAssertFalse(substituted.contains("${RECIPIENT}"),
            "RECIPIENT placeholder still present after substitution")
    }

    func testEnvVarDefaultsApplied() throws {
        let path = try resolveSkillPath("apps/clock/set-alarm")
        let content = try String(contentsOfFile: path, encoding: .utf8)

        // Do NOT set ALARM_LABEL — should fall back to default
        unsetenv("ALARM_LABEL")

        let substituted = MirroirMCP.substituteEnvVars(in: content)
        XCTAssertTrue(substituted.contains("Wake Up"),
            "Default 'Wake Up' not applied when ALARM_LABEL is unset")
    }

    // MARK: - Helpers

    /// Parse a skill by stem (no extension). Tries .yaml first for full parsing
    /// with steps, then falls back to .md for header-only parsing.
    private func parseSkill(_ stem: String) throws -> SkillDefinition {
        let yamlPath = Self.skillsDir + "/" + stem + ".yaml"
        if FileManager.default.fileExists(atPath: yamlPath) {
            let content = try String(contentsOfFile: yamlPath, encoding: .utf8)
            return SkillParser.parse(content: content, filePath: yamlPath)
        }
        let mdPath = Self.skillsDir + "/" + stem + ".md"
        let content = try String(contentsOfFile: mdPath, encoding: .utf8)
        let fallbackName = (stem as NSString).lastPathComponent
        let header = SkillMdParser.parseHeader(content: content, fallbackName: fallbackName)
        return SkillDefinition(
            name: header.name,
            description: header.description,
            filePath: mdPath,
            steps: [],
            targets: []
        )
    }

    /// Resolve a skill stem to its actual file path (.yaml preferred, then .md).
    private func resolveSkillPath(_ stem: String) throws -> String {
        let yamlPath = Self.skillsDir + "/" + stem + ".yaml"
        if FileManager.default.fileExists(atPath: yamlPath) { return yamlPath }
        let mdPath = Self.skillsDir + "/" + stem + ".md"
        if FileManager.default.fileExists(atPath: mdPath) { return mdPath }
        throw NSError(
            domain: "SkillFileTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No .yaml or .md file found for '\(stem)'"])
    }

    /// Return unique skill stems from the skills directory, filtering out legacy/,
    /// dotfile directories (.claude/, .github/), and root-level non-skill .md files.
    /// When both .yaml and .md exist for the same stem, only one entry is returned.
    private func skillStems() -> [String] {
        let allFiles = MirroirMCP.findSkillFiles(in: Self.skillsDir)
        var seenStems = Set<String>()
        var stems: [String] = []

        for relPath in allFiles {
            // Skip legacy directory
            if relPath.hasPrefix("legacy/") { continue }
            // Skip dotfile directories (.claude/, .github/)
            let pathComponents = relPath.components(separatedBy: "/")
            if pathComponents.contains(where: { $0.hasPrefix(".") }) { continue }
            // Skip root-level .md files (README.md, CLA.md, etc.)
            if pathComponents.count == 1 && relPath.hasSuffix(".md") { continue }

            let stem = MirroirMCP.skillStem(relPath)
            if seenStems.contains(stem) { continue }
            seenStems.insert(stem)
            stems.append(stem)
        }

        return stems.sorted()
    }

    /// Return non-legacy .yaml files for tests that require parsed steps.
    private func yamlFilesSkippingLegacy() -> [String] {
        MirroirMCP.findYAMLFiles(in: Self.skillsDir).filter {
            !$0.hasPrefix("legacy/")
        }
    }

    /// Map a SkillStep to its string kind for comparison.
    private func stepKind(_ step: SkillStep) -> String {
        switch step {
        case .launch: return "launch"
        case .tap: return "tap"
        case .type: return "type"
        case .pressKey: return "press_key"
        case .swipe: return "swipe"
        case .waitFor: return "wait_for"
        case .assertVisible: return "assert_visible"
        case .assertNotVisible: return "assert_not_visible"
        case .screenshot: return "screenshot"
        case .home: return "home"
        case .openURL: return "open_url"
        case .shake: return "shake"
        case .scrollTo: return "scroll_to"
        case .resetApp: return "reset_app"
        case .setNetwork: return "set_network"
        case .measure: return "measure"
        case .switchTarget: return "target"
        case .skipped(let type, _): return type
        }
    }

    private func assertContains(
        _ skill: SkillDefinition, _ kind: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let found = skill.steps.contains { stepKind($0) == kind }
        XCTAssertTrue(found,
            "'\(skill.name)' missing expected step type '\(kind)'",
            file: file, line: line)
    }

    private func assertStepKinds(
        _ steps: [SkillStep], _ expected: [String],
        file: String, testFile: StaticString = #filePath, testLine: UInt = #line
    ) {
        XCTAssertEqual(steps.count, expected.count,
            "\(file): step count mismatch", file: testFile, line: testLine)

        for (i, (step, kind)) in zip(steps, expected).enumerated() {
            XCTAssertEqual(stepKind(step), kind,
                "\(file) step \(i): expected '\(kind)' but got '\(stepKind(step))'",
                file: testFile, line: testLine)
        }
    }
}
