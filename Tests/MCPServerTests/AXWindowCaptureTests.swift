// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the window-capture file format, the ax-capture command, and the corpus of live captures it produced.
// ABOUTME: The corpus replays what Accessibility really reported for iPhone Mirroring, tagged with where it was taken.

import CoreGraphics
import XCTest
import HelperLib
@testable import mirroir_mcp

final class AXWindowCaptureTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AXWindowCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private let environment = AXCaptureEnvironment(
        macOSVersion: "26.5 (25F71)", mirroringVersion: "1.6 (98.5)", localization: "en", strings: [:])

    private func inUseWindow() -> MirroringAXWindow {
        MirroringAXWindow(
            title: "iPhone Mirroring", frame: CGRect(x: 10, y: 20, width: 410, height: 898),
            hostingView: AXNodeSnapshot(role: "AXGroup", subrole: "AXHostingView", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone in Use"),
                AXNodeSnapshot(role: "AXButton", label: "Try Again"),
            ]),
            sheets: [AXNodeSnapshot(role: "AXSheet", children: [
                AXNodeSnapshot(role: "AXTextField", identifier: "password", label: nil),
            ])])
    }

    private func probe(_ window: MirroringAXWindow?, pid: pid_t? = 100) -> ScriptedMirroringProbe {
        let probe = ScriptedMirroringProbe()
        probe.set(pid: pid, axWindow: window, entries: [])
        return probe
    }

    // MARK: - File format

    func testACaptureRoundTripsThroughItsFile() throws {
        let capture = AXWindowCapture(
            version: AXWindowCapture.currentVersion, name: "in-use",
            macOSVersion: "26.5 (25F71)", mirroringVersion: "1.6 (98.5)", localization: "fr_CA",
            strings: ["iPhone in Use": "iPhone en cours d’utilisation"],
            state: .paused, move: .lockIPhone, frameIsBlank: nil, window: inUseWindow())
        let url = directory.appendingPathComponent("sub/in-use" + AXWindowCapture.fileSuffix)
        try capture.write(to: url)
        XCTAssertEqual(try AXWindowCapture.load(path: url.path), capture)

        let unreadable = AXWindowCapture(
            version: AXWindowCapture.currentVersion, name: "degraded", macOSVersion: "27.0 (26A1)",
            mirroringVersion: "2.0 (1)", localization: "en", strings: [:], state: .paused,
            move: .reopenMirroring, frameIsBlank: true,
            window: MirroringAXWindow(title: nil, frame: nil, hostingView: nil, isWindow: false))
        let second = directory.appendingPathComponent("degraded" + AXWindowCapture.fileSuffix)
        try unreadable.write(to: second)
        XCTAssertEqual(try AXWindowCapture.load(path: second.path), unreadable)
    }

    func testLoadRefusesAnotherVersion() throws {
        let capture = AXWindowCapture(
            version: AXWindowCapture.currentVersion + 1, name: "x", macOSVersion: "26.5 (25F71)",
            mirroringVersion: "1.6", localization: "en", strings: [:], state: .connected,
            move: nil, frameIsBlank: nil, window: inUseWindow())
        let url = directory.appendingPathComponent("x" + AXWindowCapture.fileSuffix)
        try capture.write(to: url)
        XCTAssertThrowsError(try AXWindowCapture.load(path: url.path)) {
            XCTAssertEqual($0 as? AXWindowCapture.LoadError, .unsupportedVersion(
                path: url.path, found: AXWindowCapture.currentVersion + 1,
                expected: AXWindowCapture.currentVersion))
            XCTAssertTrue($0.localizedDescription.contains(url.path))
        }
    }

    func testACaptureIsFiledUnderItsSystemVersionAndLanguage() {
        let capture = AXWindowCapture(
            version: 1, name: "x", macOSVersion: "26.5.1 (25F80)", mirroringVersion: "1.6",
            localization: "fr_CA", strings: [:], state: .connected, move: nil, frameIsBlank: nil,
            window: inUseWindow())
        XCTAssertEqual(capture.directoryName, "macos-26.5-fr_CA")
        XCTAssertEqual(capture.labels, ["iPhone in Use", "Try Again"])
    }

    // MARK: - Command

    func testParsesNameOutAndWatch() throws {
        XCTAssertEqual(
            try AXCaptureCommand.parseArguments(["paused", "--out", "/tmp/x", "--watch", "30"]),
            AXCaptureConfig(name: "paused", outputDirectory: "/tmp/x", watchSeconds: 30))
        let plain = try AXCaptureCommand.parseArguments(["connected"])
        XCTAssertEqual(plain.name, "connected")
        XCTAssertNil(plain.watchSeconds)
        XCTAssertEqual(plain.outputDirectory, FileManager.default.currentDirectoryPath)
    }

    func testBadCommandLinesAreRefused() {
        XCTAssertThrowsError(try AXCaptureCommand.parseArguments([])) {
            XCTAssertEqual($0 as? CLIArgumentError,
                           .missingArgument("a name for the capture", command: "ax-capture"))
        }
        XCTAssertThrowsError(try AXCaptureCommand.parseArguments(["a", "b"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .unexpectedArgument("b", command: "ax-capture"))
        }
        XCTAssertThrowsError(try AXCaptureCommand.parseArguments(["a", "--watch", "soon"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .invalidValue(
                flag: "--watch", value: "soon", expected: "a positive whole number of seconds"))
        }
        XCTAssertThrowsError(try AXCaptureCommand.parseArguments(["a", "--out"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .missingValue(flag: "--out"))
        }
    }

    func testACaptureRecordsStateMoveAndWindowFromOneSnapshot() throws {
        let window = MirroringAXWindow(
            title: "iPhone Mirroring", frame: nil,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXStaticText", label: "iPhone in Use"),
                AXNodeSnapshot(role: "AXButton", label: "Try Again"),
            ]))
        let capture = try XCTUnwrap(AXCaptureCommand.capture(
            name: "in-use", bundleID: "x", probe: probe(window), environment: environment))
        XCTAssertEqual(capture.state, .paused)
        XCTAssertEqual(capture.move, .lockIPhone)
        XCTAssertEqual(capture.window, window)
        XCTAssertNil(capture.frameIsBlank, "a labeled overlay is decided without the frame")
        XCTAssertEqual(capture.macOSVersion, "26.5 (25F71)")
        XCTAssertEqual(capture.version, AXWindowCapture.currentVersion)
    }

    func testACaptureOfAConnectedWindowHasNoMove() throws {
        let window = MirroringAXWindow(
            title: "iPhone Mirroring", frame: nil,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: []))
        let capture = try XCTUnwrap(AXCaptureCommand.capture(
            name: "connected", bundleID: "x", probe: probe(window), environment: environment))
        XCTAssertEqual(capture.state, .connected)
        XCTAssertNil(capture.move)
    }

    func testNothingIsCapturedWithoutARunningAppOrAWindow() {
        XCTAssertNil(AXCaptureCommand.capture(
            name: "x", bundleID: "x", probe: probe(inUseWindow(), pid: nil), environment: environment))
        XCTAssertNil(AXCaptureCommand.capture(
            name: "x", bundleID: "x", probe: probe(nil), environment: environment))
    }

    /// The frame is asked about only for a window showing unlabeled controls,
    /// and its answer is recorded then, so a replay can give the same one.
    func testTheFrameAnswerIsRecordedOnlyWhenItWasAsked() throws {
        let unlabeled = MirroringAXWindow(
            title: "iPhone Mirroring", frame: nil,
            hostingView: AXNodeSnapshot(role: "AXGroup", children: [
                AXNodeSnapshot(role: "AXButton"), AXNodeSnapshot(role: "AXButton"),
            ]))
        let scripted = probe(unlabeled)
        scripted.set(blankFrame: false)
        let capture = try XCTUnwrap(AXCaptureCommand.capture(
            name: "x", bundleID: "x", probe: scripted, environment: environment))
        XCTAssertEqual(capture.frameIsBlank, false)
        XCTAssertEqual(capture.state, .connected)
    }
}

/// Every live capture under Tests/Fixtures/mirroring-ax, replayed.
final class AXWindowCaptureCorpusTests: XCTestCase {

    private static var corpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mirroring-ax")
    }

    /// Each capture with the name of the directory it is filed in.
    private func corpus() throws -> [(capture: AXWindowCapture, directory: String, file: String)] {
        let files = FileManager.default.enumerator(at: Self.corpusDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix(AXWindowCapture.fileSuffix) } ?? []
        return try files.sorted { $0.path < $1.path }.map {
            (try AXWindowCapture.load(path: $0.path), $0.deletingLastPathComponent().lastPathComponent,
             $0.lastPathComponent)
        }
    }

    func testTheCorpusIsNotEmpty() throws {
        XCTAssertFalse(try corpus().isEmpty, "no capture under \(Self.corpusDirectory.path)")
    }

    func testEveryCaptureReadsAsItsRecordedState() throws {
        for entry in try corpus() {
            var asked = false
            let state = MirroringWindowResolver.state(of: entry.capture.window) {
                asked = true
                return entry.capture.frameIsBlank ?? true
            }
            XCTAssertEqual(state, entry.capture.state, entry.file)
            XCTAssertEqual(asked, entry.capture.frameIsBlank != nil,
                           "\(entry.file): the frame answer is recorded exactly when it is asked for")
        }
    }

    func testEveryPausedCaptureNamesItsRecordedMove() throws {
        for entry in try corpus() where entry.capture.state == .paused {
            let strings = entry.capture.strings
            let phrases = InterstitialPhrases(localize: { key in strings[key].map { [$0] } ?? [] })
            XCTAssertEqual(SessionBlockClassifier.block(of: entry.capture.window, phrases: phrases).move,
                           entry.capture.move, entry.file)
        }
    }

    func testEveryCaptureIsTaggedAndFiledUnderItsTags() throws {
        for entry in try corpus() {
            XCTAssertFalse(entry.capture.macOSVersion.isEmpty, entry.file)
            XCTAssertFalse(entry.capture.mirroringVersion.isEmpty, entry.file)
            XCTAssertEqual(entry.directory, entry.capture.directoryName, entry.file)
            XCTAssertEqual(entry.file, entry.capture.name + AXWindowCapture.fileSuffix)
        }
    }

    /// The Connection Interrupted screen, captured live on macOS 26.5: its
    /// Try Again button is a resume control, and its words call for the
    /// iPhone to be brought back in reach.
    func testTheConnectionInterruptedCaptureIsReadAsItWasSeen() throws {
        let entry = try XCTUnwrap(try corpus().first { $0.capture.name == "connection-interrupted" })
        XCTAssertEqual(entry.capture.state, .paused)
        XCTAssertEqual(entry.capture.move, .reconnectIPhone)
        XCTAssertTrue(entry.capture.labels.contains("Connection Interrupted"))
        XCTAssertTrue(entry.capture.labels.contains("Try Again"))
        XCTAssertFalse(entry.capture.labels.joined().contains("Yulplay"), "no phone name in a public fixture")
    }
}
