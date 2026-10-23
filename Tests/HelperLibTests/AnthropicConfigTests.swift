// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the Anthropic settings: effort parsing, the warn-once sink, and the derived timeout.
// ABOUTME: Checks that a bad effort value falls back with one warning and a 16k reply fits the deadline.

import Foundation
import XCTest
@testable import HelperLib

/// Collects warnings passed to a `OnceWarner` sink. The lock guards `stored`
/// because the sink is `@Sendable`.
private final class WarningLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ message: String) {
        lock.lock()
        stored.append(message)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class AnthropicConfigTests: XCTestCase {

    // MARK: - Effort

    func testEveryLevelParsesToItself() {
        for effort in AnthropicEffort.allCases {
            var warnings: [String] = []
            XCTAssertEqual(AnthropicEffort.resolve(effort.rawValue) { warnings.append($0) }, effort)
            XCTAssertTrue(warnings.isEmpty)
        }
    }

    func testCaseAndWhitespaceAreIgnored() {
        var warnings: [String] = []
        XCTAssertEqual(AnthropicEffort.resolve(" High\n") { warnings.append($0) }, .high)
        XCTAssertEqual(AnthropicEffort.resolve("XHIGH") { warnings.append($0) }, .xhigh)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testUnsetResolvesToDefaultSilently() {
        var warnings: [String] = []
        XCTAssertEqual(AnthropicEffort.resolve("", fallback: .medium) { warnings.append($0) }, .medium)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testEnvConfigReadsEffortFromSettingsAndEnv() {
        let log = WarningLog()
        let warner = OnceWarner(sink: log.append)
        let fromSettings = EnvConfig.anthropicEffort(
            settings: ["anthropicEffort": "HIGH"], env: [:], warner: warner)
        XCTAssertEqual(fromSettings, .high)
        let fromEnv = EnvConfig.anthropicEffort(
            settings: [:], env: ["MIRROIR_ANTHROPIC_EFFORT": "HIGH"], warner: warner)
        XCTAssertEqual(fromEnv, .high)
        XCTAssertTrue(log.messages.isEmpty)
    }

    func testEnvConfigFallsBackOnBogusEffortWithOneWarning() {
        let log = WarningLog()
        let warner = OnceWarner(sink: log.append)
        for _ in 0..<2 {
            let effort = EnvConfig.anthropicEffort(
                settings: ["anthropicEffort": "bogus"], env: [:], warner: warner)
            XCTAssertEqual(effort, .low)
        }
        XCTAssertEqual(log.messages.count, 1)
        XCTAssertTrue(log.messages.first?.contains("'bogus'") ?? false)
    }

    func testEnvConfigSettingsWinOverEnvForEffort() {
        let warner = OnceWarner(sink: { _ in })
        let effort = EnvConfig.anthropicEffort(
            settings: ["anthropicEffort": "max"], env: ["MIRROIR_ANTHROPIC_EFFORT": "medium"],
            warner: warner)
        XCTAssertEqual(effort, .max)
    }

    func testUnknownValueFallsBackWithWarning() throws {
        var warnings: [String] = []
        let effort = AnthropicEffort.resolve("minimal", fallback: .medium) { warnings.append($0) }
        XCTAssertEqual(effort, .medium)
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warning.contains("'minimal'"))
        XCTAssertTrue(warning.contains("using 'medium'"))
        for level in AnthropicEffort.allCases {
            XCTAssertTrue(warning.contains(level.rawValue), "warning omits \(level)")
        }
    }

    func testOnceWarnerPrintsEachMessageOnce() {
        let log = WarningLog()
        let warner = OnceWarner(sink: log.append)
        for _ in 0..<3 {
            _ = AnthropicEffort.resolve("Lowest", warn: warner.warn)
        }
        warner.warn("another message")
        XCTAssertEqual(log.messages.count, 2)
        XCTAssertEqual(log.messages.last, "another message")
    }

    // MARK: - Timeout

    func testDefaultTimeoutFitsDefaultMaxTokens() {
        // At the SDKs' planning rate a 16000-token reply needs 450 s.
        let timeout = EnvConfig.plannedAnthropicTimeoutSeconds(
            forMaxTokens: TimingConstants.anthropicMaxTokens)
        let needed = Double(TimingConstants.anthropicMaxTokens) * 3600
            / Double(TimingConstants.anthropicPlannedOutputTokensPerHour)
        XCTAssertGreaterThanOrEqual(Double(timeout), needed)
        XCTAssertEqual(timeout, 450)
    }

    func testTimeoutGrowsWithMaxTokensWithinFloorAndCap() {
        let small = EnvConfig.plannedAnthropicTimeoutSeconds(forMaxTokens: TimingConstants.defaultAIMaxTokens)
        XCTAssertEqual(small, TimingConstants.anthropicMinTimeoutSeconds)
        XCTAssertEqual(EnvConfig.plannedAnthropicTimeoutSeconds(forMaxTokens: 19200), 540)
        // A token count that does not divide evenly rounds up, never down.
        XCTAssertEqual(EnvConfig.plannedAnthropicTimeoutSeconds(forMaxTokens: 16001), 451)
    }

    func testTimeoutIsCappedAtTheNonStreamingGuard() {
        // 32000 tokens would plan 900 s; a non-streaming connection is not held that long.
        let large = EnvConfig.plannedAnthropicTimeoutSeconds(forMaxTokens: 32000)
        XCTAssertEqual(large, TimingConstants.anthropicMaxNonStreamingSeconds)
    }
}
