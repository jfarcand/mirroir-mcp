// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AppMdSchemaVersion — the APP.md major gate and minor tolerance.
// ABOUTME: Mirrors the runner's version seam: other majors refused, newer minors parsed, floats rejected.

import XCTest
@testable import mirroir_mcp

final class AppMdSchemaVersionTests: XCTestCase {

    func testIntegerIsMajorWithMinorZero() {
        XCTAssertEqual(AppMdSchemaVersion.parse("1"), .init(major: 1, minor: 0))
        XCTAssertEqual(AppMdSchemaVersion.gate("1"), .supported(major: 1))
    }

    func testQuotedStringCarriesMinor() {
        XCTAssertEqual(AppMdSchemaVersion.parse("\"1.3\""), .init(major: 1, minor: 3))
        XCTAssertEqual(AppMdSchemaVersion.parse("'1.0'"), .init(major: 1, minor: 0))
        XCTAssertEqual(AppMdSchemaVersion.gate("\"1.0\""), .supported(major: 1))
    }

    func testFloatAndMalformedValuesAreRefused() {
        for raw in ["1.2", "x", "\"1.\"", "\".1\"", "\"1.2.3\"", "-1", ""] {
            XCTAssertNil(AppMdSchemaVersion.parse(raw), "\(raw) should not parse")
            guard case .rejected = AppMdSchemaVersion.gate(raw) else {
                return XCTFail("\(raw) should be rejected")
            }
        }
    }

    func testOtherMajorsAreRejected() {
        for raw in ["0", "2", "\"2.1\""] {
            guard case .rejected = AppMdSchemaVersion.gate(raw) else {
                return XCTFail("\(raw) should be rejected")
            }
        }
    }

    func testNewerMinorIsTolerated() {
        XCTAssertEqual(AppMdSchemaVersion.gate("\"1.1\""), .newerMinor(major: 1, minor: 1))
    }

    func testAbsentVersionIsRejected() {
        guard case .rejected(let reason) = AppMdSchemaVersion.gate(nil) else {
            return XCTFail("an absent version: should be rejected")
        }
        XCTAssertTrue(reason.contains("no version:"), reason)
    }

    private func appMd(version: String) -> String {
        """
        ---
        version: \(version)
        app: Gate
        ---

        # Gate

        ## Structure

        One screen.
        """
    }

    func testParserRefusesAnAppMdWithoutVersion() {
        let content = """
        ---
        app: Gate
        ---

        # Gate

        ## Structure

        One screen.
        """
        XCTAssertNil(AppDescriptionParser.parse(content: content))
    }

    /// The front-matter line exactly as docs/APP.md.spec.md shows it.
    func testParserAcceptsTheSpecExampleWithAnInlineComment() {
        let desc = AppDescriptionParser.parse(
            content: appMd(version: "1             # required — schema major; a different major is refused"))
        XCTAssertEqual(desc?.appName, "Gate")
        XCTAssertEqual(desc?.schemaVersion, 1)
    }

    func testParserRefusesADifferentMajor() {
        XCTAssertNil(AppDescriptionParser.parse(content: appMd(version: "2")))
    }

    /// An APP.md that names the app but has no `version:` is not used, and
    /// the lookup carries the file and reason a tool result reports.
    func testTheLoaderReportsARefusedAppMdForTheApp() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-appmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gate"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unversioned = appMd(version: "1").replacingOccurrences(of: "version: 1\n", with: "")
        let path = dir.appendingPathComponent("gate/APP.md")
        try unversioned.write(to: path, atomically: true, encoding: .utf8)

        let lookup = AppDescriptionLoader.load(appName: "gate", searchPaths: [dir.path])
        XCTAssertNil(lookup.description)
        XCTAssertEqual(lookup.refused.map(\.path), [dir.path + "/gate/APP.md"])
        let note = try XCTUnwrap(lookup.refusalNote)
        XCTAssertTrue(note.hasPrefix("APP.md refused — this run used no APP.md"), note)
        XCTAssertTrue(note.contains("gate/APP.md: no version: front-matter field"), note)

        XCTAssertNil(AppDescriptionLoader.load(appName: "Other", searchPaths: [dir.path]).refusalNote,
                     "an APP.md naming another app is not this app's refusal")

        let reported = ExplorationLoopRunner.appendingNote(note, to: .error("emit failed"))
        XCTAssertTrue(reported.isError)
        guard case .text(let text) = reported.content.first else {
            return XCTFail("expected a text block")
        }
        XCTAssertEqual(text, "emit failed\n\n---\n" + note)
    }

    func testParserParsesANewerMinor() {
        let desc = AppDescriptionParser.parse(content: appMd(version: "\"1.4\""))
        XCTAssertEqual(desc?.appName, "Gate")
        XCTAssertEqual(desc?.schemaVersion, 1)
    }
}
