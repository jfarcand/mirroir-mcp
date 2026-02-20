// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the PermissionPolicy permission engine.
// ABOUTME: Covers tool classification, fail-closed defaults, allow/deny lists, CLI parsing, and config decoding.

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

    @Test("all 28 tools are classified")
    func allToolsClassified() {
        let total = PermissionPolicy.readonlyTools.count + PermissionPolicy.mutatingTools.count
        #expect(total == 28, "Expected 28 tools, got \(total)")
    }

    @Test("readonly tools contains expected tools")
    func readonlyContents() {
        let expected: Set<String> = [
            "screenshot", "describe_screen", "start_recording",
            "stop_recording", "get_orientation", "status",
            "check_health", "list_targets", "list_scenarios",
            "get_scenario",
        ]
        #expect(PermissionPolicy.readonlyTools == expected)
    }

    @Test("mutating tools contains expected tools")
    func mutatingContents() {
        let expected: Set<String> = [
            "tap", "swipe", "drag", "type_text", "press_key",
            "long_press", "double_tap", "shake", "launch_app",
            "open_url", "press_home", "press_app_switcher", "spotlight",
            "scroll_to", "reset_app", "measure", "set_network",
            "switch_target",
        ]
        #expect(PermissionPolicy.mutatingTools == expected)
    }
}

// MARK: - Scenario Tool Classification

@Suite("PermissionPolicy - Scenario Tools")
struct PermissionScenarioTests {

    @Test("list_scenarios is readonly")
    func listScenariosReadonly() {
        #expect(PermissionPolicy.readonlyTools.contains("list_scenarios"))
        #expect(!PermissionPolicy.mutatingTools.contains("list_scenarios"))
    }

    @Test("get_scenario is readonly")
    func getScenarioReadonly() {
        #expect(PermissionPolicy.readonlyTools.contains("get_scenario"))
        #expect(!PermissionPolicy.mutatingTools.contains("get_scenario"))
    }

    @Test("scenario tools are always allowed without config")
    func scenarioToolsAlwaysAllowed() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        #expect(policy.checkTool("list_scenarios") == .allowed)
        #expect(policy.checkTool("get_scenario") == .allowed)
    }

    @Test("scenario tools are always visible")
    func scenarioToolsAlwaysVisible() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        #expect(policy.isToolVisible("list_scenarios") == true)
        #expect(policy.isToolVisible("get_scenario") == true)
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

// MARK: - App Blocklist

@Suite("PermissionPolicy - App Blocklist")
struct PermissionAppBlockTests {

    @Test("blocked app is denied")
    func blockedAppDenied() {
        let config = PermissionConfig(blockedApps: ["Wallet", "Health"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        if case .denied(let reason) = policy.checkAppLaunch("Wallet") {
            #expect(reason.contains("Wallet"))
        } else {
            Issue.record("Wallet should be blocked")
        }
    }

    @Test("non-blocked app is allowed")
    func nonBlockedAppAllowed() {
        let config = PermissionConfig(blockedApps: ["Wallet"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        #expect(policy.checkAppLaunch("Safari") == .allowed)
    }

    @Test("no blocklist means all apps allowed")
    func noBlocklistAllowsAll() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        #expect(policy.checkAppLaunch("Wallet") == .allowed)
    }
}

// MARK: - Error Messages

@Suite("PermissionPolicy - Error Messages")
struct PermissionErrorMessageTests {

    @Test("denied message includes tool name and remediation")
    func deniedMessageContent() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)

        if case .denied(let reason) = policy.checkTool("tap") {
            #expect(reason.contains("tap"))
            #expect(reason.contains("--dangerously-skip-permissions") || reason.contains(PermissionPolicy.configPath))
        } else {
            Issue.record("tap should be denied")
        }
    }

    @Test("deny list message mentions deny list")
    func denyListMessage() {
        let config = PermissionConfig(allow: ["tap"], deny: ["tap"])
        let policy = PermissionPolicy(skipPermissions: false, config: config)

        if case .denied(let reason) = policy.checkTool("tap") {
            #expect(reason.contains("deny list"))
        } else {
            Issue.record("tap should be denied by deny list")
        }
    }
}

// MARK: - CLI Parsing

@Suite("PermissionPolicy - CLI Parsing")
struct PermissionCLITests {

    @Test("--dangerously-skip-permissions returns true")
    func longFlagParsed() {
        #expect(PermissionPolicy.parseSkipPermissions(from: ["binary", "--dangerously-skip-permissions"]) == true)
    }

    @Test("--yolo returns true")
    func yoloFlagParsed() {
        #expect(PermissionPolicy.parseSkipPermissions(from: ["binary", "--yolo"]) == true)
    }

    @Test("no flags returns false")
    func noFlagsReturnsFalse() {
        #expect(PermissionPolicy.parseSkipPermissions(from: ["binary"]) == false)
    }

    @Test("unrelated flags return false")
    func unrelatedFlags() {
        #expect(PermissionPolicy.parseSkipPermissions(from: ["binary", "--verbose", "--port", "8080"]) == false)
    }
}

// MARK: - Config Decoding

@Suite("PermissionPolicy - Config Decoding")
struct PermissionConfigTests {

    private let decoder = JSONDecoder()

    @Test("full config decodes correctly")
    func fullConfig() throws {
        let json = """
        {
            "allow": ["tap", "swipe"],
            "deny": ["shake"],
            "blockedApps": ["Wallet"]
        }
        """
        let config = try decoder.decode(PermissionConfig.self, from: Data(json.utf8))
        #expect(config.allow == ["tap", "swipe"])
        #expect(config.deny == ["shake"])
        #expect(config.blockedApps == ["Wallet"])
    }

    @Test("empty object decodes to nil fields")
    func emptyConfig() throws {
        let json = "{}"
        let config = try decoder.decode(PermissionConfig.self, from: Data(json.utf8))
        #expect(config.allow == nil)
        #expect(config.deny == nil)
        #expect(config.blockedApps == nil)
    }

    @Test("partial config with only allow")
    func partialConfig() throws {
        let json = """
        {"allow": ["tap"]}
        """
        let config = try decoder.decode(PermissionConfig.self, from: Data(json.utf8))
        #expect(config.allow == ["tap"])
        #expect(config.deny == nil)
        #expect(config.blockedApps == nil)
    }

    @Test("unknown keys are silently ignored")
    func unknownKeys() throws {
        let json = """
        {"allow": ["tap"], "futureField": true, "nested": {"key": "value"}}
        """
        let config = try decoder.decode(PermissionConfig.self, from: Data(json.utf8))
        #expect(config.allow == ["tap"])
    }

    @Test("config roundtrips through encode/decode")
    func roundtrip() throws {
        let original = PermissionConfig(
            allow: ["tap", "swipe"],
            deny: ["shake"],
            blockedApps: ["Wallet"]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PermissionConfig.self, from: data)
        #expect(decoded.allow == original.allow)
        #expect(decoded.deny == original.deny)
        #expect(decoded.blockedApps == original.blockedApps)
    }
}
