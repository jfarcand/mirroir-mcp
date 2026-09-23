// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the PermissionPolicy permission engine.
// ABOUTME: Covers tool classification, fail-closed defaults, skip mode, allow/deny lists, and case sensitivity.

import Foundation
import Testing
@testable import HelperLib

// MARK: - Tool Classification

@Suite("PermissionPolicy - Classification")
struct PermissionClassificationTests {

    @Test("readonly and mutating sets are disjoint")
    func setsAreDisjoint() {
        let overlap = PermissionPolicy.readonlyTools.intersection(PermissionPolicy.mutatingTools)
        #expect(overlap.isEmpty, "Readonly and mutating sets must not overlap: \(overlap)")
    }

    @Test("all tools are classified")
    func allToolsClassified() {
        let total = PermissionPolicy.readonlyTools.count + PermissionPolicy.mutatingTools.count
        #expect(total == 38, "Expected 38 tools, got \(total)")
    }

    @Test("readonly tools contains expected tools")
    func readonlyContents() {
        let expected: Set<String> = [
            "screenshot", "describe_screen", "start_recording",
            "stop_recording", "get_orientation", "status",
            "check_health", "list_targets", "list_skills",
            "get_skill", "calibrate_component", "classify_screen",
        ]
        #expect(PermissionPolicy.readonlyTools == expected)
    }

    @Test("mutating tools contains expected tools")
    func mutatingContents() {
        let expected: Set<String> = [
            "tap", "swipe", "drag", "type_text", "press_key",
            "long_press", "double_tap", "touch", "pinch", "rotate", "hold_keys", "shake", "launch_app",
            "open_url", "press_home", "press_app_switcher", "press_back",
            "spotlight", "scroll_to", "reset_app", "measure", "set_network",
            "switch_target", "record_step", "save_compiled",
            "generate_skill",
        ]
        #expect(PermissionPolicy.mutatingTools == expected)
    }
}

// MARK: - Skill Tool Classification

@Suite("PermissionPolicy - Skill Tools")
struct PermissionSkillTests {

    @Test("list_skills is readonly")
    func listSkillsReadonly() {
        #expect(PermissionPolicy.readonlyTools.contains("list_skills"))
        #expect(!PermissionPolicy.mutatingTools.contains("list_skills"))
    }

    @Test("get_skill is readonly")
    func getSkillReadonly() {
        #expect(PermissionPolicy.readonlyTools.contains("get_skill"))
        #expect(!PermissionPolicy.mutatingTools.contains("get_skill"))
    }

    @Test("skill tools are always allowed without config")
    func skillToolsAlwaysAllowed() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        #expect(policy.checkTool("list_skills") == .allowed)
        #expect(policy.checkTool("get_skill") == .allowed)
    }

    @Test("skill tools are always visible")
    func skillToolsAlwaysVisible() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        #expect(policy.isToolVisible("list_skills") == true)
        #expect(policy.isToolVisible("get_skill") == true)
    }
}

// MARK: - Target Tool Classification

@Suite("PermissionPolicy - Target Tools")
struct PermissionTargetTests {

    @Test("list_targets is readonly")
    func listTargetsReadonly() {
        #expect(PermissionPolicy.readonlyTools.contains("list_targets"))
        #expect(!PermissionPolicy.mutatingTools.contains("list_targets"))
    }

    @Test("switch_target is mutating")
    func switchTargetMutating() {
        #expect(PermissionPolicy.mutatingTools.contains("switch_target"))
        #expect(!PermissionPolicy.readonlyTools.contains("switch_target"))
    }

    @Test("list_targets is always allowed without config")
    func listTargetsAlwaysAllowed() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        #expect(policy.checkTool("list_targets") == .allowed)
    }

    @Test("list_targets is always visible")
    func listTargetsAlwaysVisible() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        #expect(policy.isToolVisible("list_targets") == true)
    }

    @Test("switch_target is denied by default")
    func switchTargetDeniedByDefault() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        if case .denied = policy.checkTool("switch_target") {
            // expected
        } else {
            Issue.record("switch_target should be denied without config")
        }
    }

    @Test("switch_target is not visible by default")
    func switchTargetNotVisibleByDefault() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        #expect(policy.isToolVisible("switch_target") == false)
    }
}

// MARK: - Fail-Closed Defaults

@Suite("PermissionPolicy - Fail-Closed")
struct PermissionFailClosedTests {

    let policy = PermissionPolicy(skipPermissions: false, config: nil)

    @Test("readonly tools are always allowed")
    func readonlyAllowed() {
        for tool in PermissionPolicy.readonlyTools {
            #expect(policy.checkTool(tool) == .allowed, "\(tool) should be allowed")
        }
    }

    @Test("mutating tools are denied by default")
    func mutatingDenied() {
        for tool in PermissionPolicy.mutatingTools {
            if case .denied = policy.checkTool(tool) {
                // expected
            } else {
                Issue.record("\(tool) should be denied without config")
            }
        }
    }

    @Test("readonly tools are visible")
    func readonlyVisible() {
        for tool in PermissionPolicy.readonlyTools {
            #expect(policy.isToolVisible(tool) == true, "\(tool) should be visible")
        }
    }

    @Test("mutating tools are not visible")
    func mutatingNotVisible() {
        for tool in PermissionPolicy.mutatingTools {
            #expect(policy.isToolVisible(tool) == false, "\(tool) should not be visible")
        }
    }
}

// MARK: - Skip Permissions

@Suite("PermissionPolicy - Skip Permissions")
struct PermissionSkipTests {

    let policy = PermissionPolicy(skipPermissions: true, config: nil)

    @Test("all tools allowed when skip-permissions is on")
    func allToolsAllowed() {
        let allTools = PermissionPolicy.readonlyTools.union(PermissionPolicy.mutatingTools)
        for tool in allTools {
            #expect(policy.checkTool(tool) == .allowed, "\(tool) should be allowed with skip-permissions")
        }
    }

    @Test("all tools visible when skip-permissions is on")
    func allToolsVisible() {
        let allTools = PermissionPolicy.readonlyTools.union(PermissionPolicy.mutatingTools)
        for tool in allTools {
            #expect(policy.isToolVisible(tool) == true, "\(tool) should be visible with skip-permissions")
        }
    }
}

// MARK: - Allow List

@Suite("PermissionPolicy - Allow List")
struct PermissionAllowTests {

    @Test("tools in allow list are permitted")
    func allowedToolsPermitted() {
        let config = PermissionConfig(allow: ["tap", "swipe"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        #expect(policy.checkTool("tap") == .allowed)
        #expect(policy.checkTool("swipe") == .allowed)
    }

    @Test("tools not in allow list are denied")
    func unlistedToolsDenied() {
        let config = PermissionConfig(allow: ["tap"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        if case .denied = policy.checkTool("swipe") {
            // expected
        } else {
            Issue.record("swipe should be denied when not in allow list")
        }
    }

    @Test("readonly tools still allowed even when not in allow list")
    func readonlyAlwaysAllowed() {
        let config = PermissionConfig(allow: ["tap"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        #expect(policy.checkTool("screenshot") == .allowed)
        #expect(policy.checkTool("status") == .allowed)
    }

    @Test("wildcard allow permits all mutating tools")
    func wildcardAllowAll() {
        let config = PermissionConfig(allow: ["*"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        for tool in PermissionPolicy.mutatingTools {
            #expect(policy.checkTool(tool) == .allowed, "\(tool) should be allowed with wildcard")
        }
    }

    @Test("wildcard allow makes all tools visible")
    func wildcardAllVisible() {
        let config = PermissionConfig(allow: ["*"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        let allTools = PermissionPolicy.readonlyTools.union(PermissionPolicy.mutatingTools)
        for tool in allTools {
            #expect(policy.isToolVisible(tool) == true, "\(tool) should be visible with wildcard")
        }
    }

    @Test("wildcard allow still respects deny list")
    func wildcardWithDeny() {
        let config = PermissionConfig(allow: ["*"], deny: ["shake"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        #expect(policy.checkTool("tap") == .allowed)
        if case .denied = policy.checkTool("shake") {
            // expected: deny overrides wildcard
        } else {
            Issue.record("deny should override wildcard for shake")
        }
    }

    @Test("allowed mutating tools are visible")
    func allowedToolsVisible() {
        let config = PermissionConfig(allow: ["tap", "type_text"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        #expect(policy.isToolVisible("tap") == true)
        #expect(policy.isToolVisible("type_text") == true)
        #expect(policy.isToolVisible("swipe") == false)
    }
}

// MARK: - Deny List

@Suite("PermissionPolicy - Deny List")
struct PermissionDenyTests {

    @Test("tools in deny list are blocked")
    func denyBlocksTools() {
        let config = PermissionConfig(allow: ["tap", "shake"], deny: ["shake"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        if case .denied = policy.checkTool("shake") {
            // expected: deny overrides allow
        } else {
            Issue.record("shake should be denied when in deny list")
        }
    }

    @Test("deny overrides allow")
    func denyOverridesAllow() {
        let config = PermissionConfig(allow: ["tap", "swipe"], deny: ["tap"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        if case .denied = policy.checkTool("tap") {
            // expected
        } else {
            Issue.record("deny should override allow for tap")
        }
        #expect(policy.checkTool("swipe") == .allowed)
    }

    @Test("readonly tools cannot be denied")
    func readonlyCannotBeDenied() {
        let config = PermissionConfig(deny: ["screenshot", "status"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        #expect(policy.checkTool("screenshot") == .allowed)
        #expect(policy.checkTool("status") == .allowed)
    }
}

// MARK: - Case Sensitivity

@Suite("PermissionPolicy - Case Sensitivity")
struct PermissionCaseTests {

    @Test("allow list is case-insensitive")
    func allowCaseInsensitive() {
        let config = PermissionConfig(allow: ["TAP", "Swipe"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        #expect(policy.checkTool("tap") == .allowed)
        #expect(policy.checkTool("SWIPE") == .allowed)
        #expect(policy.checkTool("Tap") == .allowed)
    }

    @Test("deny list is case-insensitive")
    func denyCaseInsensitive() {
        let config = PermissionConfig(allow: ["tap"], deny: ["TAP"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        if case .denied = policy.checkTool("tap") {
            // expected
        } else {
            Issue.record("case-insensitive deny should block tap")
        }
    }

    @Test("app blocklist is case-insensitive")
    func appBlockCaseInsensitive() {
        let config = PermissionConfig(blockedApps: ["Wallet"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        if case .denied = policy.checkAppLaunch("wallet") {
            // expected
        } else {
            Issue.record("blockedApps should be case-insensitive")
        }

        if case .denied = policy.checkAppLaunch("WALLET") {
            // expected
        } else {
            Issue.record("blockedApps should be case-insensitive for WALLET")
        }
    }
}
