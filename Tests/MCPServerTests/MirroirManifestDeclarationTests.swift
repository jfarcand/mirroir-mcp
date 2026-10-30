// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests what counts as a declared flow or plan entry when the emitter extends a manifest.
// ABOUTME: Comments, prose and unread keys do not declare; nice_to_pass is noted; a double failure names both.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class MirroirManifestDeclarationTests: XCTestCase {

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

    private var flows: [MirroirAppTreeEmitter.Flow] {
        [.init(name: "alpha", screens: walk("Alarm")), .init(name: "beta", screens: walk("Timer"))]
    }

    /// A temporary `.mirroir/` whose `apps/clock/SAMPLE.md` is `sample`.
    private func root(sample: String) throws -> (root: URL, samplePath: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-declared-\(UUID().uuidString)")
        let root = base.appendingPathComponent(".mirroir")
        let appDir = root.appendingPathComponent("apps/clock")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let samplePath = appDir.appendingPathComponent("SAMPLE.md")
        try sample.write(to: samplePath, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, samplePath)
    }

    /// An owned SAMPLE.md with `prose` before the fenced block and `tiers`
    /// as the body of `session.scenarios`.
    private func ownedSample(prose: String = "", tiers: String) -> String {
        MirroirManifestUpsert.sampleOwnershipMarker + "\n# Clock\n\n" + prose +
            "\n```yaml\nversion: 1\nsession:\n  boot:\n    command: \"true\"\n  scenarios:\n" +
            tiers + "```\n"
    }

    private let alphaOnly = "    must_pass:\n      - scenarios/alpha.ios.yaml\n"

    // MARK: - SAMPLE.md

    /// The entry lands after the last item; the comment, at the items' own
    /// indentation, belongs to no item and stays below it.
    func testACommentedOutEntryDoesNotDeclareTheFlow() throws {
        let comment = "      # - scenarios/beta.ios.yaml\n"
        let tiers = alphaOnly + comment
        let (root, samplePath) = try root(sample: ownedSample(tiers: tiers))

        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: flows, root: root)

        XCTAssertEqual(result.sampleNote, "added scenarios/beta.ios.yaml to SAMPLE.md must_pass")
        XCTAssertEqual(
            try String(contentsOf: samplePath, encoding: .utf8),
            ownedSample(tiers: alphaOnly + "      - scenarios/beta.ios.yaml\n" + comment))
    }

    func testAProseMentionDoesNotDeclareTheFlow() throws {
        let prose = "The timer flow lives in `scenarios/beta.ios.yaml`.\n"
        let (root, samplePath) = try root(sample: ownedSample(prose: prose, tiers: alphaOnly))

        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: flows, root: root)

        XCTAssertEqual(result.sampleNote, "added scenarios/beta.ios.yaml to SAMPLE.md must_pass")
        XCTAssertEqual(
            try String(contentsOf: samplePath, encoding: .utf8),
            ownedSample(prose: prose, tiers: alphaOnly + "      - scenarios/beta.ios.yaml\n"))
    }

    /// `nice_to_pass` is a tier mirroir-run replays, so a flow there is
    /// declared and left where it is — and the note says it gates nothing.
    func testAFlowOnlyInNiceToPassIsDeclaredAndNoted() throws {
        let tiers = alphaOnly + "    nice_to_pass:\n      - scenarios/beta.ios.yaml\n"
        let sample = ownedSample(tiers: tiers)
        let (root, samplePath) = try root(sample: sample)

        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: flows, root: root)

        XCTAssertEqual(
            result.sampleNote,
            "scenarios/alpha.ios.yaml, scenarios/beta.ios.yaml already declared in SAMPLE.md\n" +
                "SAMPLE.md declares scenarios/beta.ios.yaml under nice_to_pass only, so a FAIL " +
                "there does not fail the sample; move them to must_pass to gate on them")
        XCTAssertEqual(try String(contentsOf: samplePath, encoding: .utf8), sample)
    }

    /// `should_pass` is not a SAMPLE.md key (mirroir-run refuses the file over it),
    /// so a flow listed only there is not declared: it is added to must_pass.
    func testAFlowOnlyUnderAnUnreadKeyIsAddedToMustPass() throws {
        let tiers = "    should_pass:\n      - scenarios/beta.ios.yaml\n" + alphaOnly
        let (root, samplePath) = try root(sample: ownedSample(tiers: tiers))

        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: flows, root: root)

        XCTAssertEqual(result.sampleNote, "added scenarios/beta.ios.yaml to SAMPLE.md must_pass")
        XCTAssertEqual(
            try String(contentsOf: samplePath, encoding: .utf8),
            ownedSample(tiers: tiers + "      - scenarios/beta.ios.yaml\n"))
    }

    // MARK: - Plan

    func testACommentedOutPlanEntryDoesNotCountAsPresent() throws {
        let (root, _) = try root(sample: ownedSample(tiers: alphaOnly))
        let planPath = root.appendingPathComponent("mirroir.yaml")
        let head = MirroirManifestUpsert.planOwnershipMarker + "\nversion: 1\nplan:\n" +
            "  must_pass:\n    - name: web\n      local: apps/web\n"
        let plan = head + "    # - name: clock\n"
        try plan.write(to: planPath, atomically: true, encoding: .utf8)

        let result = try MirroirAppTreeEmitter.emit(appName: "Clock", flows: flows, root: root)

        XCTAssertEqual(result.planNote, "added plan entry 'clock' to .mirroir/mirroir.yaml")
        XCTAssertEqual(
            try String(contentsOf: planPath, encoding: .utf8),
            head + "    - name: clock\n      local: apps/clock\n      boot:\n        command: \"true\"\n" +
                "    # - name: clock\n")
    }

    /// A human SAMPLE.md missing a flow and an ambiguous owned plan: the one
    /// error names both, with the plan entry to paste.
    func testWhenSampleAndPlanBothFailTheErrorCarriesThePlanSnippet() throws {
        let human = ownedSample(tiers: alphaOnly)
            .replacingOccurrences(of: MirroirManifestUpsert.sampleOwnershipMarker + "\n", with: "")
        let (root, samplePath) = try root(sample: human)
        let planPath = root.appendingPathComponent("mirroir.yaml")
        let plan = MirroirManifestUpsert.planOwnershipMarker + "\nversion: 1\n" +
            "plan:\n  must_pass:\n    - name: web\n" + "plan:\n  must_pass:\n    - name: api\n"
        try plan.write(to: planPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(appName: "Clock", flows: flows, root: root)) {
            error in
            guard case .undeclaredFlows(_, let undeclared, _, _, _, let planError) =
                    error as? MirroirAppTreeEmitter.EmitError else {
                return XCTFail("expected undeclaredFlows, got \(error)")
            }
            XCTAssertEqual(undeclared, ["scenarios/beta.ios.yaml"])
            let unplaced = MirroirAppTreeEmitter.EmitError.unplacedPlanEntry(
                plan: planPath.path, slug: "clock",
                snippet: "    - name: clock\n      local: apps/clock\n      boot:\n        command: \"true\"")
            XCTAssertEqual(planError, unplaced.errorDescription)
            XCTAssertTrue(error.localizedDescription.hasSuffix(
                "\nthe plan was not updated either: " + (unplaced.errorDescription ?? "")),
                error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: samplePath, encoding: .utf8), human)
        XCTAssertEqual(try String(contentsOf: planPath, encoding: .utf8), plan)
    }
}
