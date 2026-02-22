// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Generates JUnit XML reports from test runner results.
// ABOUTME: Standard format compatible with CI systems (Jenkins, GitHub Actions, etc.).

import Foundation

/// Generates JUnit XML from skill test results.
enum JUnitReporter {

    /// Generate JUnit XML string from skill results.
    static func generateXML(results: [ConsoleReporter.SkillResult]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"

        let totalTests = results.flatMap { $0.stepResults }.count
        let totalFailures = results.flatMap { $0.stepResults }
            .filter { $0.status == .failed }.count
        let totalSkipped = results.flatMap { $0.stepResults }
            .filter { $0.status == .skipped }.count
        let totalTime = results.reduce(0.0) { $0 + $1.durationSeconds }

        xml += "<testsuites tests=\"\(totalTests)\" failures=\"\(totalFailures)\""
        xml += " skipped=\"\(totalSkipped)\""
        xml += " time=\"\(String(format: "%.3f", totalTime))\">\n"

        for result in results {
            xml += generateTestSuite(result: result)
        }

        xml += "</testsuites>\n"
        return xml
    }

    /// Generate a single testsuite element for a skill.
    private static func generateTestSuite(result: ConsoleReporter.SkillResult) -> String {
        let testCount = result.stepResults.count
        let failureCount = result.stepResults.filter { $0.status == .failed }.count
        let skippedCount = result.stepResults.filter { $0.status == .skipped }.count
        let suiteName = xmlEscape(result.name)

        var xml = "  <testsuite name=\"\(suiteName)\""
        xml += " tests=\"\(testCount)\" failures=\"\(failureCount)\""
        xml += " skipped=\"\(skippedCount)\""
        xml += " time=\"\(String(format: "%.3f", result.durationSeconds))\">\n"

        for (index, stepResult) in result.stepResults.enumerated() {
            xml += generateTestCase(stepResult: stepResult, index: index,
                                    suiteName: result.name)
        }

        xml += "  </testsuite>\n"
        return xml
    }

    /// Generate a single testcase element for a step.
    private static func generateTestCase(stepResult: StepResult, index: Int,
                                         suiteName: String) -> String {
        let testName = xmlEscape(stepResult.step.displayName)
        let className = xmlEscape(suiteName)

        var xml = "    <testcase name=\"\(testName)\" classname=\"\(className)\""
        xml += " time=\"\(String(format: "%.3f", stepResult.durationSeconds))\""

        switch stepResult.status {
        case .passed:
            xml += " />\n"
        case .failed:
            let message = xmlEscape(stepResult.message ?? "Step failed")
            xml += ">\n"
            xml += "      <failure message=\"\(message)\">\(message)</failure>\n"
            xml += "    </testcase>\n"
        case .skipped:
            let message = xmlEscape(stepResult.message ?? "Step skipped")
            xml += ">\n"
            xml += "      <skipped message=\"\(message)\" />\n"
            xml += "    </testcase>\n"
        }

        return xml
    }

    /// Write JUnit XML to a file at the given path.
    static func writeXML(results: [ConsoleReporter.SkillResult], to path: String) throws {
        let xml = generateXML(results: results)
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
        try xml.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Escape special XML characters in a string.
    static func xmlEscape(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }
}
