// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for DestructiveStepDetector — which skill steps require confirmation.
// ABOUTME: Covers pattern matching, inherently destructive types, and read-only steps.

import XCTest

@testable import mirroir_mcp

final class DestructiveStepDetectorTests: XCTestCase {

    private let patterns = DestructiveStepDetector.builtInConfirmPatterns

    private func skill(_ steps: [SkillStep], name: String = "sample") -> SkillDefinition {
        SkillDefinition(
            name: name,
            description: "",
            filePath: "/tmp/\(name).yaml",
            steps: steps,
            targets: [],
            kind: ""
        )
    }

    // MARK: - Steps that must be gated

    func testTapSendRequiresConfirmation() {
        let reason = DestructiveStepDetector.reasonForConfirmation(
            .tap(label: "Send"), followedBy: nil, patterns: patterns)
        XCTAssertEqual(reason, "matches 'send'")
    }

    func testTapDeleteRequiresConfirmation() {
        XCTAssertNotNil(DestructiveStepDetector.reasonForConfirmation(
            .tap(label: "Delete Message"), followedBy: nil, patterns: patterns))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertNotNil(DestructiveStepDetector.reasonForConfirmation(
            .tap(label: "UNINSTALL"), followedBy: nil, patterns: patterns))
    }

    func testLongPressIsGatedLikeTap() {
        XCTAssertNotNil(DestructiveStepDetector.reasonForConfirmation(
            .longPress(label: "Archive All", durationMs: nil), followedBy: nil, patterns: patterns))
    }

    func testResetAppIsGatedRegardlessOfPatterns() {
        // Its text says nothing destructive; the step type is what makes it so.
        let reason = DestructiveStepDetector.reasonForConfirmation(
            .resetApp(appName: "Notes"), followedBy: nil, patterns: [])
        XCTAssertEqual(reason, "reset_app erases app state")
    }

    func testMeasureInheritsFromItsInnerAction() {
        let step = SkillStep.measure(
            name: "send_latency",
            action: .tap(label: "Send"),
            until: "Delivered",
            maxSeconds: nil)
        XCTAssertNotNil(
            DestructiveStepDetector.reasonForConfirmation(
                step, followedBy: nil, patterns: patterns),
            "A destructive action does not become safe by being timed")
    }

    func testDragUsesBothEndpoints() {
        XCTAssertNotNil(DestructiveStepDetector.reasonForConfirmation(
            .drag(fromLabel: "Photo", toLabel: "Trash"), followedBy: nil, patterns: patterns))
    }

    // MARK: - Steps that must NOT be gated

    func testReadOnlyStepsAreNotGated() {
        // Each of these observes or navigates; none of them changes the world,
        // even when the text they carry contains a destructive word.
        let readOnly: [SkillStep] = [
            .assertVisible(label: "Delete"),
            .assertNotVisible(label: "Send"),
            .waitFor(label: "Purchase complete", timeoutSeconds: nil),
            .screenshot(label: "order sent"),
            .scrollTo(label: "Delete Account", direction: "down", maxScrolls: 3),
            .home,
            .swipe(direction: "up"),
        ]
        for step in readOnly {
            XCTAssertNil(
                DestructiveStepDetector.reasonForConfirmation(
                    step, followedBy: nil, patterns: patterns),
                "\(step.typeKey) only observes and must not be gated")
        }
    }

    func testOrdinaryTapIsNotGated() {
        XCTAssertNil(DestructiveStepDetector.reasonForConfirmation(
            .tap(label: "Settings"), followedBy: nil, patterns: patterns))
    }

    // MARK: - Scanning whole skills

    func testScanReportsPositionAndSkillInExecutionOrder() {
        let matches = DestructiveStepDetector.scan(
            skills: [skill([
                .launch(appName: "Messages"),
                .tap(label: "New"),
                .type(text: "hello"),
                .tap(label: "Send"),
            ], name: "compose")],
            patterns: patterns)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.skillName, "compose")
        XCTAssertEqual(matches.first?.stepNumber, 4, "step numbers are 1-based")
        XCTAssertEqual(matches.first?.summary, "tap: \"Send\"")
    }

    func testScanCoversEverySkill() {
        let matches = DestructiveStepDetector.scan(
            skills: [
                skill([.tap(label: "Send")], name: "first"),
                skill([.tap(label: "Cancel")], name: "second"),
                skill([.tap(label: "Delete")], name: "third"),
            ],
            patterns: patterns)
        XCTAssertEqual(matches.map(\.skillName), ["first", "third"])
    }

    func testCleanSkillProducesNoMatches() {
        let matches = DestructiveStepDetector.scan(
            skills: [skill([
                .launch(appName: "Weather"),
                .assertVisible(label: "Today"),
            ])],
            patterns: patterns)
        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - Caller-supplied patterns

    func testConfigPatternExtendsTheBuiltIns() {
        let extended = patterns + ["schedule pickup"]
        XCTAssertNil(DestructiveStepDetector.reasonForConfirmation(
            .tap(label: "Schedule pickup"), followedBy: nil, patterns: patterns))
        XCTAssertNotNil(DestructiveStepDetector.reasonForConfirmation(
            .tap(label: "Schedule pickup"), followedBy: nil, patterns: extended))
    }

    func testSlashWrappedPatternIsTreatedAsRegex() {
        let reason = DestructiveStepDetector.reasonForConfirmation(
            .tap(label: "Wipe device now"), followedBy: nil, patterns: ["/wipe\\s+device/"])
        XCTAssertEqual(reason, "matches '/wipe\\s+device/'")
    }

    func testInvalidRegexIsSkippedRatherThanCrashing() {
        XCTAssertNil(DestructiveStepDetector.reasonForConfirmation(
            .tap(label: "anything"), followedBy: nil, patterns: ["/[unclosed/"]))
    }
}
