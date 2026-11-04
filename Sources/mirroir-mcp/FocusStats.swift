// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Counts, per kind of input action, how many stole the Mac's focus, raised the target, or went unjudged.
// ABOUTME: `mirroir test` prints the totals so a run (and CI) shows whether driving the phone interrupted the user.

import Foundation

/// The kinds of input action `FocusObservingInput` judges.
enum FocusActionKind: String, CaseIterable, Sendable {
    case tap, doubleTap = "double_tap", longPress = "long_press", swipe, drag
    case type, key, launch, openURL = "open_url", shake, touch, gesture
    case holdKeys = "hold_keys"
}

/// Point-in-time totals from `FocusStats`.
struct FocusStatsSnapshot: Equatable, Sendable {
    /// Actions judged, of any outcome.
    let actions: Int
    /// Actions that took the front window from another app, by kind.
    let stole: [FocusActionKind: Int]
    /// Actions that raised the target without taking the front, by kind.
    let raised: [FocusActionKind: Int]
    /// Actions whose target could not be identified.
    let unmeasured: Int

    /// One-line summary, e.g. `focus: actions=10 stole=3 raised=0 (stole: tap=2, type=1)`.
    /// `unmeasured=N` appears only when something went unjudged, and the
    /// per-kind list only when something stole or raised.
    var summaryLine: String {
        let stoleTotal = stole.values.reduce(0, +)
        let raisedTotal = raised.values.reduce(0, +)
        var line = "focus: actions=\(actions) stole=\(stoleTotal) raised=\(raisedTotal)"
        if unmeasured > 0 { line += " unmeasured=\(unmeasured)" }
        let parts = [("stole", stole), ("raised", raised)].compactMap { label, counts in
            Self.breakdown(counts).map { "\(label): \($0)" }
        }
        if !parts.isEmpty { line += " (" + parts.joined(separator: "; ") + ")" }
        return line
    }

    private static func breakdown(_ counts: [FocusActionKind: Int]) -> String? {
        let items = FocusActionKind.allCases.compactMap { kind in
            counts[kind].map { "\(kind.rawValue)=\($0)" }
        }
        return items.isEmpty ? nil : items.joined(separator: ", ")
    }
}

/// Accumulates focus outcomes for the life of the process.
final class FocusStats: @unchecked Sendable {
    /// The process-wide counters every `FocusObservingInput` records into by default.
    static let shared = FocusStats()

    private let lock = NSLock()
    private var actions = 0
    private var stole: [FocusActionKind: Int] = [:]
    private var raised: [FocusActionKind: Int] = [:]
    private var unmeasured = 0

    /// Record the judged outcome of one action.
    func record(_ outcome: FocusInterruption, kind: FocusActionKind) {
        lock.withLock {
            actions += 1
            switch outcome {
            case .stoleFocus: stole[kind, default: 0] += 1
            case .raised: raised[kind, default: 0] += 1
            case .unmeasured: unmeasured += 1
            case .clean: break
            }
        }
    }

    /// Current totals.
    func snapshot() -> FocusStatsSnapshot {
        lock.withLock {
            FocusStatsSnapshot(actions: actions, stole: stole, raised: raised,
                               unmeasured: unmeasured)
        }
    }
}
