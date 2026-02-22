// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for SkillParser: YAML parsing, step type extraction, env var substitution.
// ABOUTME: Covers all step types, malformed input, AI-only steps, and edge cases.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SkillParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseSimpleSkill() {
        let yaml = """
        name: Check About
        description: Navigate to About screen
        steps:
          - launch: "Settings"
          - tap: "General"
          - assert_visible: "Model Name"
        """
        let skill = SkillParser.parse(content: yaml, filePath: "check-about.yaml")
        XCTAssertEqual(skill.name, "Check About")
        XCTAssertEqual(skill.description, "Navigate to About screen")
        XCTAssertEqual(skill.steps.count, 3)
    }

    func testParseExtractsFilePath() {
        let yaml = "name: Test\nsteps:\n  - home"
        let skill = SkillParser.parse(content: yaml, filePath: "/path/to/test.yaml")
        XCTAssertEqual(skill.filePath, "/path/to/test.yaml")
    }

    func testParseFallbackName() {
        let yaml = "steps:\n  - home"
        let skill = SkillParser.parse(content: yaml, filePath: "my-skill.yaml")
        XCTAssertEqual(skill.name, "my-skill")
    }

    func testParseEmptyContent() {
        let skill = SkillParser.parse(content: "", filePath: "empty.yaml")
        XCTAssertEqual(skill.steps.count, 0)
        XCTAssertEqual(skill.name, "empty")
    }

    func testParseNoStepsSection() {
        let yaml = "name: No Steps\ndescription: Missing steps block"
        let skill = SkillParser.parse(content: yaml)
        XCTAssertEqual(skill.steps.count, 0)
    }

    // MARK: - Step Type Parsing

    func testParseLaunchStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - launch: \"Settings\"")
        XCTAssertEqual(steps.count, 1)
        if case .launch(let appName) = steps[0] {
            XCTAssertEqual(appName, "Settings")
        } else {
            XCTFail("Expected launch step")
        }
    }

    func testParseTapStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - tap: \"General\"")
        XCTAssertEqual(steps.count, 1)
        if case .tap(let label) = steps[0] {
            XCTAssertEqual(label, "General")
        } else {
            XCTFail("Expected tap step")
        }
    }

    func testParseTypeStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - type: \"Hello World\"")
        XCTAssertEqual(steps.count, 1)
        if case .type(let text) = steps[0] {
            XCTAssertEqual(text, "Hello World")
        } else {
            XCTFail("Expected type step")
        }
    }

    func testParsePressKeyStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - press_key: \"return\"")
        XCTAssertEqual(steps.count, 1)
        if case .pressKey(let keyName, let modifiers) = steps[0] {
            XCTAssertEqual(keyName, "return")
            XCTAssertTrue(modifiers.isEmpty)
        } else {
            XCTFail("Expected press_key step")
        }
    }

    func testParsePressKeyWithModifiers() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - press_key: \"l+command\"")
        XCTAssertEqual(steps.count, 1)
        if case .pressKey(let keyName, let modifiers) = steps[0] {
            XCTAssertEqual(keyName, "l")
            XCTAssertEqual(modifiers, ["command"])
        } else {
            XCTFail("Expected press_key step with modifiers")
        }
    }

    func testParseSwipeStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - swipe: \"up\"")
        XCTAssertEqual(steps.count, 1)
        if case .swipe(let direction) = steps[0] {
            XCTAssertEqual(direction, "up")
        } else {
            XCTFail("Expected swipe step")
        }
    }

    func testParseWaitForStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - wait_for: \"General\"")
        XCTAssertEqual(steps.count, 1)
        if case .waitFor(let label, _) = steps[0] {
            XCTAssertEqual(label, "General")
        } else {
            XCTFail("Expected wait_for step")
        }
    }

    func testParseAssertVisibleStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - assert_visible: \"Model Name\"")
        XCTAssertEqual(steps.count, 1)
        if case .assertVisible(let label) = steps[0] {
            XCTAssertEqual(label, "Model Name")
        } else {
            XCTFail("Expected assert_visible step")
        }
    }

    func testParseAssertNotVisibleStep() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - assert_not_visible: \"Error\"")
        XCTAssertEqual(steps.count, 1)
        if case .assertNotVisible(let label) = steps[0] {
            XCTAssertEqual(label, "Error")
        } else {
            XCTFail("Expected assert_not_visible step")
        }
    }

    func testParseScreenshotStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - screenshot: \"result\"")
        XCTAssertEqual(steps.count, 1)
        if case .screenshot(let label) = steps[0] {
            XCTAssertEqual(label, "result")
        } else {
            XCTFail("Expected screenshot step")
        }
    }

    func testParseHomeStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - home")
        XCTAssertEqual(steps.count, 1)
        if case .home = steps[0] {
            // pass
        } else {
            XCTFail("Expected home step")
        }
    }

    func testParsePressHomeStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - press_home")
        XCTAssertEqual(steps.count, 1)
        if case .home = steps[0] {
            // pass
        } else {
            XCTFail("Expected home step from press_home")
        }
    }

    func testParseOpenURLStep() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - open_url: \"https://example.com\"")
        XCTAssertEqual(steps.count, 1)
        if case .openURL(let url) = steps[0] {
            XCTAssertEqual(url, "https://example.com")
        } else {
            XCTFail("Expected open_url step")
        }
    }

    func testParseShakeStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - shake")
        XCTAssertEqual(steps.count, 1)
        if case .shake = steps[0] {
            // pass
        } else {
            XCTFail("Expected shake step")
        }
    }

    // MARK: - AI-Only Steps

    func testParseRememberStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - remember: \"user name\"")
        XCTAssertEqual(steps.count, 1)
        if case .skipped(let stepType, _) = steps[0] {
            XCTAssertEqual(stepType, "remember")
        } else {
            XCTFail("Expected skipped step for remember")
        }
    }

    func testParseConditionStep() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - condition: \"if logged in\"")
        XCTAssertEqual(steps.count, 1)
        if case .skipped(let stepType, _) = steps[0] {
            XCTAssertEqual(stepType, "condition")
        } else {
            XCTFail("Expected skipped step for condition")
        }
    }

    func testParseUnknownStep() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - custom_action: \"something\"")
        XCTAssertEqual(steps.count, 1)
        if case .skipped(let stepType, _) = steps[0] {
            XCTAssertEqual(stepType, "custom_action")
        } else {
            XCTFail("Expected skipped step for unknown type")
        }
    }

    // MARK: - Multi-Step Skills

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
        let skill = SkillParser.parse(content: yaml)
        XCTAssertEqual(skill.steps.count, 7)
    }

    // MARK: - Quote Handling

    func testStripDoubleQuotes() {
        XCTAssertEqual(SkillParser.stripQuotes("\"hello\""), "hello")
    }

    func testStripSingleQuotes() {
        XCTAssertEqual(SkillParser.stripQuotes("'hello'"), "hello")
    }

    func testNoQuotesToStrip() {
        XCTAssertEqual(SkillParser.stripQuotes("hello"), "hello")
    }

    func testMismatchedQuotesNotStripped() {
        XCTAssertEqual(SkillParser.stripQuotes("\"hello'"), "\"hello'")
    }

    // MARK: - Unquoted Values

    func testParseUnquotedValues() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - tap: General")
        XCTAssertEqual(steps.count, 1)
        if case .tap(let label) = steps[0] {
            XCTAssertEqual(label, "General")
        } else {
            XCTFail("Expected tap step")
        }
    }

    // MARK: - DisplayName

    func testDisplayNameLaunch() {
        let step = SkillStep.launch(appName: "Settings")
        XCTAssertEqual(step.displayName, "launch: \"Settings\"")
    }

    func testDisplayNameSkipped() {
        let step = SkillStep.skipped(stepType: "remember", reason: "AI-only")
        XCTAssertEqual(step.displayName, "remember (skipped)")
    }

    func testDisplayNamePressKeyWithModifiers() {
        let step = SkillStep.pressKey(keyName: "l", modifiers: ["command"])
        XCTAssertEqual(step.displayName, "press_key: \"l\" [command]")
    }

    // MARK: - scroll_to

    func testParseScrollToStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - scroll_to: \"About\"")
        XCTAssertEqual(steps.count, 1)
        if case .scrollTo(let label, let direction, let maxScrolls) = steps[0] {
            XCTAssertEqual(label, "About")
            XCTAssertEqual(direction, "up")
            XCTAssertEqual(maxScrolls, 10)
        } else {
            XCTFail("Expected scroll_to step")
        }
    }

    func testDisplayNameScrollTo() {
        let step = SkillStep.scrollTo(label: "About", direction: "up", maxScrolls: 10)
        XCTAssertEqual(step.displayName, "scroll_to: \"About\"")
    }

    // MARK: - reset_app

    func testParseResetAppStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - reset_app: \"Settings\"")
        XCTAssertEqual(steps.count, 1)
        if case .resetApp(let appName) = steps[0] {
            XCTAssertEqual(appName, "Settings")
        } else {
            XCTFail("Expected reset_app step")
        }
    }

    func testDisplayNameResetApp() {
        let step = SkillStep.resetApp(appName: "Settings")
        XCTAssertEqual(step.displayName, "reset_app: \"Settings\"")
    }

    // MARK: - set_network

    func testParseSetNetworkStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - set_network: \"airplane_on\"")
        XCTAssertEqual(steps.count, 1)
        if case .setNetwork(let mode) = steps[0] {
            XCTAssertEqual(mode, "airplane_on")
        } else {
            XCTFail("Expected set_network step")
        }
    }

    func testDisplayNameSetNetwork() {
        let step = SkillStep.setNetwork(mode: "wifi_off")
        XCTAssertEqual(step.displayName, "set_network: \"wifi_off\"")
    }

    // MARK: - measure

    func testParseMeasureInlineStep() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - measure: { tap: \"Login\", until: \"Dashboard\", max: 5, name: \"login_time\" }")
        XCTAssertEqual(steps.count, 1)
        if case .measure(let name, let action, let until, let maxSeconds) = steps[0] {
            XCTAssertEqual(name, "login_time")
            XCTAssertEqual(until, "Dashboard")
            XCTAssertEqual(maxSeconds, 5.0)
            if case .tap(let label) = action {
                XCTAssertEqual(label, "Login")
            } else {
                XCTFail("Expected tap action inside measure")
            }
        } else {
            XCTFail("Expected measure step")
        }
    }

    func testParseMeasureWithoutName() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - measure: { tap: \"Go\", until: \"Done\" }")
        XCTAssertEqual(steps.count, 1)
        if case .measure(let name, _, let until, let maxSeconds) = steps[0] {
            XCTAssertEqual(name, "measure")
            XCTAssertEqual(until, "Done")
            XCTAssertNil(maxSeconds)
        } else {
            XCTFail("Expected measure step")
        }
    }

    func testDisplayNameMeasure() {
        let step = SkillStep.measure(
            name: "login", action: .tap(label: "Go"),
            until: "Done", maxSeconds: 5.0)
        XCTAssertEqual(step.displayName, "measure: \"login\"")
    }

    // MARK: - Skill with new step types

    func testParseSkillWithNewSteps() {
        let yaml = """
        name: Full Flow
        steps:
          - reset_app: "Settings"
          - launch: "Settings"
          - scroll_to: "About"
          - set_network: "wifi_off"
          - measure: { tap: "General", until: "About", max: 3 }
        """
        let skill = SkillParser.parse(content: yaml)
        XCTAssertEqual(skill.steps.count, 5)
    }

    // MARK: - Target Switching

    func testParseSwitchTargetStep() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - target: \"android\"")
        XCTAssertEqual(steps.count, 1)
        if case .switchTarget(let name) = steps[0] {
            XCTAssertEqual(name, "android")
        } else {
            XCTFail("Expected .switchTarget, got \(steps[0])")
        }
    }

    func testParseTargetsHeader() {
        let yaml = """
        name: Multi-target test
        targets:
          - iphone
          - android
        steps:
          - target: "iphone"
          - tap: "Settings"
        """
        let skill = SkillParser.parse(content: yaml)
        XCTAssertEqual(skill.targets, ["iphone", "android"])
    }

    func testParseNoTargetsHeaderReturnsEmpty() {
        let yaml = "name: Single\nsteps:\n  - home"
        let skill = SkillParser.parse(content: yaml)
        XCTAssertTrue(skill.targets.isEmpty)
    }

    func testSwitchTargetTypeKey() {
        let step = SkillStep.switchTarget(name: "android")
        XCTAssertEqual(step.typeKey, "target")
    }

    func testSwitchTargetDisplayName() {
        let step = SkillStep.switchTarget(name: "android")
        XCTAssertEqual(step.displayName, "target: \"android\"")
    }

    // MARK: - press_key dict modifiers syntax

    func testParsePressKeyWithDictModifiers() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - press_key: \"l\" modifiers: [\"command\"]")
        XCTAssertEqual(steps.count, 1)
        if case .pressKey(let keyName, let modifiers) = steps[0] {
            XCTAssertEqual(keyName, "l")
            XCTAssertEqual(modifiers, ["command"])
        } else {
            XCTFail("Expected press_key step with dict modifiers")
        }
    }

    func testParsePressKeyWithMultipleDictModifiers() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - press_key: \"l\" modifiers: [\"command\", \"shift\"]")
        XCTAssertEqual(steps.count, 1)
        if case .pressKey(let keyName, let modifiers) = steps[0] {
            XCTAssertEqual(keyName, "l")
            XCTAssertEqual(modifiers, ["command", "shift"])
        } else {
            XCTFail("Expected press_key step with multiple dict modifiers")
        }
    }

    // MARK: - wait_for timeout syntax

    func testParseWaitForWithTimeout() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - wait_for: \"General\" timeout: 30")
        XCTAssertEqual(steps.count, 1)
        if case .waitFor(let label, let timeout) = steps[0] {
            XCTAssertEqual(label, "General")
            XCTAssertEqual(timeout, 30)
        } else {
            XCTFail("Expected wait_for step with timeout")
        }
    }

    func testParseWaitForWithoutTimeout() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - wait_for: \"General\"")
        XCTAssertEqual(steps.count, 1)
        if case .waitFor(let label, let timeout) = steps[0] {
            XCTAssertEqual(label, "General")
            XCTAssertNil(timeout)
        } else {
            XCTFail("Expected wait_for step without timeout")
        }
    }
}
