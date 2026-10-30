// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for DestructiveStepGate — when a skill run is refused and when it proceeds.
// ABOUTME: Covers the bypasses, the built-in pattern floor, and the own-app reset_app exemption.

import XCTest

@testable import mirroir_mcp

final class DestructiveStepGateTests: XCTestCase {

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

    private var destructive: [SkillDefinition] {
        [skill([.launch(appName: "Messages"), .tap(label: "Send")])]
    }

    private var harmless: [SkillDefinition] {
        [skill([.launch(appName: "Weather"), .assertVisible(label: "Today")])]
    }

    func testDestructiveRunIsRefused() {
        XCTAssertEqual(
            DestructiveStepGate.refuse(skills: destructive, dryRun: false, confirmed: false),
            1,
            "An unconfirmed destructive step must stop the run")
    }

    func testHarmlessRunProceeds() {
        XCTAssertNil(
            DestructiveStepGate.refuse(skills: harmless, dryRun: false, confirmed: false))
    }

    func testConfirmedRunProceeds() {
        XCTAssertNil(
            DestructiveStepGate.refuse(skills: destructive, dryRun: false, confirmed: true),
            "--confirm-destructive is the explicit say-so the gate asks for")
    }

    func testDryRunProceedsWithoutConfirmation() {
        XCTAssertNil(
            DestructiveStepGate.refuse(skills: destructive, dryRun: true, confirmed: false),
            "A dry run executes nothing, so there is nothing to confirm")
    }

    func testEmptyRunProceeds() {
        XCTAssertNil(
            DestructiveStepGate.refuse(skills: [], dryRun: false, confirmed: false))
    }

    func testActivePatternsAlwaysContainTheBuiltInFloor() {
        // Config may extend the list; it must never be able to shrink it below
        // the built-in safety patterns.
        let active = DestructiveStepGate.activePatterns()
        for builtIn in DestructiveStepDetector.builtInConfirmPatterns {
            XCTAssertTrue(active.contains(builtIn), "'\(builtIn)' must survive config merging")
        }
    }

    // MARK: - reset_app before launch

    private func refused(_ steps: [SkillStep]) -> Int32? {
        DestructiveStepGate.refuse(skills: [skill(steps)], dryRun: false, confirmed: false)
    }

    func testOwnAppResetBeforeLaunchProceeds() {
        XCTAssertNil(
            refused([.resetApp(appName: "Clock"), .launch(appName: "Clock"),
                     .assertVisible(label: "Alarms")]),
            "Resetting the app the next step launches returns it to its root; no say-so needed")
    }

    func testOwnAppResetComparesTrimmedNames() {
        XCTAssertNil(refused([.resetApp(appName: " Clock "), .launch(appName: "Clock")]))
    }

    func testResetOfAnotherAppIsRefused() {
        XCTAssertEqual(
            refused([.launch(appName: "Clock"), .resetApp(appName: "Messages")]), 1,
            "A reset_app not followed by a launch of the same app stays destructive")
    }

    func testResetNotFollowedByLaunchIsRefused() {
        XCTAssertEqual(refused([.resetApp(appName: "Clock")]), 1)
        XCTAssertEqual(
            refused([.resetApp(appName: "Clock"), .home, .launch(appName: "Clock")]), 1,
            "Only the launch IMMEDIATELY after the reset exempts it")
    }

    func testResetFollowedByLaunchOfADifferentAppIsRefused() {
        XCTAssertEqual(
            refused([.resetApp(appName: "Messages"), .launch(appName: "Clock")]), 1)
    }

    func testOwnAppResetComparesCaseSensitively() {
        XCTAssertEqual(
            refused([.resetApp(appName: "clock"), .launch(appName: "Clock")]), 1)
    }

    /// The exempted reset is not a match, and the later destructive tap
    /// still is: exactly one match, at step 3.
    func testOwnAppResetDoesNotExemptALaterDestructiveStep() {
        let matches = DestructiveStepDetector.scan(
            skills: [skill([.resetApp(appName: "Messages"), .launch(appName: "Messages"),
                            .tap(label: "Send")])],
            patterns: DestructiveStepDetector.builtInConfirmPatterns)
        XCTAssertEqual(matches.map(\.stepNumber), [3], "\(matches)")
    }
}
