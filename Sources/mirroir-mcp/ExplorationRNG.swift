// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Seeded pseudo-random number generator for reproducible exploration.
// ABOUTME: Wraps a deterministic xoshiro256** PRNG to break scoring ties consistently.

import Foundation
import HelperLib

/// Seeded PRNG for reproducible exploration ordering.
/// When no seed is provided, uses system randomness (non-deterministic).
/// When seeded, produces identical sequences across runs for the same seed.
final class ExplorationRNG: @unchecked Sendable {

    private let lock = NSLock()
    /// xoshiro256** internal state (4 x UInt64).
    private var state: (UInt64, UInt64, UInt64, UInt64)
    /// Whether this RNG was seeded (deterministic mode).
    let isSeeded: Bool

    /// Create a seeded RNG for deterministic exploration.
    init(seed: UInt64) {
        self.isSeeded = true
        // SplitMix64 to expand a single seed into 4 state values
        var s = seed
        func next() -> UInt64 {
            s &+= 0x9e3779b97f4a7c15
            var z = s
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        self.state = (next(), next(), next(), next())
    }

    /// Create a non-deterministic RNG using system randomness.
    init() {
        self.isSeeded = false
        self.state = (
            UInt64.random(in: .min ... .max),
            UInt64.random(in: .min ... .max),
            UInt64.random(in: .min ... .max),
            UInt64.random(in: .min ... .max)
        )
    }

    /// Generate the next random UInt64.
    func nextUInt64() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return xoshiro256ss()
    }

    /// Generate a random Double in [0.0, 1.0).
    func nextDouble() -> Double {
        Double(nextUInt64() >> 11) * 0x1.0p-53
    }

    /// Shuffle an array in place using this PRNG.
    func shuffle<T>(_ array: inout [T]) {
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = Int(nextUInt64() % UInt64(i + 1))
            array.swapAt(i, j)
        }
    }

    /// Break a tie between equally-scored elements with a deterministic jitter.
    /// Returns a small value (±0.001) that varies by element text hash and sequence.
    func tiebreaker(for text: String) -> Double {
        let textHash = text.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
        let combined = textHash ^ nextUInt64()
        return Double(combined % 1000) / 500_000.0 - 0.001
    }

    // MARK: - Canonical Element Ordering

    /// Sort elements into a canonical order for deterministic exploration.
    /// Primary sort by Y (top to bottom), secondary by X (left to right) for
    /// elements at similar Y positions (within 10pt tolerance).
    static func canonicalOrder(_ elements: [TapPoint]) -> [TapPoint] {
        let yTolerance: Double = 10.0
        return elements.sorted { a, b in
            if abs(a.tapY - b.tapY) <= yTolerance {
                return a.tapX < b.tapX
            }
            return a.tapY < b.tapY
        }
    }

    // MARK: - xoshiro256** Core

    private func xoshiro256ss() -> UInt64 {
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 << 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = rotl(state.3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }
}
