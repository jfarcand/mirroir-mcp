// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests doctor's permission hints (the host app that holds the grant, the pane link, the restart rule)
// ABOUTME: and its screen-read verdicts; process chains are fixed paths, the screen is a describe result.

import CoreGraphics
import HelperLib
import XCTest
@testable import mirroir_mcp

final class DoctorHostAppTests: XCTestCase {

    // MARK: - HostApp

    func testATerminalSessionIsGrantedThroughTheTerminal() {
        // Measured on this Mac: mirroir-mcp ← zsh ← claude ← zsh ← login ← iTermServer ← iTerm2.
        let chain = ["/opt/homebrew/bin/mirroir-mcp", "/bin/zsh",
                     "/Users/a/.local/share/claude/versions/2.1.317", "/bin/zsh", "/usr/bin/login",
                     "/Users/a/Library/Application Support/iTerm2/iTermServer-3.7.3",
                     "/Applications/iTerm.app/Contents/MacOS/iTerm2"]
        XCTAssertEqual(HostApp.bundlePath(chain: chain), "/Applications/iTerm.app")
        XCTAssertEqual(HostApp.displayName(bundlePath: "/Applications/iTerm.app"), "iTerm")
    }

    func testANestedHelperResolvesToTheAppThatShipsIt() {
        let chain = ["/opt/homebrew/bin/mirroir-mcp",
                     "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
                     "/Applications/Claude.app/Contents/MacOS/Claude"]
        XCTAssertEqual(HostApp.bundlePath(chain: chain), "/Applications/Claude.app")
    }

    func testTheOutermostAppWinsOverAnInnerOne() {
        // VS Code's integrated terminal under the VS Code app.
        let chain = ["/opt/homebrew/bin/mirroir-mcp", "/bin/zsh",
                     "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
                     "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"]
        XCTAssertEqual(HostApp.bundlePath(chain: chain).map(HostApp.displayName(bundlePath:)),
                       "Visual Studio Code")
    }

    func testNoAppAmongTheAncestorsNamesNone() {
        XCTAssertNil(HostApp.bundlePath(chain: ["/opt/homebrew/bin/mirroir-mcp", "/usr/sbin/sshd"]))
    }

    // MARK: - PermissionGuidance

    func testScreenRecordingNamesTheAppThePaneAndTheRestart() {
        let hint = PermissionGuidance.hint(.screenRecording, hostApp: "iTerm")
        XCTAssertEqual(hint, "Open System Settings > Privacy & Security > Screen Recording "
            + "(open \"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture\") "
            + "and turn on \"iTerm\". Then quit and reopen iTerm: Screen Recording takes effect "
            + "only after a restart.")
    }

    func testAccessibilityNeedsNoRestartAndAnUnknownHostIsDescribed() {
        let hint = PermissionGuidance.hint(.accessibility, hostApp: nil)
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
        let check = DoctorCaptureCheck.verdict(screen(["Météo", "Montréal"]), windowSize: size, hostApp: "iTerm")
        XCTAssertEqual(check.status, .passed)
        XCTAssertEqual(check.detail, "capture ok 410x898, OCR 2 boxes")
        XCTAssertNil(check.fixHint)
    }

    func testNoFrameMeansTheGrantNeedsARestart() {
        let check = DoctorCaptureCheck.verdict(nil, windowSize: size, hostApp: "iTerm")
        XCTAssertEqual(check.status, .failed)
        XCTAssertTrue(check.fixHint?.contains("quit and reopen \"iTerm\"") ?? false, check.fixHint ?? "")
    }

    func testABlankFrameFailsAndAnEmptyScreenOnlyWarns() {
        XCTAssertEqual(DoctorCaptureCheck.verdict(screen([], blank: true), windowSize: size,
                                                  hostApp: nil).status, .failed)
        XCTAssertEqual(DoctorCaptureCheck.verdict(screen([]), windowSize: size, hostApp: nil).status,
                       .warned)
    }

    func testABrokenRecognizerIsNotReportedAsAnEmptyScreen() {
        let check = DoctorCaptureCheck.verdict(screen([], failure: "Vision request failed"),
                                               windowSize: size, hostApp: nil)
        XCTAssertEqual(check.status, .failed)
        XCTAssertTrue(check.detail.contains("OCR failed: Vision request failed"), check.detail)
    }
}
