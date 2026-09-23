// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for SkillParser step variants: scroll_to, reset_app, set_network, measure, targets.
// ABOUTME: Covers press_key modifiers, wait_for timeouts, long_press, and drag syntax.

import XCTest
import HelperLib
@testable import mirroir_mcp

extension SkillParserTests {

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
        let steps = SkillParser.parseSteps(from: "steps:\n  - target: { kind: ios, app: \"Clock\" }")
        guard steps.count == 1, case .switchTarget(let selector) = steps[0] else {
            return XCTFail("Expected one .switchTarget, got \(steps)")
        }
        XCTAssertEqual(selector, .ios(app: "Clock"))
    }

    func testParseMacosTargetStep() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - target: { kind: macos, name: \"android\" }")
        guard steps.count == 1, case .switchTarget(let selector) = steps[0] else {
            return XCTFail("Expected one .switchTarget, got \(steps)")
        }
        XCTAssertEqual(selector, .macos(name: "android"))
    }

    /// The bare-name form is gone: it is refused with the map that replaces
    /// it, not silently read as a target called "android".
    func testBareTargetNameIsInvalid() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - target: \"android\"")
        guard case .invalid(let type, let reason) = steps.first else {
            return XCTFail("Expected .invalid, got \(steps)")
        }
        XCTAssertEqual(type, "target")
        XCTAssertTrue(reason.contains("{ kind: ios }"))
    }

    /// An unknown verb used to parse as `.skipped` and let the skill pass
    /// around it; it is now `.invalid`, which refuses the run.
    func testUnknownVerbIsInvalid() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - double_tap: \"A\"\n  - frobnicate")
        let invalid = steps.compactMap { step -> String? in
            guard case .invalid(let type, let reason) = step else { return nil }
            return "\(type): \(reason)"
        }
        XCTAssertEqual(invalid, ["double_tap: unknown step type", "frobnicate: unknown step type"])
    }

    /// AI-only verbs are still skipped, not invalid: a SKILL flow may carry them.
    func testAIOnlyVerbStaysSkipped() {
        let steps = SkillParser.parseSteps(from: "steps:\n  - remember: \"x\"")
        guard case .skipped = steps.first else {
            return XCTFail("Expected .skipped, got \(steps)")
        }
    }

    func testParseTargetsHeader() {
        let yaml = """
        name: Multi-target test
        targets:
          - iphone
          - android
        steps:
          - target: { kind: ios }
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
        let step = SkillStep.switchTarget(.macos(name: "android"))
        XCTAssertEqual(step.typeKey, "target")
    }

    func testSwitchTargetDisplayName() {
        XCTAssertEqual(SkillStep.switchTarget(.macos(name: "android")).displayName,
                       "target: { kind: macos, name: \"android\" }")
        XCTAssertEqual(SkillStep.switchTarget(.ios(app: "Clock")).displayName,
                       "target: { kind: ios, app: \"Clock\" }")
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

    // MARK: - long_press

    func testParseLongPressSimple() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - long_press: \"Photo\"")
        XCTAssertEqual(steps.count, 1)
        if case .longPress(let label, let duration) = steps[0] {
            XCTAssertEqual(label, "Photo")
            XCTAssertNil(duration)
        } else {
            XCTFail("Expected .longPress, got \(steps[0])")
        }
    }

    func testParseLongPressWithDuration() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - long_press: \"Photo\" duration: 2000")
        XCTAssertEqual(steps.count, 1)
        if case .longPress(let label, let duration) = steps[0] {
            XCTAssertEqual(label, "Photo")
            XCTAssertEqual(duration, 2000)
        } else {
            XCTFail("Expected .longPress with duration, got \(steps[0])")
        }
    }

    func testDisplayNameLongPress() {
        let step = SkillStep.longPress(label: "Photo", durationMs: 1000)
        XCTAssertEqual(step.displayName, "long_press: \"Photo\"")
        XCTAssertEqual(step.typeKey, "long_press")
        XCTAssertEqual(step.labelValue, "Photo")
    }

    // MARK: - drag

    func testParseDragStep() {
        let steps = SkillParser.parseSteps(
            from: "steps:\n  - drag: { from: \"Source\", to: \"Target\" }")
        XCTAssertEqual(steps.count, 1)
        if case .drag(let fromLabel, let toLabel) = steps[0] {
            XCTAssertEqual(fromLabel, "Source")
            XCTAssertEqual(toLabel, "Target")
        } else {
            XCTFail("Expected .drag, got \(steps[0])")
        }
    }

    func testDisplayNameDrag() {
        let step = SkillStep.drag(fromLabel: "A", toLabel: "B")
        XCTAssertEqual(step.displayName, "drag: \"A\" -> \"B\"")
        XCTAssertEqual(step.typeKey, "drag")
        XCTAssertEqual(step.labelValue, "A")
    }
}
