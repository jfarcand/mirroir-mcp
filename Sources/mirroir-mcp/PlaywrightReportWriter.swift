// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Renders `mirroir test` results as a Playwright JSON-reporter document.
// ABOUTME: mirroir-run ingests this one shape for both surfaces, so an iOS block reports like a web block.

import Foundation

/// Writes skill results in the Playwright JSON-reporter shape.
///
/// mirroir-run already reads Playwright's JSON reporter for its web leg —
/// per-test status, the failure message, and a base64 `mirroir-captures`
/// attachment. Writing the iOS leg in that same shape gives the runner one
/// ingest path and one contract for both surfaces. Each skill is one suite
/// holding one spec with one test and one result, mirroring how a compiled
/// scenario reports.
enum PlaywrightReportWriter {

    /// Attachment name mirroir-run reads captures from. The Rust side of this
    /// contract is `compile::report::CAPTURES_ATTACHMENT`.
    static let capturesAttachment = "mirroir-captures"

    /// Build the report document.
    ///
    /// - Parameters:
    ///   - results: one entry per skill, in run order.
    ///   - screenCaptures: final-screen OCR text per skill index, recorded
    ///     when the run was asked to capture.
    ///   - captureKey: the `cross_surface` key each capture is attached under.
    static func document(
        results: [ConsoleReporter.SkillResult],
        screenCaptures: [Int: String],
        captureKey: String?
    ) throws -> Data {
        let suites = try results.enumerated().map { index, result in
            try suite(for: result, capture: captureKey.flatMap { key in
                screenCaptures[index].map { (key, $0) }
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Report(suites: suites))
    }

    /// Write the report document to `path`, creating its directory.
    static func write(
        results: [ConsoleReporter.SkillResult],
        screenCaptures: [Int: String],
        captureKey: String?,
        to path: String
    ) throws {
        let data = try document(
            results: results, screenCaptures: screenCaptures, captureKey: captureKey)
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Private

    private static func suite(
        for result: ConsoleReporter.SkillResult,
        capture: (key: String, text: String)?
    ) throws -> Suite {
        let captures = Captures(
            metrics: measureMetrics(in: result),
            crossSurface: capture.map { [$0.key: $0.text] } ?? [:])
        let inner = JSONEncoder()
        inner.outputFormatting = [.sortedKeys]
        let body = try inner.encode(captures).base64EncodedString()
        let passed = result.passed
        let error = passed ? nil : Message(message: result.failureReasons.joined(separator: "\n"))
        let run = TestResult(
            status: passed ? "passed" : "failed",
            duration: Int((result.durationSeconds * 1000).rounded()),
            error: error,
            errors: error.map { [$0] } ?? [],
            attachments: [Attachment(
                name: capturesAttachment, contentType: "application/json", body: body)])
        let test = Test(
            projectName: "ios", status: passed ? "expected" : "unexpected", results: [run])
        let spec = Spec(title: result.name, ok: passed, tests: [test])
        return Suite(title: result.filePath, file: result.filePath, specs: [spec])
    }

    /// `measure:` latencies in milliseconds, keyed by measure name — the same
    /// map a web block's captures carry.
    private static func measureMetrics(in result: ConsoleReporter.SkillResult) -> [String: Double] {
        var metrics: [String: Double] = [:]
        for step in result.stepResults where step.status == .passed {
            if case .measure(let name, _, _, _) = step.step {
                metrics[name] = step.durationSeconds * 1000
            }
        }
        return metrics
    }

    // MARK: - Reporter shapes

    private struct Report: Encodable {
        let suites: [Suite]
    }

    private struct Suite: Encodable {
        let title: String
        let file: String
        let specs: [Spec]
    }

    private struct Spec: Encodable {
        let title: String
        let ok: Bool
        let tests: [Test]
    }

    private struct Test: Encodable {
        let projectName: String
        let status: String
        let results: [TestResult]
    }

    private struct TestResult: Encodable {
        let status: String
        let duration: Int
        let error: Message?
        let errors: [Message]
        let attachments: [Attachment]
    }

    private struct Message: Encodable {
        let message: String
    }

    private struct Attachment: Encodable {
        let name: String
        let contentType: String
        let body: String
    }

    private struct Captures: Encodable {
        let metrics: [String: Double]
        let crossSurface: [String: String]

        enum CodingKeys: String, CodingKey {
            case metrics
            case crossSurface = "cross_surface"
        }
    }
}
