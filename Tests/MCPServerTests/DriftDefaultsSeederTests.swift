// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the emit's .mirroir/drift-defaults.yaml seeding — copy when absent, keep when present.
// ABOUTME: With no mirroir-skills copy anywhere the emit is refused before writing, never with invented values.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class DriftDefaultsSeederTests: XCTestCase {

    /// A skills-repo layer the tests write themselves, so each case controls
    /// exactly which candidate exists.
    private static let skillsLayer = "version: 1\nfingerprint_similarity: { min: 0.85 }\n"

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-drift-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    private var root: URL { scratch.appendingPathComponent("consumer/.mirroir") }

    private var layer: URL { root.appendingPathComponent(DriftDefaultsSeeder.fileName) }

    /// Write a skills copy under `skills/<name>/` and return its path.
    private func skillsCopy(_ name: String, body: String = skillsLayer) throws -> String {
        let dir = scratch.appendingPathComponent("skills/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(DriftDefaultsSeeder.fileName)
        try body.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func flows() -> [MirroirAppTreeEmitter.Flow] {
        let labels = ["Alarms", "Add Alarm", "World Clock"]
        let screens = [
            ExploredScreen(
                index: 0,
                elements: labels.enumerated().map {
                    TapPoint(text: $0.element, tapX: 200, tapY: Double(100 + 40 * $0.offset), confidence: 0.95)
                },
                hints: [], actionType: nil, arrivedVia: nil, screenshotBase64: ""),
            ExploredScreen(
                index: 1,
                elements: [TapPoint(text: "Cancel", tapX: 200, tapY: 100, confidence: 0.95)],
                hints: [], actionType: "tap", arrivedVia: "Add Alarm", screenshotBase64: ""),
        ]
        return [.init(name: "Add Alarm", screens: screens)]
    }

    /// A tree with no layer gets the first existing skills copy, byte for byte;
    /// a missing earlier candidate is passed over.
    func testEmitCopiesTheSkillsLayerWhenTheTreeHasNone() throws {
        let missing = scratch.appendingPathComponent("skills/absent/\(DriftDefaultsSeeder.fileName)").path
        let first = try skillsCopy("first")
        _ = try skillsCopy("second", body: "version: 1\njudge_score_swing: { max_delta: 0.5 }\n")

        let result = try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: flows(), root: root,
            driftDefaultsCandidates: [missing, first, scratch.appendingPathComponent(
                "skills/second/\(DriftDefaultsSeeder.fileName)").path])

        XCTAssertEqual(try String(contentsOf: layer, encoding: .utf8), Self.skillsLayer)
        XCTAssertEqual(result.driftDefaultsNote, "created \(DriftDefaultsSeeder.fileName) from \(first)")
    }

    /// An existing layer is the consumer's: a later emit never rewrites it.
    func testEmitKeepsAnExistingLayer() throws {
        let owned = "version: 1\nfingerprint_similarity: { min: 0.95 }\n"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try owned.write(to: layer, atomically: true, encoding: .utf8)

        let result = try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: flows(), root: root,
            driftDefaultsCandidates: [try skillsCopy("repo")])

        XCTAssertEqual(try String(contentsOf: layer, encoding: .utf8), owned)
        XCTAssertEqual(result.driftDefaultsNote, "kept existing \(DriftDefaultsSeeder.fileName)")
    }

    /// An existing layer is kept even when no skills copy exists to seed from.
    func testEmitKeepsAnExistingLayerWithoutASkillsCopy() throws {
        let owned = "version: 1\nfingerprint_similarity: { min: 0.95 }\n"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try owned.write(to: layer, atomically: true, encoding: .utf8)

        let result = try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: flows(), root: root, driftDefaultsCandidates: [])

        XCTAssertEqual(result.driftDefaultsNote, "kept existing \(DriftDefaultsSeeder.fileName)")
    }

    /// No layer in the tree and no skills copy at any candidate: the emit is
    /// refused naming every path searched, and nothing is written.
    func testEmitErrorsWhenNoSkillsCopyExists() throws {
        let searched = [
            scratch.appendingPathComponent("skills/one/\(DriftDefaultsSeeder.fileName)").path,
            scratch.appendingPathComponent("skills/two/\(DriftDefaultsSeeder.fileName)").path,
        ]

        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(
            appName: "Clock", flows: flows(), root: root, driftDefaultsCandidates: searched)
        ) { error in
            XCTAssertEqual(error as? MirroirAppTreeEmitter.EmitError,
                           .driftDefaultsMissing(searched: searched))
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            for path in searched {
                XCTAssertTrue(message.contains(path), "the refusal omits \(path): \(message)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "a refused emit must leave the tree untouched")
    }
}
