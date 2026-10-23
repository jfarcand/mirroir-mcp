// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for DestructiveStepGate — when a skill run is refused and when it proceeds.
// ABOUTME: Covers the dry-run and confirmed bypasses plus the built-in pattern floor.

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
}
