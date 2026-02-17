// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ScenarioParser: YAML parsing, step type extraction, env var substitution.
// ABOUTME: Covers all step types, malformed input, AI-only steps, and edge cases.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class ScenarioParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseSimpleScenario() {
        let yaml = """
        name: Check About
        description: Navigate to About screen
        steps:
          - launch: "Settings"
          - tap: "General"
          - assert_visible: "Model Name"
        """
        let scenario = ScenarioParser.parse(content: yaml, filePath: "check-about.yaml")
        XCTAssertEqual(scenario.name, "Check About")
        XCTAssertEqual(scenario.description, "Navigate to About screen")
        XCTAssertEqual(scenario.steps.count, 3)
    }

    func testParseExtractsFilePath() {
        let yaml = "name: Test\nsteps:\n  - home"
        let scenario = ScenarioParser.parse(content: yaml, filePath: "/path/to/test.yaml")
        XCTAssertEqual(scenario.filePath, "/path/to/test.yaml")
    }

    func testParseFallbackName() {
        let yaml = "steps:\n  - home"
        let scenario = ScenarioParser.parse(content: yaml, filePath: "my-scenario.yaml")
        XCTAssertEqual(scenario.name, "my-scenario")
    }

    func testParseEmptyContent() {
        let scenario = ScenarioParser.parse(content: "", filePath: "empty.yaml")
        XCTAssertEqual(scenario.steps.count, 0)
        XCTAssertEqual(scenario.name, "empty")
    }

    func testParseNoStepsSection() {
        let yaml = "name: No Steps\ndescription: Missing steps block"
        let scenario = ScenarioParser.parse(content: yaml)
        XCTAssertEqual(scenario.steps.count, 0)
    }

    // MARK: - Step Type Parsing

    func testParseLaunchStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - launch: \"Settings\"")
        XCTAssertEqual(steps.count, 1)
        if case .launch(let appName) = steps[0] {
            XCTAssertEqual(appName, "Settings")
        } else {
            XCTFail("Expected launch step")
        }
    }

    func testParseTapStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - tap: \"General\"")
        XCTAssertEqual(steps.count, 1)
        if case .tap(let label) = steps[0] {
            XCTAssertEqual(label, "General")
        } else {
            XCTFail("Expected tap step")
        }
    }

    func testParseTypeStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - type: \"Hello World\"")
        XCTAssertEqual(steps.count, 1)
        if case .type(let text) = steps[0] {
            XCTAssertEqual(text, "Hello World")
        } else {
            XCTFail("Expected type step")
        }
    }

    func testParsePressKeyStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - press_key: \"return\"")
        XCTAssertEqual(steps.count, 1)
        if case .pressKey(let keyName, let modifiers) = steps[0] {
            XCTAssertEqual(keyName, "return")
            XCTAssertTrue(modifiers.isEmpty)
        } else {
            XCTFail("Expected press_key step")
        }
    }

    func testParsePressKeyWithModifiers() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - press_key: \"l+command\"")
        XCTAssertEqual(steps.count, 1)
        if case .pressKey(let keyName, let modifiers) = steps[0] {
            XCTAssertEqual(keyName, "l")
            XCTAssertEqual(modifiers, ["command"])
        } else {
            XCTFail("Expected press_key step with modifiers")
        }
    }

    func testParseSwipeStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - swipe: \"up\"")
        XCTAssertEqual(steps.count, 1)
        if case .swipe(let direction) = steps[0] {
            XCTAssertEqual(direction, "up")
        } else {
            XCTFail("Expected swipe step")
        }
    }

    func testParseWaitForStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - wait_for: \"General\"")
        XCTAssertEqual(steps.count, 1)
        if case .waitFor(let label, _) = steps[0] {
            XCTAssertEqual(label, "General")
        } else {
            XCTFail("Expected wait_for step")
        }
    }

    func testParseAssertVisibleStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - assert_visible: \"Model Name\"")
        XCTAssertEqual(steps.count, 1)
        if case .assertVisible(let label) = steps[0] {
            XCTAssertEqual(label, "Model Name")
        } else {
            XCTFail("Expected assert_visible step")
        }
    }

    func testParseAssertNotVisibleStep() {
        let steps = ScenarioParser.parseSteps(
            from: "steps:\n  - assert_not_visible: \"Error\"")
        XCTAssertEqual(steps.count, 1)
        if case .assertNotVisible(let label) = steps[0] {
            XCTAssertEqual(label, "Error")
        } else {
            XCTFail("Expected assert_not_visible step")
        }
    }

    func testParseScreenshotStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - screenshot: \"result\"")
        XCTAssertEqual(steps.count, 1)
        if case .screenshot(let label) = steps[0] {
            XCTAssertEqual(label, "result")
        } else {
            XCTFail("Expected screenshot step")
        }
    }

    func testParseHomeStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - home")
        XCTAssertEqual(steps.count, 1)
        if case .home = steps[0] {
            // pass
        } else {
            XCTFail("Expected home step")
        }
    }

    func testParsePressHomeStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - press_home")
        XCTAssertEqual(steps.count, 1)
        if case .home = steps[0] {
            // pass
        } else {
            XCTFail("Expected home step from press_home")
        }
    }

    func testParseOpenURLStep() {
        let steps = ScenarioParser.parseSteps(
            from: "steps:\n  - open_url: \"https://example.com\"")
        XCTAssertEqual(steps.count, 1)
        if case .openURL(let url) = steps[0] {
            XCTAssertEqual(url, "https://example.com")
        } else {
            XCTFail("Expected open_url step")
        }
    }

    func testParseShakeStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - shake")
        XCTAssertEqual(steps.count, 1)
        if case .shake = steps[0] {
            // pass
        } else {
            XCTFail("Expected shake step")
        }
    }

    // MARK: - AI-Only Steps

    func testParseRememberStep() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - remember: \"user name\"")
        XCTAssertEqual(steps.count, 1)
        if case .skipped(let stepType, _) = steps[0] {
            XCTAssertEqual(stepType, "remember")
        } else {
            XCTFail("Expected skipped step for remember")
        }
    }

    func testParseConditionStep() {
        let steps = ScenarioParser.parseSteps(
            from: "steps:\n  - condition: \"if logged in\"")
        XCTAssertEqual(steps.count, 1)
        if case .skipped(let stepType, _) = steps[0] {
            XCTAssertEqual(stepType, "condition")
        } else {
            XCTFail("Expected skipped step for condition")
        }
    }

    func testParseUnknownStep() {
        let steps = ScenarioParser.parseSteps(
            from: "steps:\n  - custom_action: \"something\"")
        XCTAssertEqual(steps.count, 1)
        if case .skipped(let stepType, _) = steps[0] {
            XCTAssertEqual(stepType, "custom_action")
        } else {
            XCTFail("Expected skipped step for unknown type")
        }
    }

    // MARK: - Multi-Step Scenarios

    func testParseMultipleSteps() {
        let yaml = """
        name: Full Flow
        steps:
          - launch: "Settings"
          - wait_for: "General"
          - tap: "General"
          - wait_for: "About"
          - tap: "About"
          - assert_visible: "Model Name"
          - screenshot: "about_screen"
        """
        let scenario = ScenarioParser.parse(content: yaml)
        XCTAssertEqual(scenario.steps.count, 7)
    }

    // MARK: - Quote Handling

    func testStripDoubleQuotes() {
        XCTAssertEqual(ScenarioParser.stripQuotes("\"hello\""), "hello")
    }

    func testStripSingleQuotes() {
        XCTAssertEqual(ScenarioParser.stripQuotes("'hello'"), "hello")
    }

    func testNoQuotesToStrip() {
        XCTAssertEqual(ScenarioParser.stripQuotes("hello"), "hello")
    }

    func testMismatchedQuotesNotStripped() {
        XCTAssertEqual(ScenarioParser.stripQuotes("\"hello'"), "\"hello'")
    }

    // MARK: - Unquoted Values

    func testParseUnquotedValues() {
        let steps = ScenarioParser.parseSteps(from: "steps:\n  - tap: General")
        XCTAssertEqual(steps.count, 1)
        if case .tap(let label) = steps[0] {
            XCTAssertEqual(label, "General")
        } else {
            XCTFail("Expected tap step")
        }
    }

    // MARK: - DisplayName

    func testDisplayNameLaunch() {
        let step = ScenarioStep.launch(appName: "Settings")
        XCTAssertEqual(step.displayName, "launch: \"Settings\"")
    }

    func testDisplayNameSkipped() {
        let step = ScenarioStep.skipped(stepType: "remember", reason: "AI-only")
        XCTAssertEqual(step.displayName, "remember (skipped)")
    }

    func testDisplayNamePressKeyWithModifiers() {
        let step = ScenarioStep.pressKey(keyName: "l", modifiers: ["command"])
        XCTAssertEqual(step.displayName, "press_key: \"l\" [command]")
    }
}
