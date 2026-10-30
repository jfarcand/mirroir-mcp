// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that the iOS scenario emitter refuses walks it cannot replay instead of shortening them.
// ABOUTME: AI-only and unlabeled steps, source-screen label resolution, arrival waits, multi-flow and failing emits.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class ScenarioEmitRefusalTests: XCTestCase {

    private func screen(
        _ index: Int, _ action: String?, _ via: String?, _ labels: [String]
    ) -> ExploredScreen {
        ExploredScreen(
            index: index,
            elements: labels.map { TapPoint(text: $0, tapX: 100, tapY: 200, confidence: 0.95) },
            hints: [],
            actionType: action,
            arrivedVia: via,
            screenshotBase64: "")
    }

    private func tmpRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-refuse-\(UUID().uuidString)/.mirroir")
    }

    /// Start → Next → `action` on `via`. The middle screen shows `via`, so an
    /// element action finds its label on the screen it acts on.
    private func walk(_ action: String, _ via: String?) -> [ExploredScreen] {
        [
            screen(0, nil, nil, ["Start", "Next"]),
            screen(1, "tap", "Next", ["Middle"] + [via].compactMap { $0 }.filter { !$0.isEmpty }),
            screen(2, action, via, ["End"]),
        ]
    }

    // MARK: - Refusals

    /// Every AI-only kind the runner refuses inside an ios block is refused
    /// by name here, at the walk index it sits on.
    func testEveryAIOnlyKindIsRefusedByName() {
        for kind in SkillParser.aiOnlyStepTypes.sorted() {
            XCTAssertThrowsError(try ScenarioStepFormatter.scenarioYAML(
                name: "ai", appName: "Clock", screens: walk(kind, "note"))) { error in
                XCTAssertEqual(error as? ScenarioStepFormatter.FormatError,
                               .aiOnlyAction(index: 2, action: kind))
            }
        }
    }

    /// A tap with no label throws, naming the step — the walk is never shortened.
    func testAnUnlabeledTapIsRefused() {
        for via in [nil, ""] as [String?] {
            XCTAssertThrowsError(try ScenarioStepFormatter.scenarioYAML(
                name: "unlabeled", appName: "Clock", screens: walk("tap", via))) { error in
                XCTAssertEqual(error as? ScenarioStepFormatter.FormatError,
                               .unlabeledAction(index: 2, action: "tap"))
            }
        }
    }

    /// A long press on a label text-cleanup.md excludes throws, naming it.
    func testAnExcludedLabelIsRefused() {
        XCTAssertTrue(ActionStepFormatter.isExcludedLabel("icon"),
                      "text-cleanup.md must be on the skills search path for this test")
        XCTAssertThrowsError(try ScenarioStepFormatter.scenarioYAML(
            name: "excluded", appName: "Clock", screens: walk("long_press", "icon"))) { error in
            XCTAssertEqual(error as? ScenarioStepFormatter.FormatError,
                           .excludedLabel(index: 2, action: "long_press", label: "icon"))
        }
    }

    /// A literal action with no value throws instead of vanishing.
    func testALiteralActionWithNoValueIsRefused() {
        XCTAssertThrowsError(try ScenarioStepFormatter.scenarioYAML(
            name: "empty", appName: "Clock", screens: walk("type", nil))) { error in
            XCTAssertEqual(error as? ScenarioStepFormatter.FormatError,
                           .emptyValue(index: 2, action: "type"))
        }
    }

    // MARK: - Label resolution and arrival

    /// The label resolves against the screen the tap acted on. The
    /// destination holds "General Settings", which the containment match
    /// would have swapped in for the tapped "general".
    func testLabelsResolveAgainstTheSourceScreen() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "source", appName: "Settings", screens: [
                screen(0, nil, nil, ["General", "Privacy"]),
                screen(1, "tap", "general", ["General Settings", "About"]),
            ])
        XCTAssertTrue(yaml.contains("  - tap: \"General\"\n"), yaml)
        XCTAssertFalse(yaml.contains("tap: \"General Settings\""), yaml)
    }

    /// A tap waits for the longest label its arrival added; when the arrival
    /// added none, no wait is invented and the destination is asserted.
    func testATapWaitsForALandmarkOfTheScreenItReached() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "arrival", appName: "Clock", screens: [
                screen(0, nil, nil, ["Alarms", "Add Alarm"]),
                screen(1, "tap", "Add Alarm", ["Add Alarm", "Cancel", "Snooze"]),
                screen(2, "tap", "Cancel", ["Alarms", "Add Alarm"]),
                screen(3, "tap", "Alarms", ["Alarms", "Add Alarm"]),
            ])
        XCTAssertTrue(yaml.contains(
            "  - tap: \"Add Alarm\"\n  - wait_for: \"Cancel\"\n" +
            "  - tap: \"Cancel\"\n  - wait_for: \"Alarms\"\n" +
            "  - tap: \"Alarms\"\n  - assert_visible: \"Add Alarm\"\n"), yaml)
    }

    func testTheScenarioOpensWithTheOwnershipHeader() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "header", appName: "Clock", screens: [screen(0, nil, nil, ["Alarms"])])
        XCTAssertTrue(yaml.hasPrefix(ScenarioStepFormatter.generatedHeader + "\nversion: 1\n"))
        XCTAssertFalse(ScenarioStepFormatter.generatedHeader.contains("\n"))
    }

    // MARK: - Emitter

    /// Nothing to emit is an error, never an empty success.
    func testEmittingNoFlowOrAnEmptyWalkFails() {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [], root: root)) {
            XCTAssertEqual($0 as? MirroirAppTreeEmitter.EmitError, .noFlows(appName: "Clock"))
        }
        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: [.init(name: "f", screens: [])], root: root)) {
            XCTAssertEqual($0 as? MirroirAppTreeEmitter.EmitError, .emptyWalk(flow: "f"))
        }
    }

    /// One refused flow leaves the tree unwritten — the good flow beside it
    /// is not emitted alone.
    /// One unreplayable path drops only its own flow, named with its reason;
    /// the replayable one is still written and declared.
    func testARefusedFlowIsDroppedAndTheOthersAreEmitted() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "good", screens: walk("tap", "End")),
            .init(name: "bad", screens: walk("remember", "note")),
        ], root: root)
        XCTAssertEqual(result.scenarioPaths.map(\.lastPathComponent), ["good.ios.yaml"])
        XCTAssertEqual(result.dropped.map(\.flow), ["bad"])
        XCTAssertTrue(result.dropped[0].reason.contains("\"remember\" is an AI-only step"),
                      result.dropped[0].reason)
        let sample = try String(
            contentsOf: result.appDir.appendingPathComponent("SAMPLE.md"), encoding: .utf8)
        XCTAssertFalse(sample.contains("bad.ios.yaml"), sample)
    }

    /// An icon-only tab — a textless anchor named from APP.md — cannot be
    /// found by a replay: that flow is dropped and the tab-free one emitted.
    /// The result note names the dropped flow and why.
    func testAnIconOnlyTabFlowIsDroppedAndNamedInTheNote() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var iconTab = ExploredScreen(
            index: 1, elements: [TapPoint(text: "Playlists", tapX: 100, tapY: 200, confidence: 0.9)],
            hints: [], actionType: "tap", arrivedVia: "", screenshotBase64: "")
        iconTab.displayLabel = "Library"
        let note = try ExplorationLoopRunner.emitNote(appName: "Music", flows: [
            .init(name: "open library", screens: [screen(0, nil, nil, ["Listen Now"]), iconTab]),
            .init(name: "next", screens: walk("tap", "End")),
        ], outputDir: base.path)
        XCTAssertTrue(note.contains("scenarios/next.ios.yaml"), note)
        XCTAssertFalse(note.contains("open-library.ios.yaml"), note)
        XCTAssertTrue(note.contains(
            "  dropped (a step no replay can perform; no scenario written):\n" +
            "    open library: step 1: tap label \"Library\" is not in the OCR text"), note)
    }

    /// Only when every flow is dropped is the emit refused, naming each, and
    /// the tree is left untouched.
    func testAnEmitWithNoReplayableFlowWritesNothing() {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "bad", screens: walk("remember", "note")),
            .init(name: "worse", screens: walk("pinch", "Map")),
        ], root: root)) { error in
            guard case .noReplayableFlow(let app, let dropped) =
                    error as? MirroirAppTreeEmitter.EmitError else {
                return XCTFail("expected noReplayableFlow, got \(error)")
            }
            XCTAssertEqual(app, "Clock")
            XCTAssertEqual(dropped.map(\.flow), ["bad", "worse"])
            XCTAssertTrue(error.localizedDescription.contains("    worse: step 2:"),
                          error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// Every flow lands as its own scenario, in slug order; repeated slugs
    /// are suffixed, and a re-emit of declared flows names the stale ones.
    func testEveryFlowIsEmittedAndDeclared() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "Zeta", screens: walk("tap", "End")),
            .init(name: "alpha", screens: walk("swipe", "up")),
            .init(name: "Alpha", screens: walk("swipe", "down")),
        ], root: root)
        XCTAssertEqual(first.scenarioPaths.map(\.lastPathComponent),
                       ["alpha.ios.yaml", "alpha-2.ios.yaml", "zeta.ios.yaml"])
        let sample = try String(
            contentsOf: first.appDir.appendingPathComponent("SAMPLE.md"), encoding: .utf8)
        XCTAssertTrue(sample.contains(
            "    must_pass:\n      - scenarios/alpha.ios.yaml\n" +
            "      - scenarios/alpha-2.ios.yaml\n      - scenarios/zeta.ios.yaml\n"), sample)
        let second = try String(contentsOf: first.scenarioPaths[1], encoding: .utf8)
        XCTAssertTrue(second.contains("name: \"alpha-2\"\n"), second)

        let again = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("swipe", "up")),
            .init(name: "Alpha", screens: walk("swipe", "down")),
        ], root: root)
        XCTAssertEqual(again.sampleNote,
                       "scenarios/alpha.ios.yaml, scenarios/alpha-2.ios.yaml already declared in " +
                       "SAMPLE.md\nSAMPLE.md also declares scenarios/zeta.ios.yaml, which this " +
                       "exploration did not produce; they stay on disk and declared — remove " +
                       "them from SAMPLE.md if the flow no longer exists")
    }

    /// Re-emitting a flow a human-owned SAMPLE.md (no ownership marker) does
    /// not declare is an error carrying the exact lines to paste and the stale
    /// declared flows — never a quiet success that mirroir-run would not
    /// replay. Every other file is still written.
    func testAReEmitWithAnUndeclaredFlowIsAnErrorWithTheSnippet() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        _ = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("swipe", "up")),
            .init(name: "zeta", screens: walk("swipe", "up")),
        ], root: root)
        let sample = root.appendingPathComponent("apps/clock/SAMPLE.md")
        let human = try String(contentsOf: sample, encoding: .utf8)
            .replacingOccurrences(of: MirroirManifestUpsert.sampleOwnershipMarker + "\n", with: "")
        try human.write(to: sample, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("swipe", "up")),
            .init(name: "beta", screens: walk("swipe", "up")),
        ], root: root)) { error in
            XCTAssertEqual(error as? MirroirAppTreeEmitter.EmitError, .undeclaredFlows(
                sample: sample.path, undeclared: ["scenarios/beta.ios.yaml"],
                snippet: "      - scenarios/beta.ios.yaml",
                stale: ["scenarios/zeta.ios.yaml"], dropped: [], planError: nil))
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(
                "SAMPLE.md under session.scenarios.must_pass:\n      - scenarios/beta.ios.yaml"),
                message)
            XCTAssertTrue(message.contains("also declares scenarios/zeta.ios.yaml"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("apps/clock/scenarios/beta.ios.yaml").path))
    }

    /// A repeated slug skips a suffix another flow's own slug holds: "Foo",
    /// "Foo" and "Foo 2" write three files, and SAMPLE.md lists each once.
    func testASlugSuffixNeverCollidesWithAnotherFlowsSlug() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "Foo", screens: walk("swipe", "up")),
            .init(name: "Foo", screens: walk("swipe", "down")),
            .init(name: "Foo 2", screens: walk("swipe", "left")),
        ], root: root)
        XCTAssertEqual(Set(result.scenarioPaths.map(\.lastPathComponent)),
                       ["foo.ios.yaml", "foo-2.ios.yaml", "foo-3.ios.yaml"])
        let sample = try String(
            contentsOf: result.appDir.appendingPathComponent("SAMPLE.md"), encoding: .utf8)
        for file in ["foo", "foo-2", "foo-3"] {
            XCTAssertEqual(sample.components(separatedBy: "scenarios/\(file).ios.yaml").count, 2,
                           "\(file) declared once:\n\(sample)")
        }
        let foo2 = try String(contentsOf: root.appendingPathComponent(
            "apps/clock/scenarios/foo-2.ios.yaml"), encoding: .utf8)
        XCTAssertTrue(foo2.contains("- swipe: \"left\""), foo2)
    }

    // MARK: - Tool result

    /// `finish` with emit=true and a walk the emitter refuses is an error
    /// result naming why; with a replayable walk it writes the tree.
    func testFinishWithEmitFailsLoudlyAndWritesOnSuccess() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-finish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let refused = finish(action: "remember", via: "note", outputDir: base.path)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(resultText(refused).contains(
            "emit failed: emit requested but no flow of Clock can replay; nothing was emitted:\n" +
            "    add alarm: step 1: \"remember\" is an AI-only step"),
                      resultText(refused))

        let written = finish(action: "tap", via: "Add Alarm", outputDir: base.path)
        XCTAssertFalse(written.isError, resultText(written))
        let scenario = base.appendingPathComponent(".mirroir/apps/clock/scenarios/add-alarm.ios.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenario.path), resultText(written))
    }

    func testAnEmitFailureIsAnErrorResultCarryingTheExplorationText() {
        let result = ExplorationLoopRunner.emitFailure(
            resultText: "explored 3 screens",
            error: MirroirAppTreeEmitter.EmitError.noFlows(appName: "Clock"))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(resultText(result).hasPrefix("explored 3 screens\n\n---\nemit failed: "))
    }

    private func finish(action: String, via: String, outputDir: String) -> MCPToolResult {
        let session = ExplorationSession()
        session.start(appName: "Clock", goal: "add alarm")
        _ = session.capture(
            elements: [TapPoint(text: "Alarms", tapX: 100, tapY: 100, confidence: 0.95),
                       TapPoint(text: "Add Alarm", tapX: 300, tapY: 100, confidence: 0.95)],
            hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: "")
        _ = session.capture(
            elements: [TapPoint(text: "Cancel", tapX: 50, tapY: 100, confidence: 0.95),
                       TapPoint(text: "Snooze", tapX: 100, tapY: 400, confidence: 0.95)],
            hints: [], actionType: action, arrivedVia: via, screenshotBase64: "")
        return MirroirMCP.handleFinish(session: session, emit: true, outputDir: outputDir)
    }

    private func resultText(_ result: MCPToolResult) -> String {
        result.content.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }
}
