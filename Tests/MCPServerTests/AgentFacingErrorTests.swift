// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Every error only the user can clear must name the user's action and tell the agent to stop, not loop.
// ABOUTME: Table-driven over every session-block move, every permission refusal, and the connection refusals.

import CoreGraphics
import XCTest
import HelperLib
@testable import mirroir_mcp

final class AgentFacingErrorTests: XCTestCase {

    // MARK: - Session blocks

    func testEveryMoveOnlyTheUserCanMakeSaysToStop() {
        for move in SessionBlockMove.allCases {
            let refusal = SessionBlock(quoted: ["iPhone in Use", "[Try Again]"], move: move)
                .refusal(targetName: "iphone")
            XCTAssertTrue(refusal.contains(move.advice), "\(move): the advice names the action")
            XCTAssertEqual(refusal.contains(AgentInstruction.waitForUser), move.needsUser,
                           "\(move): \(refusal)")
        }
    }

    func testOnlyWaitingNeedsNoUser() {
        let agentMoves = SessionBlockMove.allCases.filter { !$0.needsUser }
        XCTAssertEqual(Set(agentMoves), [.waitForCameraOrMicrophone, .waitWhileConnecting])
        for move in agentMoves {
            XCTAssertTrue(move.advice.contains("Wait"), "\(move): \(move.advice)")
        }
    }

    // MARK: - Connection refusals

    private func refusal(for state: WindowState) -> String? {
        let bridge = StubBridge()
        bridge.state = state
        bridge.block = nil
        return InputSimulation(bridge: bridge).checkMirroringConnected(tag: "test")
    }

    func testAPausedOrUnreadableWindowSaysToStop() {
        for state in [WindowState.paused, .noWindow] {
            let message = refusal(for: state) ?? ""
            XCTAssertTrue(message.contains(AgentInstruction.waitForUser), "\(state): \(message)")
            XCTAssertTrue(message.contains("No input was sent"), "\(state): \(message)")
        }
    }

    // MARK: - Permission refusals

    func testEveryPermissionRefusalLeavesTheChoiceToTheUser() {
        let refusals: [PermissionDecision] = [
            PermissionPolicy(skipPermissions: false, config: nil).checkTool("tap"),
            PermissionPolicy(skipPermissions: false, config: PermissionConfig(allow: ["swipe"]))
                .checkTool("tap"),
            PermissionPolicy(skipPermissions: false, config: PermissionConfig(allow: ["tap"], deny: ["tap"]))
                .checkTool("tap"),
            PermissionPolicy(skipPermissions: false, config: PermissionConfig(
                allow: ["tap"], perApp: ["Mail": AppToolRules(deny: ["tap"])]))
                .checkTool("tap", forApp: "Mail"),
            PermissionPolicy(skipPermissions: false, config: PermissionConfig(blockedApps: ["Wallet"]))
                .checkAppLaunch("Wallet"),
        ]
        for decision in refusals {
            guard case .denied(let reason) = decision else {
                return XCTFail("expected a refusal, got \(decision)")
            }
            XCTAssertTrue(reason.hasSuffix(AgentInstruction.userDecides), reason)
        }
    }
}
