// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for `doctor --fix`: which panes it fixes and in what order, what it tells the user, when it moves on.
// ABOUTME: System Settings and the fresh-process probe are a scripted fake; nothing opens a pane or reads real grants.

import XCTest
@testable import mirroir_mcp

/// Stands in for System Settings and the fresh `doctor --grants` process,
/// which a unit test must not open or depend on: it answers from a script.
private final class ScriptedGrants: PrivacyGrantChecking, @unchecked Sendable {
    var opened: [PermissionGuidance.Pane] = []
    var opens = true
    /// One answer per probe, in order; the last one repeats.
    var probes: [Set<PermissionGuidance.Pane>?]
    var probeCount = 0

    init(probes: [Set<PermissionGuidance.Pane>?]) { self.probes = probes }

    func open(_ pane: PermissionGuidance.Pane) -> Bool {
        opened.append(pane)
        return opens
    }

    func grantedToFreshProcess() -> Set<PermissionGuidance.Pane>? {
        defer { probeCount += 1 }
        return probes[min(probeCount, probes.count - 1)]
    }
}

final class DoctorGrantFixTests: XCTestCase {

    private func failed(_ pane: PermissionGuidance.Pane) -> DoctorCheck {
        DoctorCheck(name: pane.title, status: .failed, detail: "off", fixHint: nil, fixURL: pane.url)
    }

    func testOnlyFailedGrantsAreFixedAccessibilityFirst() {
        let checks = [failed(.screenRecording), failed(.accessibility),
                      DoctorCheck(name: "macOS version", status: .failed, detail: "14", fixHint: nil)]
        XCTAssertEqual(DoctorGrantFix.missingPanes(in: checks), [.accessibility, .screenRecording])
        let passed = DoctorCheck(name: "Accessibility", status: .passed, detail: "ok", fixHint: nil,
                                 fixURL: PermissionGuidance.Pane.accessibility.url)
        XCTAssertEqual(DoctorGrantFix.missingPanes(in: [passed, failed(.screenRecording)]), [.screenRecording])
    }

    func testEachPaneIsOpenedAndWaitedForUntilAFreshProcessIsGranted() {
        let system = ScriptedGrants(probes: [[], [.accessibility], [.accessibility, .screenRecording]])
        var lines: [String] = []
        var waits = 0
        let outcomes = DoctorGrantFix.run(
            panes: [.accessibility, .screenRecording], grantee: .server(name: "mirroir-mcp"),
            system: system, polls: 5, wait: { waits += 1 }, say: { lines.append($0) })

        XCTAssertEqual(outcomes.map(\.0), [.accessibility, .screenRecording])
        XCTAssertEqual(outcomes.map(\.1), [.granted, .granted])
        XCTAssertEqual(system.opened, [.accessibility, .screenRecording])
        XCTAssertEqual(waits, 1, "the second probe saw Accessibility; Screen Recording's first probe saw it too")
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("turn on \"mirroir-mcp\""), text)
        XCTAssertTrue(text.contains("Now quit and reopen the app that started mirroir-mcp"), text)
        XCTAssertTrue(text.contains("check_health"), text)
    }

    func testAGrantNeverGivenTimesOutAfterThePolls() {
        let system = ScriptedGrants(probes: [[]])
        var waits = 0
        let outcomes = DoctorGrantFix.run(panes: [.screenRecording], grantee: .app(name: "iTerm"),
                                          system: system, polls: 3, wait: { waits += 1 }, say: { _ in })
        XCTAssertEqual(outcomes.map(\.1), [.timedOut])
        XCTAssertEqual(system.probeCount, 3)
        XCTAssertEqual(waits, 2)
    }

    func testAPaneThatDoesNotOpenAndAProbeThatCannotRunAreReported() {
        let closed = ScriptedGrants(probes: [[]])
        closed.opens = false
        XCTAssertEqual(DoctorGrantFix.run(panes: [.accessibility], grantee: nil, system: closed, polls: 2,
                                          wait: {}, say: { _ in }).map(\.1), [.paneDidNotOpen])
        XCTAssertEqual(closed.probeCount, 0)

        let broken = ScriptedGrants(probes: [nil])
        var lines: [String] = []
        XCTAssertEqual(DoctorGrantFix.run(panes: [.screenRecording], grantee: nil, system: broken, polls: 2,
                                          wait: {}, say: { lines.append($0) }).map(\.1), [.probeFailed])
        XCTAssertFalse(lines.joined().contains("Now quit and reopen"), "no restart advice for a grant not seen")
    }

    /// The probe reads the report `doctor --json --grants` writes.
    func testGrantedPanesAreReadFromTheDoctorJSON() throws {
        let report: [String: Any] = ["checks": [
            ["name": DoctorCommand.screenCaptureCheckName, "status": "failed"],
            ["name": DoctorCommand.accessibilityCheckName, "status": "passed"],
        ]]
        let data = try JSONSerialization.data(withJSONObject: report)
        XCTAssertEqual(DoctorGrantFix.grantedPanes(inDoctorJSON: data), [.accessibility])
        XCTAssertNil(DoctorGrantFix.grantedPanes(inDoctorJSON: Data("not json".utf8)))
    }

    func testFixAndGrantsAreParsedAndFixRefusesJSON() throws {
        XCTAssertTrue(try DoctorCommand.parseArguments(["--fix"]).fix)
        XCTAssertTrue(try DoctorCommand.parseArguments(["--json", "--grants"]).grantsOnly)
        XCTAssertThrowsError(try DoctorCommand.parseArguments(["--fix", "--json"]))
        XCTAssertThrowsError(try DoctorCommand.parseArguments(["--fix", "--grants"]))
    }
}
