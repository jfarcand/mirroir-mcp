// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that later emits extend the SAMPLE.md and mirroir.yaml the emitter owns, and never a human's.
// ABOUTME: Covers in-place inserts that keep web-leg edits, the plan, a marker-free SAMPLE.md, and dropped flows.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class MirroirManifestUpsertTests: XCTestCase {

    private func point(_ text: String, y: Double = 100) -> TapPoint {
        TapPoint(text: text, tapX: 100, tapY: y, confidence: 0.95)
    }

    private func walk(_ via: String) -> [ExploredScreen] {
        [
            ExploredScreen(index: 0, elements: [point("Start"), point(via, y: 200)], hints: [],
                           actionType: nil, arrivedVia: nil, screenshotBase64: ""),
            ExploredScreen(index: 1, elements: [point("Arrived \(via)")], hints: [],
                           actionType: "tap", arrivedVia: via, screenshotBase64: ""),
        ]
    }

    private func tmpBase() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func text(_ result: MCPToolResult) -> String {
        result.content.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }

    /// The manifest-declared flows, as mirroir-run's SAMPLE.md loader sees
    /// them: only the fenced yaml block, which the marker sits outside of.
    private func mustPass(_ sample: String) -> [String] {
        guard let block = sample.components(separatedBy: "```yaml\n").dropFirst().first?
            .components(separatedBy: "```").first else { return [] }
        return block.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
    }

    /// Two goals in one session, each finished with emit: true: both
    /// succeed, and the SAMPLE.md the first created declares both flows.
    func testTwoGoalsInOneSessionBothEmitAndBothAreDeclared() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let session = ExplorationSession()
        session.start(appName: "Clock", goal: "", goals: ["add alarm", "open timer"])

        for via in ["Add Alarm", "Timer"] {
            for screen in walk(via) {
                _ = session.capture(
                    elements: screen.elements, hints: [], actionType: screen.actionType,
                    arrivedVia: screen.arrivedVia, screenshotBase64: "")
            }
            let result = MirroirMCP.handleFinish(session: session, emit: true, outputDir: base.path)
            XCTAssertFalse(result.isError, text(result))
        }

        let sample = try String(contentsOf: base.appendingPathComponent(
            ".mirroir/apps/clock/SAMPLE.md"), encoding: .utf8)
        XCTAssertTrue(sample.hasPrefix(MirroirManifestUpsert.sampleOwnershipMarker + "\n"), sample)
        XCTAssertEqual(mustPass(sample),
                       ["scenarios/add-alarm.ios.yaml", "scenarios/open-timer.ios.yaml"], sample)
    }

    /// Re-running explore into the same tree with a path slug not seen before
    /// succeeds, keeps what SAMPLE.md declared, and adds no duplicate.
    func testAReEmitWithANewFlowExtendsTheOwnedSample() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".mirroir")
        _ = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("Alarm")),
        ], root: root)
        let again = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("Alarm")),
            .init(name: "beta", screens: walk("Timer")),
        ], root: root)
        XCTAssertEqual(again.sampleNote, "added scenarios/beta.ios.yaml to SAMPLE.md must_pass")
        let sample = try String(contentsOf: again.appDir.appendingPathComponent("SAMPLE.md"),
                                encoding: .utf8)
        XCTAssertEqual(mustPass(sample),
                       ["scenarios/alpha.ios.yaml", "scenarios/beta.ios.yaml"], sample)
    }

    /// A SAMPLE.md without the marker is a human's: never rewritten, and an
    /// undeclared flow is an error carrying the exact lines to paste.
    func testAMarkerFreeSampleIsNeverRewritten() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".mirroir")
        let first = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("Alarm")),
        ], root: root)
        let samplePath = first.appDir.appendingPathComponent("SAMPLE.md")
        let human = try String(contentsOf: samplePath, encoding: .utf8)
            .replacingOccurrences(of: MirroirManifestUpsert.sampleOwnershipMarker + "\n", with: "")
        try human.write(to: samplePath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "beta", screens: walk("Timer")),
        ], root: root)) { error in
            XCTAssertEqual(error as? MirroirAppTreeEmitter.EmitError, .undeclaredFlows(
                sample: samplePath.path, undeclared: ["scenarios/beta.ios.yaml"],
                snippet: "      - scenarios/beta.ios.yaml",
                stale: ["scenarios/alpha.ios.yaml"], dropped: [], planError: nil))
        }
        XCTAssertEqual(try String(contentsOf: samplePath, encoding: .utf8), human)
    }

    /// A second app joins the plan the emitter created; a human-owned plan
    /// gets the entry to paste and is left as it was.
    func testASecondAppJoinsTheOwnedPlanOnly() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".mirroir")
        let planPath = root.appendingPathComponent("mirroir.yaml")
        _ = try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: [.init(name: "a", screens: walk("Alarm"))], root: root)
        let second = try MirroirAppTreeEmitter.emit(
            appName: "Clock 2", flows: [.init(name: "a", screens: walk("Alarm"))], root: root)
        XCTAssertEqual(second.planNote, "added plan entry 'clock-2' to .mirroir/mirroir.yaml")
        let plan = try String(contentsOf: planPath, encoding: .utf8)
        XCTAssertTrue(plan.contains("    - name: clock\n      local: apps/clock\n"), plan)
        XCTAssertTrue(plan.hasSuffix("    - name: clock-2\n      local: apps/clock-2\n" +
                                     "      boot:\n        command: \"true\"\n"), plan)
        let clock = try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: [.init(name: "a", screens: walk("Alarm"))], root: root)
        XCTAssertEqual(clock.planNote, "plan entry 'clock' already present in mirroir.yaml",
                       "'clock-2' must not count as the 'clock' entry")

        let human = plan.replacingOccurrences(
            of: MirroirManifestUpsert.planOwnershipMarker + "\n", with: "")
        try human.write(to: planPath, atomically: true, encoding: .utf8)
        let third = try MirroirAppTreeEmitter.emit(
            appName: "Timer", flows: [.init(name: "a", screens: walk("Alarm"))], root: root)
        XCTAssertTrue(third.planNote.hasPrefix(
            "add this entry to .mirroir/mirroir.yaml under plan.must_pass:\n    - name: timer"),
            third.planNote)
        XCTAssertEqual(try String(contentsOf: planPath, encoding: .utf8), human)
    }

    // MARK: - In-place inserts

    /// An owned SAMPLE.md the web leg filled in: a real boot, nice_to_pass,
    /// a renamed title, prose and comments.
    private static let customizedSample = """
        \(MirroirManifestUpsert.sampleOwnershipMarker)
        # Clock and web

        Hand-written description the web leg added.

        ```yaml
        version: 1
        name: clock-web
        description: "web + ios"
        session:
          boot:
            command: "npm run dev"
            cwd: ../web
            ports: [5173, 8080]
            timeout_seconds: 90
          scenarios:
            must_pass:
              # iOS flows first
              - scenarios/alpha.ios.yaml
              - scenarios/login.web.yaml
            nice_to_pass:
              - scenarios/flaky.web.yaml
        ```

        Trailing notes.

        """

    /// A new flow lands at the end of session.scenarios.must_pass, and every
    /// other byte of the customized SAMPLE.md is kept.
    func testAnInsertKeepsACustomizedSampleByteForByte() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".mirroir")
        let appDir = root.appendingPathComponent("apps/clock")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let samplePath = appDir.appendingPathComponent("SAMPLE.md")
        try Self.customizedSample.write(to: samplePath, atomically: true, encoding: .utf8)

        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("Alarm")),
            .init(name: "beta", screens: walk("Timer")),
            .init(name: "gamma", screens: walk("Stopwatch")),
        ], root: root)

        XCTAssertEqual(result.sampleNote,
                       "added scenarios/beta.ios.yaml, scenarios/gamma.ios.yaml to SAMPLE.md must_pass")
        let expected = Self.customizedSample.replacingOccurrences(
            of: "      - scenarios/login.web.yaml\n",
            with: "      - scenarios/login.web.yaml\n      - scenarios/beta.ios.yaml\n" +
                "      - scenarios/gamma.ios.yaml\n")
        XCTAssertEqual(try String(contentsOf: samplePath, encoding: .utf8), expected)
    }

    /// An owned SAMPLE.md whose must_pass is not a block list the emitter can
    /// locate is never guessed at: the emit fails with the lines to paste.
    func testAnOwnedSampleWithoutALocatableListFailsWithTheSnippet() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".mirroir")
        let appDir = root.appendingPathComponent("apps/clock")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let samplePath = appDir.appendingPathComponent("SAMPLE.md")
        let flowStyle = Self.customizedSample.replacingOccurrences(
            of: "    must_pass:\n      # iOS flows first\n      - scenarios/alpha.ios.yaml\n" +
                "      - scenarios/login.web.yaml\n",
            with: "    must_pass: [scenarios/alpha.ios.yaml, scenarios/login.web.yaml]\n")
        XCTAssertNotEqual(flowStyle, Self.customizedSample)
        try flowStyle.write(to: samplePath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("Alarm")),
            .init(name: "beta", screens: walk("Timer")),
        ], root: root)) { error in
            XCTAssertEqual(error as? MirroirAppTreeEmitter.EmitError, .undeclaredFlows(
                sample: samplePath.path, undeclared: ["scenarios/beta.ios.yaml"],
                snippet: "      - scenarios/beta.ios.yaml", stale: [], dropped: [], planError: nil))
        }
        XCTAssertEqual(try String(contentsOf: samplePath, encoding: .utf8), flowStyle)
    }

    /// A plan entry is inserted into plan.must_pass, not appended at EOF,
    /// when keys follow the list; the rest of the file is kept.
    func testAPlanEntryIsInsertedIntoMustPassBeforeLaterKeys() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".mirroir")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let planPath = root.appendingPathComponent("mirroir.yaml")
        let tail = "  nice_to_pass:\n    - name: docs\n      local: apps/docs\n" +
            "env:\n  API_URL: http://localhost:8080 # local\n"
        let owned = MirroirManifestUpsert.planOwnershipMarker + "\nversion: 1\nplan:\n" +
            "  must_pass:\n    - name: web\n      local: apps/web\n      boot:\n" +
            "        command: \"npm start\"\n" + tail
        try owned.write(to: planPath, atomically: true, encoding: .utf8)

        let result = try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: [.init(name: "a", screens: walk("Alarm"))], root: root)

        XCTAssertEqual(result.planNote, "added plan entry 'clock' to .mirroir/mirroir.yaml")
        let expected = owned.replacingOccurrences(
            of: tail,
            with: "    - name: clock\n      local: apps/clock\n      boot:\n" +
                "        command: \"true\"\n" + tail)
        XCTAssertEqual(try String(contentsOf: planPath, encoding: .utf8), expected)
    }

    /// An owned plan with two `plan:` blocks is ambiguous: the emit fails with
    /// the entry to paste, SAMPLE.md is still brought current, and the plan
    /// is left as it was.
    func testAnAmbiguousOwnedPlanFailsWithTheEntryToPaste() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".mirroir")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let planPath = root.appendingPathComponent("mirroir.yaml")
        let owned = MirroirManifestUpsert.planOwnershipMarker + "\nversion: 1\n" +
            "plan:\n  must_pass:\n    - name: web\n      local: apps/web\n" +
            "plan:\n  must_pass:\n    - name: api\n      local: apps/api\n"
        try owned.write(to: planPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: [.init(name: "a", screens: walk("Alarm"))], root: root
        )) { error in
            guard case .unplacedPlanEntry(let plan, let slug, let snippet) =
                    error as? MirroirAppTreeEmitter.EmitError else {
                return XCTFail("expected unplacedPlanEntry, got \(error)")
            }
            XCTAssertEqual(plan, planPath.path)
            XCTAssertEqual(slug, "clock")
            XCTAssertTrue(snippet.hasPrefix("    - name: clock\n      local: apps/clock"), snippet)
        }
        XCTAssertEqual(try String(contentsOf: planPath, encoding: .utf8), owned)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("apps/clock/SAMPLE.md").path))
    }

    // MARK: - Dropped flows

    /// A human-owned SAMPLE.md failing the emit still reports the flows the
    /// emit dropped as unreplayable, and why.
    func testAHumanSampleFailureAlsoListsTheDroppedFlows() throws {
        let base = try tmpBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(".mirroir")
        let first = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("Alarm")),
        ], root: root)
        let samplePath = first.appDir.appendingPathComponent("SAMPLE.md")
        let human = try String(contentsOf: samplePath, encoding: .utf8)
            .replacingOccurrences(of: MirroirManifestUpsert.sampleOwnershipMarker + "\n", with: "")
        try human.write(to: samplePath, atomically: true, encoding: .utf8)
        var aiOnly = walk("Timer")
        aiOnly[1] = ExploredScreen(index: 1, elements: [point("Noted")], hints: [],
                                   actionType: "remember", arrivedVia: "note",
                                   screenshotBase64: "")

        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(appName: "Clock", flows: [
            .init(name: "alpha", screens: walk("Alarm")),
            .init(name: "beta", screens: walk("Timer")),
            .init(name: "noted", screens: aiOnly),
        ], root: root)) { error in
            guard case .undeclaredFlows(_, let undeclared, _, _, let dropped, _) =
                    error as? MirroirAppTreeEmitter.EmitError else {
                return XCTFail("expected undeclaredFlows, got \(error)")
            }
            XCTAssertEqual(undeclared, ["scenarios/beta.ios.yaml"])
            XCTAssertEqual(dropped.map(\.flow), ["noted"])
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(
                "also dropped (a step no replay can perform; no scenario written):\n    noted: "),
                message)
            XCTAssertTrue(message.contains("\"remember\" is an AI-only step"), message)
        }
    }
}
