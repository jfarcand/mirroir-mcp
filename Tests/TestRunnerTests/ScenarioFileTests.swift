// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Integration tests that load all real scenario YAML files and validate parsing.
// ABOUTME: Ensures every shipped scenario parses without errors and uses only recognized step types.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class ScenarioFileTests: XCTestCase {

    private static var projectRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TestRunnerTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // project root
            .path
    }

    private static var scenariosDir: String {
        projectRoot + "/.iphone-mirroir-mcp/scenarios"
    }

    // MARK: - Global validation

    func testAllScenarioFilesParse() throws {
        let files = IPhoneMirroirMCP.findYAMLFiles(in: Self.scenariosDir)
        XCTAssertFalse(files.isEmpty, "No scenario files found in \(Self.scenariosDir)")

        for file in files {
            let scenario = try parseScenario(file)
            XCTAssertFalse(scenario.name.isEmpty, "\(file): empty name")
            XCTAssertFalse(scenario.steps.isEmpty, "\(file): no steps")
        }
    }

    func testScenarioCount() {
        let files = IPhoneMirroirMCP.findYAMLFiles(in: Self.scenariosDir)
        XCTAssertEqual(files.count, 24, "Expected 24 scenarios, got \(files.count): \(files)")
    }

    func testNoUnexpectedUnknownSteps() throws {
        let knownAIOnlyTypes: Set<String> = [
            "remember", "condition", "repeat", "verify", "summarize",
        ]
        // long_press is used in share-recent.yaml — not built into the parser on purpose
        let expectedUnknownTypes: Set<String> = ["long_press"]

        let files = IPhoneMirroirMCP.findYAMLFiles(in: Self.scenariosDir)
        for file in files {
            let scenario = try parseScenario(file)
            for step in scenario.steps {
                if case .skipped(let stepType, let reason) = step {
                    let allowed = knownAIOnlyTypes.contains(stepType)
                        || expectedUnknownTypes.contains(stepType)
                    XCTAssertTrue(allowed,
                        "\(file): unexpected unknown step '\(stepType)' (\(reason))")
                }
            }
        }
    }

    // MARK: - Individual scenario validation: apps/

    func testCheckAbout() throws {
        let s = try parseScenario("apps/settings/check-about.yaml")
        XCTAssertEqual(s.name, "Read Device Info")
        XCTAssertTrue(s.description.contains("Settings"))
        XCTAssertEqual(s.steps.count, 9)
        assertStepKinds(s.steps, [
            "launch", "wait_for", "tap", "wait_for", "tap",
            "wait_for", "remember", "assert_visible", "screenshot",
        ], file: "check-about.yaml")
    }

    func testCheckAboutFr() throws {
        let s = try parseScenario("apps/settings/check-about-fr.yaml")
        XCTAssertEqual(s.name, "Vérifier l'écran À propos")
        XCTAssertEqual(s.steps.count, 7)
    }

    func testSetTimer() throws {
        let s = try parseScenario("apps/clock/set-timer.yaml")
        XCTAssertEqual(s.name, "Set Timer")
        XCTAssertEqual(s.steps.count, 8)
        assertContains(s, "assert_visible")
    }

    func testSetAlarm() throws {
        let s = try parseScenario("apps/clock/set-alarm.yaml")
        XCTAssertEqual(s.name, "Set Alarm")
        XCTAssertEqual(s.steps.count, 10)
        assertContains(s, "type")
    }

    func testCheckToday() throws {
        let s = try parseScenario("apps/calendar/check-today.yaml")
        XCTAssertEqual(s.name, "Read Today's Schedule")
        XCTAssertEqual(s.steps.count, 6)
        assertContains(s, "remember")
    }

    func testCreateEvent() throws {
        let s = try parseScenario("apps/calendar/create-event.yaml")
        XCTAssertEqual(s.name, "Create Calendar Event")
        XCTAssertEqual(s.steps.count, 11)
    }

    func testCheckForecast() throws {
        let s = try parseScenario("apps/weather/check-forecast.yaml")
        XCTAssertEqual(s.name, "Read Weather Forecast")
        XCTAssertEqual(s.steps.count, 8)
        assertContains(s, "swipe")
        assertContains(s, "remember")
    }

    func testAddCity() throws {
        let s = try parseScenario("apps/weather/add-city.yaml")
        XCTAssertEqual(s.name, "Add City to Weather")
        XCTAssertEqual(s.steps.count, 12)
    }

    func testSendMessage() throws {
        let s = try parseScenario("apps/slack/send-message.yaml")
        XCTAssertEqual(s.name, "Send Slack Message")
        XCTAssertEqual(s.steps.count, 11)
        assertContains(s, "press_key")
    }

    func testCheckUnread() throws {
        let s = try parseScenario("apps/slack/check-unread.yaml")
        XCTAssertEqual(s.name, "Read Unread Slack Messages")
        XCTAssertEqual(s.steps.count, 6)
    }

    func testSaveDirections() throws {
        let s = try parseScenario("apps/maps/save-directions.yaml")
        XCTAssertEqual(s.name, "Get Directions and Travel Time")
        XCTAssertEqual(s.steps.count, 11)
    }

    func testShareRecent() throws {
        let s = try parseScenario("apps/photos/share-recent.yaml")
        XCTAssertEqual(s.name, "Share Recent Photo")
        XCTAssertEqual(s.steps.count, 16)
        // long_press is intentionally an unknown step type (AI-only gesture)
        let longPress = s.steps.filter {
            if case .skipped(let t, _) = $0, t == "long_press" { return true }
            return false
        }
        XCTAssertEqual(longPress.count, 1,
            "Expected exactly 1 long_press step in share-recent.yaml")
    }

    func testListApps() throws {
        let s = try parseScenario("apps/settings/list-apps.yaml")
        XCTAssertEqual(s.name, "List Installed Apps")
        XCTAssertTrue(s.description.contains("iPhone Storage"))
        XCTAssertEqual(s.steps.count, 14)
        assertContains(s, "remember")
        assertContains(s, "swipe")
    }

    func testInstallApp() throws {
        let s = try parseScenario("apps/appstore/install-app.yaml")
        XCTAssertEqual(s.name, "Install App from App Store")
        XCTAssertEqual(s.steps.count, 17)
        assertContains(s, "condition")
        assertContains(s, "press_key")
    }

    func testUninstallApp() throws {
        let s = try parseScenario("apps/settings/uninstall-app.yaml")
        XCTAssertEqual(s.name, "Uninstall App")
        XCTAssertEqual(s.steps.count, 13)
        assertContains(s, "scroll_to")
    }

    // MARK: - Individual scenario validation: testing/

    func testLoginFlow() throws {
        let s = try parseScenario("testing/expo-go/login-flow.yaml")
        XCTAssertEqual(s.name, "Expo Go Login Flow")
        XCTAssertEqual(s.steps.count, 20)
        assertContains(s, "condition")
    }

    func testShakeDebugMenu() throws {
        let s = try parseScenario("testing/expo-go/shake-debug-menu.yaml")
        XCTAssertEqual(s.name, "Expo Go Debug Menu")
        XCTAssertEqual(s.steps.count, 7)
        assertContains(s, "shake")
    }

    // MARK: - Individual scenario validation: workflows/

    func testCommuteETA() throws {
        let s = try parseScenario("workflows/commute-eta-notify.yaml")
        XCTAssertEqual(s.name, "Commute ETA Notification")
        XCTAssertEqual(s.steps.count, 26)
        assertContains(s, "home")
        assertContains(s, "press_key")
        assertContains(s, "remember")
    }

    func testMorningBriefing() throws {
        let s = try parseScenario("workflows/morning-briefing.yaml")
        XCTAssertEqual(s.name, "Morning Briefing")
        XCTAssertEqual(s.steps.count, 25)
        assertContains(s, "home")
        assertContains(s, "remember")
    }

    func testStandupAutoposter() throws {
        let s = try parseScenario("workflows/standup-autoposter.yaml")
        XCTAssertEqual(s.name, "Standup Autoposter")
        XCTAssertEqual(s.steps.count, 20)
        assertContains(s, "home")
        assertContains(s, "press_key")
    }

    func testEmailTriage() throws {
        let s = try parseScenario("workflows/email-triage.yaml")
        XCTAssertEqual(s.name, "Email Triage")
        XCTAssertEqual(s.steps.count, 13)
        // Two nested condition blocks are flattened by the parser
        let conditions = s.steps.filter {
            if case .skipped(let t, _) = $0, t == "condition" { return true }
            return false
        }
        XCTAssertEqual(conditions.count, 2, "Expected 2 nested conditions")
    }

    func testBatchArchive() throws {
        let s = try parseScenario("workflows/batch-archive.yaml")
        XCTAssertEqual(s.name, "Batch Archive Inbox")
        XCTAssertEqual(s.steps.count, 12)
        assertContains(s, "repeat")
        assertContains(s, "assert_not_visible")
    }

    func testQASmokePack() throws {
        let s = try parseScenario("workflows/qa-smoke-pack.yaml")
        XCTAssertEqual(s.name, "Visual Regression Test")
        XCTAssertEqual(s.steps.count, 15)
        assertContains(s, "remember")
    }

    // MARK: - Individual scenario validation: ci/

    func testFakeMirroringCheck() throws {
        let s = try parseScenario("ci/fake-mirroring-check.yaml")
        XCTAssertEqual(s.name, "FakeMirroring smoke test")
        XCTAssertEqual(s.steps.count, 10)
        assertContains(s, "home")
        assertContains(s, "assert_not_visible")
    }

    // MARK: - Step type coverage across all scenarios

    func testAllExecutableStepTypesCovered() throws {
        let files = IPhoneMirroirMCP.findYAMLFiles(in: Self.scenariosDir)
        var seenTypes: Set<String> = []

        for file in files {
            let scenario = try parseScenario(file)
            for step in scenario.steps {
                seenTypes.insert(stepKind(step))
            }
        }

        // Step types that appear in at least one real scenario
        let expectedInScenarios: Set<String> = [
            "launch", "tap", "type", "press_key", "swipe",
            "wait_for", "assert_visible", "assert_not_visible",
            "screenshot", "home", "shake", "scroll_to",
            "remember", "condition", "repeat", "long_press",
        ]
        for expected in expectedInScenarios {
            XCTAssertTrue(seenTypes.contains(expected),
                "Step type '\(expected)' not found in any scenario")
        }

        // These types are only tested synthetically (ScenarioParserTests),
        // not used in any shipped scenario yet:
        // open_url, scroll_to, reset_app, set_network, measure
    }

    // MARK: - Header extraction from real files

    func testAllFilesHaveValidHeaders() throws {
        let files = IPhoneMirroirMCP.findYAMLFiles(in: Self.scenariosDir)

        for file in files {
            let fullPath = Self.scenariosDir + "/" + file
            let info = IPhoneMirroirMCP.extractScenarioHeader(
                from: fullPath, source: "local")
            XCTAssertFalse(info.name.isEmpty, "\(file): empty header name")
        }
    }

    func testBlockScalarDescriptionsParseCleanly() throws {
        // Scenarios using > or | block scalars for description
        let blockScalarFiles = [
            "apps/settings/check-about.yaml",
            "apps/settings/list-apps.yaml",
            "apps/settings/uninstall-app.yaml",
            "apps/appstore/install-app.yaml",
            "apps/calendar/check-today.yaml",
            "apps/weather/check-forecast.yaml",
            "apps/maps/save-directions.yaml",
            "apps/photos/share-recent.yaml",
            "apps/slack/check-unread.yaml",
            "workflows/commute-eta-notify.yaml",
            "workflows/morning-briefing.yaml",
            "workflows/standup-autoposter.yaml",
            "workflows/email-triage.yaml",
            "workflows/batch-archive.yaml",
            "workflows/qa-smoke-pack.yaml",
        ]

        for file in blockScalarFiles {
            let fullPath = Self.scenariosDir + "/" + file
            let info = IPhoneMirroirMCP.extractScenarioHeader(
                from: fullPath, source: "local")
            XCTAssertFalse(info.description.isEmpty,
                "\(file): block scalar description parsed as empty")
            XCTAssertFalse(info.description.contains("\n"),
                "\(file): description should be folded into single line")
        }
    }

    // MARK: - Env var pattern validation

    func testEnvVarPatternsAreWellFormed() throws {
        let envVarPattern = try NSRegularExpression(pattern: "\\$\\{([^}]+)\\}")
        let files = IPhoneMirroirMCP.findYAMLFiles(in: Self.scenariosDir)

        for file in files {
            let fullPath = Self.scenariosDir + "/" + file
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
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
                    "\(file): env var '\(varName)' contains invalid characters")
                XCTAssertTrue(varName == varName.uppercased(),
                    "\(file): env var '\(varName)' should be UPPER_SNAKE_CASE")
            }
        }
    }

    func testEnvVarSubstitutionOnRealContent() throws {
        let content = try String(contentsOfFile:
            Self.scenariosDir + "/apps/slack/send-message.yaml", encoding: .utf8)

        // Set env vars and verify substitution
        setenv("RECIPIENT", "Alice", 1)
        setenv("MESSAGE", "Hi there!", 1)
        defer {
            unsetenv("RECIPIENT")
            unsetenv("MESSAGE")
        }

        let substituted = IPhoneMirroirMCP.substituteEnvVars(in: content)
        XCTAssertTrue(substituted.contains("Alice"),
            "RECIPIENT not substituted")
        XCTAssertTrue(substituted.contains("Hi there!"),
            "MESSAGE not substituted")
        XCTAssertFalse(substituted.contains("${RECIPIENT}"),
            "RECIPIENT placeholder still present after substitution")
    }

    func testEnvVarDefaultsApplied() throws {
        let content = try String(contentsOfFile:
            Self.scenariosDir + "/apps/clock/set-alarm.yaml", encoding: .utf8)

        // Do NOT set ALARM_LABEL — should fall back to default
        unsetenv("ALARM_LABEL")

        let substituted = IPhoneMirroirMCP.substituteEnvVars(in: content)
        XCTAssertTrue(substituted.contains("Wake Up"),
            "Default 'Wake Up' not applied when ALARM_LABEL is unset")
    }

    // MARK: - Helpers

    private func parseScenario(_ relativePath: String) throws -> ScenarioDefinition {
        let fullPath = Self.scenariosDir + "/" + relativePath
        let content = try String(contentsOfFile: fullPath, encoding: .utf8)
        return ScenarioParser.parse(content: content, filePath: fullPath)
    }

    /// Map a ScenarioStep to its string kind for easy comparison.
    private func stepKind(_ step: ScenarioStep) -> String {
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
        _ scenario: ScenarioDefinition, _ kind: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let found = scenario.steps.contains { stepKind($0) == kind }
        XCTAssertTrue(found,
            "'\(scenario.name)' missing expected step type '\(kind)'",
            file: file, line: line)
    }

    private func assertStepKinds(
        _ steps: [ScenarioStep], _ expected: [String],
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
