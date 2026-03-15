// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for CoverageMonitor: phase detection, discovery tracking, plateau/exhaustion.
// ABOUTME: Verifies the session accumulator lifecycle and rolling rate computation.

import XCTest
@testable import mirroir_mcp

final class CoverageMonitorTests: XCTestCase {

    // MARK: - Phase Detection

    func testInitialPhaseIsPlateau() {
        // No discoveries in the window → rate is 0 → below plateau threshold
        let monitor = CoverageMonitor()
        monitor.start()
        XCTAssertEqual(monitor.currentPhase, .plateau)
    }

    func testDiscoveryPhaseWhenRateAboveThreshold() {
        let monitor = CoverageMonitor()
        monitor.start()
        // Record enough discoveries to exceed 0.5 screens/minute in 120s window
        // Need > 1 discovery (0.5 * 2 minutes = 1 screen)
        monitor.recordDiscovery()
        monitor.recordDiscovery()
        XCTAssertEqual(monitor.currentPhase, .discovery)
    }

    func testPlateauPhaseWhenNoDiscoveries() {
        let monitor = CoverageMonitor()
        monitor.start()
        XCTAssertEqual(monitor.currentPhase, .plateau)
        XCTAssertNotNil(monitor.plateauStartTime,
            "Plateau start time should be set on first plateau detection")
    }

    func testExhaustionAfterLongPlateau() {
        let monitor = CoverageMonitor()
        monitor.start()
        // Trigger plateau detection to set plateauStartTime
        _ = monitor.currentPhase
        // Inject a plateau start time in the distant past
        monitor.plateauStartTime = Date().addingTimeInterval(
            -(CoverageMonitor.exhaustionTimeoutSeconds + 10)
        )
        XCTAssertEqual(monitor.currentPhase, .exhaustion)
    }

    func testDiscoveryResetsPlateauTimer() {
        let monitor = CoverageMonitor()
        monitor.start()
        // Enter plateau
        _ = monitor.currentPhase
        XCTAssertNotNil(monitor.plateauStartTime)

        // Record enough discoveries to exit plateau
        monitor.recordDiscovery()
        monitor.recordDiscovery()
        XCTAssertNil(monitor.plateauStartTime,
            "Plateau timer should reset after discovery")
        XCTAssertEqual(monitor.currentPhase, .discovery)
    }

    // MARK: - Discovery Tracking

    func testTotalDiscoveriesIncrements() {
        let monitor = CoverageMonitor()
        monitor.start()
        XCTAssertEqual(monitor.totalDiscoveries, 0)
        monitor.recordDiscovery()
        XCTAssertEqual(monitor.totalDiscoveries, 1)
        monitor.recordDiscovery()
        monitor.recordDiscovery()
        XCTAssertEqual(monitor.totalDiscoveries, 3)
    }

    func testDiscoveryRateReflectsRecentDiscoveries() {
        let monitor = CoverageMonitor()
        monitor.start()
        XCTAssertEqual(monitor.discoveryRate, 0.0, accuracy: 0.01)
        monitor.recordDiscovery()
        // 1 discovery in 120s window = 0.5 screens/minute
        XCTAssertEqual(monitor.discoveryRate, 0.5, accuracy: 0.01)
    }

    // MARK: - LLM Action Tracking

    func testLLMActionsTrackingAndReset() {
        let monitor = CoverageMonitor()
        monitor.start()
        XCTAssertEqual(monitor.llmActions, 0)
        monitor.recordLLMAction()
        monitor.recordLLMAction()
        XCTAssertEqual(monitor.llmActions, 2)
    }

    func testDiscoveryResetsLLMActions() {
        let monitor = CoverageMonitor()
        monitor.start()
        // Enter plateau first (no discoveries → rate is 0)
        _ = monitor.currentPhase
        XCTAssertNotNil(monitor.plateauStartTime)
        monitor.recordLLMAction()
        monitor.recordLLMAction()
        XCTAssertEqual(monitor.llmActions, 2)
        // Discovery during plateau resets LLM counter
        monitor.recordDiscovery()
        XCTAssertEqual(monitor.llmActions, 0)
    }

    // MARK: - Lifecycle

    func testStartResetsAllState() {
        let monitor = CoverageMonitor()
        monitor.start()
        monitor.recordDiscovery()
        monitor.recordLLMAction()
        XCTAssertEqual(monitor.totalDiscoveries, 1)
        XCTAssertEqual(monitor.llmActions, 1)

        // Restart
        monitor.start()
        XCTAssertEqual(monitor.totalDiscoveries, 0)
        XCTAssertEqual(monitor.llmActions, 0)
        XCTAssertNil(monitor.plateauStartTime)
    }

    func testElapsedSecondsIsPositiveAfterStart() {
        let monitor = CoverageMonitor()
        monitor.start()
        XCTAssertGreaterThanOrEqual(monitor.elapsedSeconds, 0)
    }
}
