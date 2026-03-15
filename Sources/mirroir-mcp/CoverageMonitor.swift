// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Monitors exploration coverage rate to detect discovery plateau and exhaustion.
// ABOUTME: Session accumulator pattern: tracks new screen timestamps, computes rolling discovery rate.

import Foundation

/// Exploration phase based on discovery rate.
enum CoveragePhase: String, Sendable {
    /// Active discovery: new screens appearing at a healthy rate.
    case discovery
    /// Plateau: discovery rate dropped below threshold for sustained period.
    case plateau
    /// Exhaustion: no new screens despite continued exploration.
    case exhaustion
}

/// Monitors exploration coverage rate and detects when discovery has stalled.
/// Follows the Session Accumulator pattern with explicit lifecycle.
final class CoverageMonitor: @unchecked Sendable {

    /// Minimum screens per minute to stay in discovery phase.
    static let discoveryThreshold: Double = 1.0
    /// Screens per minute below which we enter plateau phase.
    static let plateauThreshold: Double = 0.5
    /// Seconds of plateau before transitioning to exhaustion.
    static let exhaustionTimeoutSeconds: Double = 180.0
    /// Rolling window size in seconds for rate calculation.
    static let windowSeconds: Double = 120.0

    private let lock = NSLock()
    /// Timestamps of new screen discoveries.
    private var discoveryTimestamps: [Date] = []
    /// When the monitor started tracking.
    private var startTime: Date = Date()
    /// When plateau phase began (nil if not in plateau).
    var plateauStartTime: Date?
    /// Number of LLM-guided actions attempted during plateau.
    private var llmActionsAttempted: Int = 0

    // MARK: - Lifecycle

    /// Start monitoring. Call once at the beginning of exploration.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        startTime = Date()
        discoveryTimestamps = []
        plateauStartTime = nil
        llmActionsAttempted = 0
    }

    /// Record a new screen discovery.
    func recordDiscovery() {
        lock.lock()
        defer { lock.unlock() }
        discoveryTimestamps.append(Date())
        // Reset plateau timer on new discovery
        if plateauStartTime != nil {
            plateauStartTime = nil
            llmActionsAttempted = 0
        }
    }

    /// Record that an LLM-guided action was attempted during plateau.
    func recordLLMAction() {
        lock.lock()
        defer { lock.unlock() }
        llmActionsAttempted += 1
    }

    // MARK: - Phase Detection

    /// Current coverage phase based on discovery rate.
    var currentPhase: CoveragePhase {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let rate = rollingRate(at: now)

        // Check exhaustion first
        if let plateauStart = plateauStartTime {
            let plateauDuration = now.timeIntervalSince(plateauStart)
            if plateauDuration >= CoverageMonitor.exhaustionTimeoutSeconds {
                return .exhaustion
            }
        }

        // Check plateau
        if rate < CoverageMonitor.plateauThreshold {
            if plateauStartTime == nil {
                plateauStartTime = now
            }
            return .plateau
        }

        return .discovery
    }

    /// Screens per minute in the rolling window.
    var discoveryRate: Double {
        lock.lock()
        defer { lock.unlock() }
        return rollingRate(at: Date())
    }

    /// Total screens discovered since monitoring started.
    var totalDiscoveries: Int {
        lock.lock()
        defer { lock.unlock() }
        return discoveryTimestamps.count
    }

    /// Number of LLM-guided actions attempted during current plateau.
    var llmActions: Int {
        lock.lock()
        defer { lock.unlock() }
        return llmActionsAttempted
    }

    /// Seconds since monitoring started.
    var elapsedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(startTime)
    }

    // MARK: - Internal

    /// Compute rolling discovery rate (screens per minute) within the window.
    private func rollingRate(at now: Date) -> Double {
        let windowStart = now.addingTimeInterval(-CoverageMonitor.windowSeconds)
        let recentCount = discoveryTimestamps.filter { $0 >= windowStart }.count
        let windowMinutes = CoverageMonitor.windowSeconds / 60.0
        return Double(recentCount) / windowMinutes
    }
}
