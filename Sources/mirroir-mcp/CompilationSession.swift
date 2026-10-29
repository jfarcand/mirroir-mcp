// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Session accumulator for AI-driven compilation: the steps record_step reports and
// ABOUTME: the start-screen fingerprint get_skill reads, both consumed by save_compiled.

import Foundation

/// Accumulates compiled steps reported by the AI during skill execution, and the
/// fingerprint of the screen that execution started from.
/// Thread-safe via NSLock. Session persists across MCP calls (survives context compaction).
final class CompilationSession: @unchecked Sendable {
    private var steps: [CompiledStep] = []
    /// The skill whose start screen was read, and that screen's fingerprint.
    private var start: (skillPath: String, fingerprint: ScreenFingerprint?)?
    private let lock = NSLock()

    /// Record the screen `skillPath` starts from, read by `capture`, when no step
    /// has been recorded yet. Once a step is recorded the screen is no longer the
    /// start screen, so a skill read again mid-run keeps the one read before step 1.
    func markStart(skillPath: String, capture: () -> ScreenFingerprint?) {
        guard isIdle else { return }
        let fingerprint = capture()
        lock.lock()
        defer { lock.unlock() }
        if steps.isEmpty {
            start = (skillPath, fingerprint)
        }
    }

    /// The start-screen fingerprint read for `skillPath`, or nil when none was.
    func startFingerprint(for skillPath: String) -> ScreenFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        guard let start, start.skillPath == skillPath else { return nil }
        return start.fingerprint
    }

    private var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return steps.isEmpty
    }

    /// Record a compiled step.
    func record(_ step: CompiledStep) {
        lock.lock()
        defer { lock.unlock() }
        steps.append(step)
    }

    /// Return the accumulated steps, one per index in step order, and clear the session.
    func finalizeAndClear() -> [CompiledStep] {
        lock.lock()
        defer { lock.unlock() }
        let result = CompiledSkillIO.normalizedSteps(steps)
        steps = []
        start = nil
        return result
    }

    /// The steps recorded so far, one per index in step order, without clearing them.
    var recordedSteps: [CompiledStep] {
        lock.lock()
        defer { lock.unlock() }
        return CompiledSkillIO.normalizedSteps(steps)
    }

    /// Step indices not recorded yet, between 0 and the highest one recorded.
    var missingIndices: [ClosedRange<Int>] {
        lock.lock()
        defer { lock.unlock() }
        return CompiledSkillIO.missingIndices(CompiledSkillIO.normalizedSteps(steps))
    }

    /// Number of steps recorded so far.
    var stepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return steps.count
    }
}
