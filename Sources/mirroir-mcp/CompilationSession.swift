// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Session accumulator for AI-driven compilation: the steps record_step reports and
// ABOUTME: the screens read around them (start and after each step), consumed by save_compiled.

import Foundation
import HelperLib

/// One local OCR read of a screen during compilation: the fingerprint replay
/// checks a screen against, and the elements a `.mirroir/` scenario is
/// rendered from (label casing, landmark waits).
struct CompiledScreenRead: Sendable {
    let fingerprint: ScreenFingerprint
    let elements: [TapPoint]
}

/// Accumulates compiled steps reported by the AI during skill execution, the
/// screen that execution started from, and the screen each step left on display.
/// Thread-safe via NSLock. Session persists across MCP calls (survives context compaction).
final class CompilationSession: @unchecked Sendable {
    private var steps: [CompiledStep] = []
    /// The skill whose start screen was read, and that screen.
    private var start: (skillPath: String, screen: CompiledScreenRead?)?
    /// The settled screen read right after each recorded step, by step index
    /// (nil when that read failed). A coordinate-only tap is compared with the
    /// screen before it, so a tap that changed nothing is refused when recorded.
    private var screensAfter: [Int: CompiledScreenRead?] = [:]
    private let lock = NSLock()

    /// Record the screen `skillPath` starts from, read by `capture`, when no step
    /// has been recorded yet. Once a step is recorded the screen is no longer the
    /// start screen, so a skill read again mid-run keeps the one read before step 1.
    func markStart(skillPath: String, capture: () -> CompiledScreenRead?) {
        guard isIdle else { return }
        let screen = capture()
        lock.lock()
        defer { lock.unlock() }
        if steps.isEmpty {
            start = (skillPath, screen)
        }
    }

    /// The start-screen fingerprint read for `skillPath`, or nil when none was.
    func startFingerprint(for skillPath: String) -> ScreenFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        guard let start, start.skillPath == skillPath else { return nil }
        return start.screen?.fingerprint
    }

    /// Keep the screen read right after step `index` (nil when that read failed).
    func noteScreen(_ read: CompiledScreenRead?, after index: Int) {
        lock.lock()
        defer { lock.unlock() }
        screensAfter[index] = read
    }

    /// The elements of every screen read right after a recorded step, by step
    /// index; a step whose read failed is absent. The session is not cleared.
    var elementsAfterSteps: [Int: [TapPoint]] {
        lock.lock()
        defer { lock.unlock() }
        return screensAfter.compactMapValues { $0?.elements }
    }

    /// The screen step `index` started from: the one read after the step before
    /// it, or for step 0 the start screen get_skill read. Nil when none was read.
    func screenBefore(step index: Int) -> ScreenFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        guard index > 0 else { return start?.screen?.fingerprint }
        return (screensAfter[index - 1] ?? nil)?.fingerprint
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
        screensAfter = [:]
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
