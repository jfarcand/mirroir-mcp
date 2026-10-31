// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Records the structural fingerprint of the screen a skill starts on and of the settled screen after each step.
// ABOUTME: Feeds the run report's per-step `screens` and the compiled skill a passing run records.

import Foundation
import HelperLib

/// The screens one skill run left on display, as structural fingerprints.
struct StepScreens: Equatable {
    /// Key the report's `screens` map gives the start screen.
    static let startKey = "start"

    /// The screen before the first step ran; nil when it could not be read.
    var start: ScreenFingerprint?
    /// The settled screen after each step that ran, keyed by its index in the skill.
    var afterStep: [Int: ScreenFingerprint] = [:]

    /// Whether no screen was read at all.
    var isEmpty: Bool { start == nil && afterStep.isEmpty }

    /// The report's `screens` map: `start` for the start screen and the decimal
    /// step index for each screen a step left.
    var reportMap: [String: ScreenFingerprint] {
        var map: [String: ScreenFingerprint] = [:]
        if let start { map[Self.startKey] = start }
        for (index, fingerprint) in afterStep {
            map[String(index)] = fingerprint
        }
        return map
    }
}

/// Accumulates the screens of one skill run: `recordStart()` before the first
/// step, `recordStep(_:result:)` after each, `snapshot()` when the skill ends.
/// A step that was skipped left no screen of its own and is not read.
final class StepScreenRecorder {
    private let lock = NSLock()
    /// The describer the run reads through now: a `target:` step swaps the
    /// executor's describer, so it is looked up at each read.
    private let describer: () -> any ScreenDescribing
    private var screens = StepScreens()
    /// Microseconds between two reads that must agree before a screen is kept.
    private let confirmDelayUs: UInt32

    init(describer: @escaping () -> any ScreenDescribing,
         confirmDelayUs: UInt32 = EnvConfig.stepSettlingDelayMs * 1000) {
        self.describer = describer
        self.confirmDelayUs = confirmDelayUs
    }

    /// Read the screen the skill starts from.
    func recordStart() {
        let fingerprint = read()
        lock.lock()
        screens.start = fingerprint
        lock.unlock()
    }

    /// Read the settled screen step `index` left, unless it was skipped.
    func recordStep(_ index: Int, result: StepResult) {
        guard result.status != .skipped, let fingerprint = read() else { return }
        lock.lock()
        screens.afterStep[index] = fingerprint
        lock.unlock()
    }

    /// The screens recorded so far.
    func snapshot() -> StepScreens {
        lock.lock()
        defer { lock.unlock() }
        return screens
    }

    /// Most reads spent waiting for two consecutive reads to agree.
    static let maxStableReads = 4

    /// Read the screen until two consecutive reads, `confirmDelayUs` apart,
    /// give the same structural fingerprint. A settled frame alone is not enough: the mirrored frame lags the device, so right after a tap the
    /// old screen can hold still before the new one starts sliding in, and a
    /// single read records the screen the step left behind instead of the one
    /// it led to. When the screen never holds still, the last read is kept.
    private func read() -> ScreenFingerprint? {
        var previous = readOnce()
        for _ in 1 ..< Self.maxStableReads {
            usleep(confirmDelayUs)
            let current = readOnce()
            if let current, current.hash == previous?.hash { return current }
            previous = current
        }
        return previous
    }

    private func readOnce() -> ScreenFingerprint? {
        guard let screen = describer().describe(
            settleTimeoutUs: EnvConfig.frameSettleTimeoutUs) else { return nil }
        return StructuralFingerprint.buildScreenFingerprint(
            elements: screen.elements, icons: screen.icons)
    }
}
