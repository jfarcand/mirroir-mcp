// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the record path's recording → .mirroir/ scenario transform (RecordingWalk + emitter).
// ABOUTME: Emits the checked-in Calculator fixtures into a temp root so they stay in step with the code.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class RecordingWalkTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-recording-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    /// `Tests/Fixtures/recordings/<name>.recording.json`, the file CI renders.
    static func fixturePath(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/recordings/\(name)\(Recording.fileSuffix)")
            .path
    }

    private var root: URL { scratch.appendingPathComponent("consumer/.mirroir") }

    /// A drift-defaults layer of the tests' own, so the emit never depends on
    /// a mirroir-skills checkout.
    private func driftDefaults() throws -> [String] {
        let path = scratch.appendingPathComponent(DriftDefaultsSeeder.fileName)
        try "version: 1\nfingerprint_similarity: { min: 0.85 }\n"
            .write(to: path, atomically: true, encoding: .utf8)
        return [path.path]
    }

    private func emit(_ recording: Recording) throws -> MirroirAppTreeEmitter.EmitResult {
        try MirroirAppTreeEmitter.emit(
            appName: recording.appName, flows: [RecordingWalk.flow(from: recording)],
            root: root, driftDefaultsCandidates: try driftDefaults())
    }

    private func element(_ text: String, y: Double = 400) -> TapPoint {
        TapPoint(text: text, tapX: 200, tapY: y, confidence: 0.95)
    }

    // MARK: - Fixtures

    /// The 4-tap Calculator fixture renders exactly this scenario: a tap per
    /// key, a wait on the expression the "3" tap reveals, and the closing
    /// assertion on the final screen.
    func testCalculatorFixtureEmitsExactScenario() throws {
        let recording = try Recording.load(path: Self.fixturePath("calculator-add"))
        let result = try emit(recording)

        XCTAssertEqual(result.scenarioPaths.map(\.lastPathComponent), ["calculator-add.ios.yaml"])
        XCTAssertEqual(result.appDir.lastPathComponent, "calculator")
        let yaml = try String(contentsOf: result.scenarioPaths[0], encoding: .utf8)
        let expected = ScenarioStepFormatter.generatedHeader + "\n" + """
            version: 1
            name: "calculator-add"
            steps:
              - target: { kind: ios, app: "Calculator" }
              - reset_app: "Calculator"
              - launch: "Calculator"
              - tap: "7"
              - tap: "+"
              - tap: "3"
              - wait_for: "7+3"
              - tap: "="
              - assert_visible: "7+3"

            """
        XCTAssertEqual(yaml, expected)
    }

    /// The FIXME fixture's opening tap OCR could not name: the emit refuses
    /// the only flow and writes nothing.
    func testFixmeFixtureIsRefusedAndWritesNothing() throws {
        let recording = try Recording.load(path: Self.fixturePath("calculator-fixme"))
        XCTAssertThrowsError(try emit(recording)) { error in
            guard case MirroirAppTreeEmitter.EmitError.noReplayableFlow(let app, let dropped) = error else {
                return XCTFail("expected noReplayableFlow, got \(error)")
            }
            XCTAssertEqual(app, "Calculator")
            XCTAssertEqual(dropped.map(\.flow), ["calculator-fixme"])
            XCTAssertTrue(dropped[0].reason.contains("step 1: tap recorded no label"),
                          dropped[0].reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Walk

    /// Screen `i + 1` carries step `i`'s action; the first carries none, and
    /// the last is the final screen.
    func testScreensPairEachStepWithTheScreenItReached() {
        let recording = Recording(
            appName: "Notes", flowName: "new-note",
            steps: [
                RecordedStep(kind: .tap(x: 1, y: 2, label: "New"), screenBefore: [element("New")]),
                RecordedStep(kind: .swipe(direction: "up"), screenBefore: [element("Title")]),
            ],
            finalScreen: [element("Done")])
        let screens = RecordingWalk.screens(from: recording)

        XCTAssertEqual(screens.map(\.index), [0, 1, 2])
        XCTAssertEqual(screens.map(\.actionType), [nil, "tap", "swipe"])
        XCTAssertEqual(screens.map(\.arrivedVia), [nil, "New", "up"])
        XCTAssertEqual(screens.map { $0.elements.map(\.text) }, [["New"], ["Title"], ["Done"]])
    }

    /// Multi-line typed text is one escaped scalar, never a `|` block.
    func testMultiLineTypeIsAnEscapedScalar() throws {
        let recording = Recording(
            appName: "Notes", flowName: "two-lines",
            steps: [
                RecordedStep(kind: .tap(x: 1, y: 2, label: "Body"), screenBefore: [element("Body")]),
                RecordedStep(kind: .type(text: "line one\nline two"), screenBefore: [element("Body")]),
            ],
            finalScreen: [element("Body")])
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "two-lines", appName: "Notes", screens: RecordingWalk.screens(from: recording))

        XCTAssertTrue(yaml.contains("  - type: \"line one\\nline two\"\n"), yaml)
        XCTAssertFalse(yaml.contains("|"), yaml)
    }

    /// A key press writes its modifiers inline, the form SkillParser reads back.
    func testPressKeyWithModifiersRoundTripsThroughTheParser() throws {
        let action = RecordingWalk.action(for: .pressKey(keyName: "a", modifiers: ["command", "shift"]))
        XCTAssertEqual(action.type, "press_key")
        XCTAssertEqual(action.value, "a+command+shift")

        guard case .pressKey(let key, let modifiers) =
            SkillParser.parseStep(key: "press_key", rawValue: action.value ?? "") else {
            return XCTFail("press_key value did not parse back as a key press")
        }
        XCTAssertEqual(key, "a")
        XCTAssertEqual(modifiers, ["command", "shift"])

        let recording = Recording(
            appName: "Notes", flowName: "select-all",
            steps: [RecordedStep(kind: .pressKey(keyName: "a", modifiers: ["command"]),
                                 screenBefore: [element("Body")])],
            finalScreen: [element("Body")])
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "select-all", appName: "Notes", screens: RecordingWalk.screens(from: recording))
        XCTAssertTrue(yaml.contains("  - press_key: \"a+command\"\n"), yaml)
    }

    /// A long press keeps only its label: replay holds for its own duration.
    func testLongPressDropsItsDuration() {
        let action = RecordingWalk.action(for: .longPress(x: 1, y: 2, label: "Photo", durationMs: 900))
        XCTAssertEqual(action.type, "long_press")
        XCTAssertEqual(action.value, "Photo")
    }

    // MARK: - File format

    func testRecordingSurvivesAJSONRoundTrip() throws {
        let recording = Recording(
            appName: "Notes", flowName: "round-trip",
            steps: [
                RecordedStep(kind: .tap(x: 10, y: 20, label: nil), screenBefore: [element("A")]),
                RecordedStep(kind: .longPress(x: 1, y: 2, label: "B", durationMs: 700),
                             screenBefore: [element("B", y: 300)]),
                RecordedStep(kind: .type(text: "héllo\n"), screenBefore: []),
                RecordedStep(kind: .pressKey(keyName: "return", modifiers: []), screenBefore: []),
                RecordedStep(kind: .swipe(direction: "left"), screenBefore: []),
            ],
            finalScreen: [element("C")])
        let url = scratch.appendingPathComponent("nested/round-trip\(Recording.fileSuffix)")
        try recording.write(to: url)

        XCTAssertEqual(try Recording.load(path: url.path), recording)
    }

    func testOtherVersionIsRefused() throws {
        let url = scratch.appendingPathComponent("future\(Recording.fileSuffix)")
        try """
            {"version": 2, "appName": "Notes", "flowName": "f", "steps": [], "finalScreen": []}
            """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try Recording.load(path: url.path)) { error in
            XCTAssertEqual(error as? Recording.LoadError, .unsupportedVersion(
                path: url.path, found: 2, expected: Recording.currentVersion))
        }
    }
}
