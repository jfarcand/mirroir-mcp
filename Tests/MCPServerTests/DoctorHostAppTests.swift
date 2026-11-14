// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests doctor's permission hints (the host app that holds the grant, the pane link, the restart rule)
// ABOUTME: and its screen-read verdicts; responsible processes are fixed paths, the screen is a describe result.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

final class DoctorHostAppTests: XCTestCase {

    // MARK: - HostApp

    /// Measured: an npx server started from an iTerm shell is answered for by iTerm.
    func testAnAppThatAnswersForTheServerHoldsTheGrant() {
        let grantee = HostApp.grantee(responsiblePath: "/Applications/iTerm.app/Contents/MacOS/iTerm2",
                                      isSelf: false)
        XCTAssertEqual(grantee, .app(name: "iTerm"))
    }

    func testANestedHelperResolvesToTheAppThatShipsIt() {
        let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        XCTAssertEqual(HostApp.bundlePath(executable: helper), "/Applications/Claude.app")
        XCTAssertEqual(HostApp.grantee(responsiblePath: helper, isSelf: false), .app(name: "Claude"))
    }

    /// Measured: Claude starts its servers through a disclaiming helper, so
    /// each server answers for itself and the panes list the binary.
    func testABareServerThatAnswersForItselfIsNamedByItsBinary() {
        let grantee = HostApp.grantee(responsiblePath: "/opt/homebrew/bin/mirroir-mcp", isSelf: true)
        XCTAssertEqual(grantee, .server(name: "mirroir-mcp"))
    }

    func testTheExtensionServerIsNamedByItsBundle() {
        let path = "/Users/u/Library/Application Support/Claude/Claude Extensions/mirroir-mcp/server/"
            + "mirroir-mcp.app/Contents/MacOS/mirroir-mcp"
        XCTAssertEqual(HostApp.grantee(responsiblePath: path, isSelf: true), .server(name: "mirroir-mcp"))
    }

    func testAResponsibleProcessOutsideAnyAppNamesNone() {
        XCTAssertNil(HostApp.grantee(responsiblePath: "/usr/sbin/sshd", isSelf: false))
    }

    /// The running test process answers to some process; the private call resolves.
    func testTheResponsibilityCallResolvesForThisProcess() {
        XCTAssertNotNil(HostApp.responsiblePID(of: getpid()))
    }

    // MARK: - PermissionGuidance

    func testScreenRecordingNamesTheAppThePaneAndTheRestart() {
        let hint = PermissionGuidance.hint(.screenRecording, grantee: .app(name: "iTerm"))
        XCTAssertEqual(hint, "Open System Settings > Privacy & Security > Screen Recording "
            + "(open \"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture\") "
            + "and turn on \"iTerm\". Then quit and reopen \"iTerm\": Screen Recording takes effect "
            + "only after a restart.")
    }

    /// Under launchd the serve agent's own bundle holds the grants, and it
    /// restarts through launchctl, not by quitting an app.
    func testTheServeAgentIsNamedAndRestartedThroughLaunchctl() {
        let path = "/Users/u/.mirroir-mcp/mirroir serve.app/Contents/MacOS/mirroir serve"
        let grantee = HostApp.grantee(responsiblePath: path, isSelf: true)
        XCTAssertEqual(grantee, .serveAgent)
        let hint = PermissionGuidance.hint(.screenRecording, grantee: grantee)
        XCTAssertTrue(hint.contains("turn on \"mirroir serve\""), hint)
        XCTAssertTrue(hint.contains("launchctl kickstart -k gui/$(id -u)/dev.mirroir.serve"), hint)
        XCTAssertFalse(hint.contains("quit and reopen"), hint)
    }

    func testAServerThatAnswersForItselfIsTurnedOnAndRestartedWithItsClient() {
        let hint = PermissionGuidance.hint(.screenRecording, grantee: .server(name: "mirroir-mcp"))
        XCTAssertTrue(hint.contains("turn on \"mirroir-mcp\""), hint)
        XCTAssertTrue(hint.contains("add it with the + button"), hint)
        XCTAssertTrue(hint.contains("quit and reopen the app that started mirroir-mcp"), hint)
        XCTAssertFalse(hint.contains("\"Claude\""), hint)
    }

    func testAccessibilityNeedsNoRestartAndAnUnknownHostIsDescribed() {
        let hint = PermissionGuidance.hint(.accessibility, grantee: nil)
        XCTAssertTrue(hint.contains("Privacy_Accessibility"), hint)
        XCTAssertTrue(hint.contains("the app that runs mirroir-mcp"), hint)
        XCTAssertFalse(hint.contains("restart"), hint)
    }

    // MARK: - DoctorCaptureCheck

    private let size = CGSize(width: 410, height: 898)

    private func screen(_ texts: [String], blank: Bool = false,
                        failure: String? = nil) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(
            elements: texts.map { TapPoint(text: $0, tapX: 10, tapY: 10, confidence: 0.9) },
            screenshotBase64: "", ocrFailure: failure, screenBlank: blank)
    }

    func testAReadableScreenPassesWithItsSizeAndBoxCount() {
        let check = DoctorCaptureCheck.verdict(screen(["Météo", "Montréal"]), windowSize: size, grantee: .app(name: "iTerm"))
        XCTAssertEqual(check.status, .passed)
        XCTAssertEqual(check.detail, "capture ok 410x898, OCR 2 boxes")
        XCTAssertNil(check.fixHint)
    }

    func testNoFrameMeansTheGrantNeedsARestart() {
        let check = DoctorCaptureCheck.verdict(nil, windowSize: size, grantee: .app(name: "iTerm"))
        XCTAssertEqual(check.status, .failed)
        XCTAssertTrue(check.fixHint?.contains("quit and reopen \"iTerm\"") ?? false, check.fixHint ?? "")
    }

    func testABlankFrameFailsAndAnEmptyScreenOnlyWarns() {
        XCTAssertEqual(DoctorCaptureCheck.verdict(screen([], blank: true), windowSize: size,
                                                  grantee: nil).status, .failed)
        XCTAssertEqual(DoctorCaptureCheck.verdict(screen([]), windowSize: size, grantee: nil).status,
                       .warned)
    }

    func testABrokenRecognizerIsNotReportedAsAnEmptyScreen() {
        let check = DoctorCaptureCheck.verdict(screen([], failure: "Vision request failed"),
                                               windowSize: size, grantee: nil)
        XCTAssertEqual(check.status, .failed)
        XCTAssertTrue(check.detail.contains("OCR failed: Vision request failed"), check.detail)
    }
}
