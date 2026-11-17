/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Tests for driving mode in PermissionPolicy: the apps that open while driving and the rules read from the file.
// ABOUTME: The driving rules come from an injected source, so no test reads ~/.mirroir-mcp.

import Foundation
import Testing
@testable import HelperLib

@Suite("PermissionPolicy - Driving")
struct DrivingRulesTests {

    private func policy(_ driving: DrivingRules?, blockedApps: [String]? = nil,
                        skip: Bool = false) -> PermissionPolicy {
        PermissionPolicy(skipPermissions: skip, config: PermissionConfig(blockedApps: blockedApps),
                         drivingSource: { driving })
    }

    @Test("driving mode off leaves every app open")
    func offAllowsApps() {
        #expect(policy(nil).checkAppLaunch("Instagram") == .allowed)
        #expect(policy(DrivingRules(on: false, allowedApps: [])).checkAppLaunch("Instagram") == .allowed)
        #expect(policy(DrivingRules(on: false)).driving == nil)
        #expect(!policy(nil).restrictsApps)
    }

    @Test("while driving only the listed apps open, whatever the case")
    func onlyListedApps() {
        let rules = policy(DrivingRules(on: true, allowedApps: ["Spotify", "Waze"]))
        #expect(rules.checkAppLaunch("spotify") == .allowed)
        guard case .denied(let reason) = rules.checkAppLaunch("Instagram") else {
            Issue.record("Instagram should not open while driving"); return
        }
        #expect(reason.contains("does not open while driving"))
        #expect(reason.contains("Spotify, Waze"))
        #expect(rules.restrictsApps)
    }

    @Test("driving with no list opens no app")
    func noListNoApp() {
        guard case .denied(let reason) = policy(DrivingRules(on: true)).checkAppLaunch("Spotify") else {
            Issue.record("no app should open"); return
        }
        #expect(reason.contains("no app is listed"))
    }

    @Test("skipping permissions does not turn driving mode off")
    func skipKeepsDriving() {
        let rules = policy(DrivingRules(on: true, allowedApps: ["Spotify"]), skip: true)
        #expect(rules.checkAppLaunch("Instagram") != .allowed)
        #expect(rules.driving != nil)
    }

    @Test("blockedApps still wins over the driving list")
    func blockedWins() {
        let rules = policy(DrivingRules(on: true, allowedApps: ["Spotify"]), blockedApps: ["Spotify"])
        guard case .denied(let reason) = rules.checkAppLaunch("Spotify") else {
            Issue.record("a blocked app stays blocked"); return
        }
        #expect(reason.contains("blockedApps"))
    }

    @Test("the rules are read on every check, so a switch needs no restart")
    func readLive() {
        final class Box: @unchecked Sendable { var rules: DrivingRules? }
        let box = Box()
        let live = PermissionPolicy(skipPermissions: false, config: nil, drivingSource: { box.rules })
        #expect(live.checkAppLaunch("Instagram") == .allowed)
        box.rules = DrivingRules(on: true, allowedApps: [])
        #expect(live.checkAppLaunch("Instagram") != .allowed)
    }

    @Test("permissions.json carries a driving section")
    func decodes() throws {
        let json = #"{"allow": ["*"], "driving": {"on": true, "allowedApps": ["Spotify"]}}"#
        let config = try JSONDecoder().decode(PermissionConfig.self, from: Data(json.utf8))
        #expect(config.driving == DrivingRules(on: true, allowedApps: ["Spotify"]))
    }
}
