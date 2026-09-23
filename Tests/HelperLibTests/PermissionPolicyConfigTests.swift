// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for PermissionPolicy app blocking, error messages, CLI parsing, and config decoding.
// ABOUTME: Also covers per-app tool rules; classification and allow/deny lists live in PermissionPolicyTests.

import Foundation
import Testing
@testable import HelperLib

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

// MARK: - Per-App Tool Rules

@Suite("PermissionPolicy - per-app tool rules")
struct PerAppToolRulesTests {

    @Test("perApp deny overrides global allow")
    func perAppDenyWinsOverGlobalAllow() {
        let config = PermissionConfig(
            allow: ["*"],
            perApp: ["Banking": AppToolRules(deny: ["type_text"])]
        )
        let policy = PermissionPolicy(skipPermissions: false, config: config)
        #expect(policy.checkTool("type_text") == .allowed)
        if case .denied = policy.checkTool("type_text", forApp: "Banking") {
            // expected
        } else {
            Issue.record("Expected per-app deny to override global allow for Banking")
        }
        #expect(policy.checkTool("type_text", forApp: "Instagram") == .allowed)
    }

    @Test("perApp allow opens a globally denied tool")
    func perAppAllowOpensDeniedTool() {
        let config = PermissionConfig(
            allow: ["tap"],
            perApp: ["Debug": AppToolRules(allow: ["shake"])]
        )
        let policy = PermissionPolicy(skipPermissions: false, config: config)
        if case .denied = policy.checkTool("shake") { /* expected */ } else {
            Issue.record("Expected global denial for shake")
        }
        #expect(policy.checkTool("shake", forApp: "Debug") == .allowed)
    }

    @Test("perApp key match is case-insensitive")
    func perAppKeyCaseInsensitive() {
        let config = PermissionConfig(
            allow: ["*"],
            perApp: ["BANKING": AppToolRules(deny: ["tap"])]
        )
        let policy = PermissionPolicy(skipPermissions: false, config: config)
        if case .denied = policy.checkTool("tap", forApp: "banking") {
            // expected
        } else {
            Issue.record("Expected case-insensitive per-app match")
        }
    }

    @Test("toolsDenied returns only denied tools for the app")
    func toolsDeniedForApp() {
        let config = PermissionConfig(
            allow: ["*"],
            perApp: ["Banking": AppToolRules(deny: ["type_text", "open_url"])]
        )
        let policy = PermissionPolicy(skipPermissions: false, config: config)
        let denied = policy.toolsDenied(
            for: "Banking",
            requiredTools: ["tap", "swipe", "type_text", "press_key", "open_url"]
        )
        #expect(Set(denied) == Set(["type_text", "open_url"]))
    }
}
