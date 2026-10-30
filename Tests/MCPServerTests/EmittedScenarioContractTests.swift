// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Pins the emitter's output to a checked-in .mirroir/ tree mirroir-run's contract test loads.
// ABOUTME: Regenerates the golden byte for byte from a synthetic Clock walk, so either side drifting fails a test.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// `generate_skill emit=true` writes a `.mirroir/` tree mirroir-run must load,
/// plan and hand to mirroir-mcp unchanged. The tree for a synthetic Clock
/// exploration is committed under `runner/tests/fixtures/emitted/`, where the
/// runner's `emitted_scenario_contract` tests read it; this suite regenerates
/// it from the emitter and fails on any byte of drift.
///
/// Set `MIRROIR_REGENERATE_EMITTED_GOLDEN=1` to rewrite the fixtures from the
/// emitter after an intended format change, then commit them with the change.
final class EmittedScenarioContractTests: XCTestCase {

    private static let regenerateVariable = "MIRROIR_REGENERATE_EMITTED_GOLDEN"

    // MARK: - Synthetic Clock screens (the FakeMirroring Clock pack's labels)

    private static let alarms = [
        "Edit", "Add Alarm", "Alarms", "Sleep | Wake Up", "Other", "6:30 AM",
        "Alarm, every weekday", "7:45 AM", "Gym", "World Clock", "Stopwatch", "Timers",
    ]
    private static let addAlarm = [
        "Cancel", "Add Alarm", "Save", "Repeat", "Label", "Sound", "Snooze",
    ]
    /// The Alarms list as the explorer saw it after scrolling: the arrival
    /// viewport, then the rows scrolling merged in (`scrolledElementCount`).
    private static let alarmsViewport = [
        "Edit", "Add Alarm", "Alarms", "Sleep | Wake Up", "Other", "6:30 AM",
        "Alarm, every weekday", "World Clock", "Stopwatch", "Timers",
    ]
    private static let alarmsScrolledRows = ["7:45 AM", "Gym"]
    private static let editAlarm = [
        "Cancel", "Edit Alarm", "Save", "Repeat", "Label", "Gym", "Sound", "Snooze",
    ]
    private static let worldClock = [
        "Edit", "World Clock", "Cupertino", "Today, +0HRS", "Alarms", "Stopwatch", "Timers",
    ]

    private func screen(_ index: Int, _ action: String?, _ via: String?, _ labels: [String]) -> ExploredScreen {
        ExploredScreen(
            index: index,
            elements: labels.enumerated().map {
                TapPoint(text: $0.element, tapX: 200, tapY: Double(100 + 40 * $0.offset), confidence: 0.95)
            },
            hints: [],
            actionType: action,
            arrivedVia: via,
            screenshotBase64: "")
    }

    /// Three explored paths, handed over in the order a graph walk might
    /// yield them — not slug order — to pin the emitter's own ordering. The
    /// Gym alarm row was reached by scrolling, so its tap crosses the
    /// contract preceded by a `scroll_to:`.
    private func clockFlows() -> [MirroirAppTreeEmitter.Flow] {
        var scrolledAlarms = screen(0, nil, nil, Self.alarmsViewport + Self.alarmsScrolledRows)
        scrolledAlarms.scrolledElementCount = Self.alarmsScrolledRows.count
        return [
            .init(name: "Gym Alarm", screens: [
                scrolledAlarms,
                screen(1, "tap", "Gym", Self.editAlarm),
            ]),
            .init(name: "World Clock", screens: [
                screen(0, nil, nil, Self.alarms),
                screen(1, "tap", "World Clock", Self.worldClock),
            ]),
            .init(name: "Add Alarm", screens: [
                screen(0, nil, nil, Self.alarms),
                screen(1, "tap", "Add Alarm", Self.addAlarm),
                screen(2, "tap", "Cancel", Self.alarms),
            ]),
        ]
    }

    /// One walk that makes the formatter write every verb it can emit.
    private func everyVerbWalk() -> [ExploredScreen] {
        [
            screen(0, nil, nil, Self.alarms),
            screen(1, "tap", "add alarm", Self.addAlarm),
            screen(2, "long_press", "Repeat", ["Repeat", "Never", "Every Monday", "Every Sunday"]),
            screen(3, "scroll_to", "Every Sunday", ["Every Sunday", "Every Saturday"]),
            screen(4, "assert_visible", "Every Saturday", ["Every Sunday", "Every Saturday"]),
            screen(5, "assert_not_visible", "Snooze", ["Every Sunday", "Every Saturday"]),
            screen(6, "type", "Wake up", ["Wake up"]),
            screen(7, "press_key", "return", ["Wake up"]),
            screen(8, "swipe", "up", ["Wake up"]),
            screen(9, "open_url", "https://example.com/alarms", ["example.com"]),
            screen(10, "screenshot", "alarm-sheet", ["example.com"]),
            screen(11, "press_home", nil, ["Clock", "Calendar"]),
        ]
    }

    // MARK: - Golden

    /// The emitted Clock tree is the committed fixture, file for file.
    func testEmittedClockTreeMatchesTheRunnerGolden() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent(".mirroir")

        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: clockFlows(), root: root)
        XCTAssertEqual(result.scenarioPaths.map(\.lastPathComponent),
                       ["add-alarm.ios.yaml", "gym-alarm.ios.yaml", "world-clock.ios.yaml"])

        let golden = goldenDir().appendingPathComponent(".mirroir")
        try assertTree(emitted: root, golden: golden)
    }

    /// The every-verb walk is the committed fixture, and it holds every verb
    /// the formatter can write — the runner renders each through its block writer.
    func testEveryVerbScenarioMatchesTheRunnerGolden() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "every-verb", appName: "Clock", screens: everyVerbWalk())
        let lines = yaml.components(separatedBy: "\n")
        for verb in ScenarioStepFormatter.emittedVerbs {
            XCTAssertTrue(lines.contains { $0.hasPrefix("  - \(verb):") },
                          "the every-verb walk does not emit \(verb):\n\(yaml)")
        }
        try assertFile(actual: yaml, golden: goldenDir().appendingPathComponent("every-verb.ios.yaml"))
    }

    // MARK: - Helpers

    private func goldenDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runner/tests/fixtures/emitted")
    }

    private var regenerating: Bool {
        ProcessInfo.processInfo.environment[Self.regenerateVariable] == "1"
    }

    /// Every file under `emitted` equals its twin under `golden`, and the
    /// golden tree holds no file the emitter did not write.
    private func assertTree(emitted: URL, golden: URL) throws {
        let emittedFiles = try relativeFiles(under: emitted)
        for file in emittedFiles {
            let actual = try String(contentsOf: emitted.appendingPathComponent(file), encoding: .utf8)
            try assertFile(actual: actual, golden: golden.appendingPathComponent(file))
        }
        XCTAssertEqual(try relativeFiles(under: golden), emittedFiles,
                       "the golden tree and the emitted tree hold different files")
    }

    private func assertFile(actual: String, golden: URL) throws {
        if regenerating {
            try FileManager.default.createDirectory(
                at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: golden, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: golden, encoding: .utf8)
        XCTAssertEqual(actual, expected,
                       "emitter output drifted from \(golden.path) — rerun with " +
                       "\(Self.regenerateVariable)=1 if the change is intended:\n\(actual)")
    }

    private func relativeFiles(under root: URL) throws -> [String] {
        let rootPath = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [String] = []
        for case let url as URL in walker
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = url.resolvingSymlinksInPath().path
            files.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return files.sorted()
    }
}
