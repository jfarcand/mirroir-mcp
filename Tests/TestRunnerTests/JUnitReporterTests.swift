// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for JUnitReporter: XML generation, failure elements, special char escaping.
// ABOUTME: Validates output against standard JUnit XML schema expectations.

import XCTest
@testable import mirroir_mcp

final class JUnitReporterTests: XCTestCase {

    // MARK: - XML Escaping

    func testXmlEscapeAmpersand() {
        XCTAssertEqual(JUnitReporter.xmlEscape("a & b"), "a &amp; b")
    }

    func testXmlEscapeLessThan() {
        XCTAssertEqual(JUnitReporter.xmlEscape("a < b"), "a &lt; b")
    }

    func testXmlEscapeGreaterThan() {
        XCTAssertEqual(JUnitReporter.xmlEscape("a > b"), "a &gt; b")
    }

    func testXmlEscapeDoubleQuote() {
        XCTAssertEqual(JUnitReporter.xmlEscape("a \"b\" c"), "a &quot;b&quot; c")
    }

    func testXmlEscapeSingleQuote() {
        XCTAssertEqual(JUnitReporter.xmlEscape("it's"), "it&apos;s")
    }

    func testXmlEscapeMultiple() {
        XCTAssertEqual(JUnitReporter.xmlEscape("<a & \"b\">"),
                        "&lt;a &amp; &quot;b&quot;&gt;")
    }

    func testXmlEscapeNoSpecialChars() {
        XCTAssertEqual(JUnitReporter.xmlEscape("simple text"), "simple text")
    }

    // MARK: - XML Generation

    func testGenerateXMLEmpty() {
        let xml = JUnitReporter.generateXML(results: [])
        XCTAssertTrue(xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<testsuites"))
        XCTAssertTrue(xml.contains("tests=\"0\""))
        XCTAssertTrue(xml.contains("</testsuites>"))
    }

    func testGenerateXMLWithPassingSteps() {
        let stepResult = StepResult(
            step: .tap(label: "General"),
            status: .passed,
            message: nil,
            durationSeconds: 0.5
        )
        let skillResult = ConsoleReporter.SkillResult(
            name: "Check About",
            filePath: "check-about.yaml",
            stepResults: [stepResult],
            durationSeconds: 1.0
        )

        let xml = JUnitReporter.generateXML(results: [skillResult])
        XCTAssertTrue(xml.contains("tests=\"1\""))
        XCTAssertTrue(xml.contains("failures=\"0\""))
        XCTAssertTrue(xml.contains("name=\"Check About\""))
        XCTAssertTrue(xml.contains("tap: &quot;General&quot;"))
        XCTAssertTrue(xml.contains("/>"))  // self-closing testcase for passing
    }

    func testGenerateXMLWithFailedStep() {
        let stepResult = StepResult(
            step: .assertVisible(label: "Missing"),
            status: .failed,
            message: "Element not found",
            durationSeconds: 0.3
        )
        let skillResult = ConsoleReporter.SkillResult(
            name: "Failure Test",
            filePath: "test.yaml",
            stepResults: [stepResult],
            durationSeconds: 0.5
        )

        let xml = JUnitReporter.generateXML(results: [skillResult])
        XCTAssertTrue(xml.contains("failures=\"1\""))
        XCTAssertTrue(xml.contains("<failure message=\"Element not found\">"))
        XCTAssertTrue(xml.contains("</failure>"))
    }

    func testGenerateXMLWithSkippedStep() {
        let stepResult = StepResult(
            step: .skipped(stepType: "remember", reason: "AI-only"),
            status: .skipped,
            message: "remember: AI-only step",
            durationSeconds: 0.0
        )
        let skillResult = ConsoleReporter.SkillResult(
            name: "Skip Test",
            filePath: "test.yaml",
            stepResults: [stepResult],
            durationSeconds: 0.1
        )

        let xml = JUnitReporter.generateXML(results: [skillResult])
        XCTAssertTrue(xml.contains("skipped=\"1\""))
        XCTAssertTrue(xml.contains("<skipped message="))
    }

    func testGenerateXMLWithSpecialCharsInName() {
        let stepResult = StepResult(
            step: .tap(label: "A & B <test>"),
            status: .passed,
            message: nil,
            durationSeconds: 0.1
        )
        let skillResult = ConsoleReporter.SkillResult(
            name: "Test & <Special>",
            filePath: "test.yaml",
            stepResults: [stepResult],
            durationSeconds: 0.2
        )

        let xml = JUnitReporter.generateXML(results: [skillResult])
        XCTAssertTrue(xml.contains("Test &amp; &lt;Special&gt;"))
        XCTAssertTrue(xml.contains("A &amp; B &lt;test&gt;"))
    }

    func testGenerateXMLMultipleSkills() {
        let step1 = StepResult(step: .home, status: .passed,
                               message: nil, durationSeconds: 0.1)
        let step2 = StepResult(step: .shake, status: .failed,
                               message: "Shake failed", durationSeconds: 0.2)

        let skill1 = ConsoleReporter.SkillResult(
            name: "Skill 1", filePath: "s1.yaml",
            stepResults: [step1], durationSeconds: 0.3)
        let skill2 = ConsoleReporter.SkillResult(
            name: "Skill 2", filePath: "s2.yaml",
            stepResults: [step2], durationSeconds: 0.4)

        let xml = JUnitReporter.generateXML(results: [skill1, skill2])
        XCTAssertTrue(xml.contains("tests=\"2\""))
        XCTAssertTrue(xml.contains("failures=\"1\""))
        // Two testsuite elements
        let suiteCount = xml.components(separatedBy: "<testsuite ").count - 1
        XCTAssertEqual(suiteCount, 2)
    }

    // MARK: - File Writing

    func testWriteXMLToFile() throws {
        let tmpDir = NSTemporaryDirectory() + "junit-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let path = tmpDir + "/results.xml"
        let stepResult = StepResult(step: .home, status: .passed,
                                    message: nil, durationSeconds: 0.1)
        let skillResult = ConsoleReporter.SkillResult(
            name: "Test", filePath: "test.yaml",
            stepResults: [stepResult], durationSeconds: 0.2)

        try JUnitReporter.writeXML(results: [skillResult], to: path)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("<?xml"))
        XCTAssertTrue(content.contains("<testsuites"))
    }
}
