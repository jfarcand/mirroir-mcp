// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Data model for compiled scenarios — pre-recorded coordinates, timing, and scroll sequences.
// ABOUTME: Eliminates OCR during replay by storing all decision data from a learning run.

import CommonCrypto
import Foundation

/// A compiled scenario ready for OCR-free replay.
struct CompiledScenario: Codable, Equatable {
    /// Format version for forward compatibility.
    let version: Int
    /// Metadata about the source YAML file.
    let source: SourceInfo
    /// Device dimensions at compilation time.
    let device: DeviceInfo
    /// Pre-compiled steps with cached coordinates and timing.
    let steps: [CompiledStep]

    /// Current format version.
    static let currentVersion = 1
}

/// Metadata about the source scenario file used to detect staleness.
struct SourceInfo: Codable, Equatable {
    /// SHA-256 hash of the source scenario file content.
    let sha256: String
    /// ISO 8601 timestamp of when the scenario was compiled.
    let compiledAt: String
}

/// Device dimensions captured during compilation for dimension mismatch detection.
struct DeviceInfo: Codable, Equatable {
    let windowWidth: Double
    let windowHeight: Double
    let orientation: String
}

/// A single step in a compiled scenario, combining the original step type with cached hints.
struct CompiledStep: Codable, Equatable {
    /// Original step index in the scenario.
    let index: Int
    /// Step type key (e.g. "tap", "wait_for", "launch").
    let type: String
    /// Human-readable label from the original step.
    let label: String?
    /// Compiled hints for OCR-free replay. Nil for AI-only steps that cannot be compiled.
    let hints: StepHints?
}

/// Cached data from the learning run that enables OCR-free replay.
struct StepHints: Codable, Equatable {
    /// The action to perform during compiled replay.
    let compiledAction: CompiledAction

    // Tap hints
    let tapX: Double?
    let tapY: Double?
    let confidence: Float?
    let matchStrategy: String?

    // Timing hints
    let observedDelayMs: Int?

    // Scroll hints
    let scrollCount: Int?
    let scrollDirection: String?

    /// Create hints for a tap action.
    static func tap(x: Double, y: Double, confidence: Float, strategy: String) -> StepHints {
        StepHints(compiledAction: .tap, tapX: x, tapY: y,
                  confidence: confidence, matchStrategy: strategy,
                  observedDelayMs: nil, scrollCount: nil, scrollDirection: nil)
    }

    /// Create hints for a sleep action (wait_for / assert_visible).
    static func sleep(delayMs: Int) -> StepHints {
        StepHints(compiledAction: .sleep, tapX: nil, tapY: nil,
                  confidence: nil, matchStrategy: nil,
                  observedDelayMs: delayMs, scrollCount: nil, scrollDirection: nil)
    }

    /// Create hints for a scroll sequence.
    static func scrollSequence(count: Int, direction: String) -> StepHints {
        StepHints(compiledAction: .scrollSequence, tapX: nil, tapY: nil,
                  confidence: nil, matchStrategy: nil,
                  observedDelayMs: nil, scrollCount: count, scrollDirection: direction)
    }

    /// Create hints for a passthrough action (already OCR-free).
    static func passthrough() -> StepHints {
        StepHints(compiledAction: .passthrough, tapX: nil, tapY: nil,
                  confidence: nil, matchStrategy: nil,
                  observedDelayMs: nil, scrollCount: nil, scrollDirection: nil)
    }
}

/// The type of action to perform during compiled replay.
enum CompiledAction: String, Codable, Equatable {
    /// Direct tap at cached coordinates.
    case tap
    /// Sleep for observed delay (used for wait_for, assert_visible).
    case sleep
    /// Replay a sequence of scroll/swipe gestures.
    case scrollSequence = "scroll_sequence"
    /// Delegate to normal StepExecutor (step is already OCR-free).
    case passthrough
}

/// File I/O for compiled scenario JSON files.
enum CompiledScenarioIO {

    /// Derive the compiled JSON path from a scenario file path.
    /// Works for both `.yaml` and `.md` since `deletingPathExtension` handles either.
    /// `apps/settings/check-about.yaml` → `apps/settings/check-about.compiled.json`
    /// `apps/settings/check-about.md` → `apps/settings/check-about.compiled.json`
    static func compiledPath(for scenarioPath: String) -> String {
        let base = (scenarioPath as NSString).deletingPathExtension
        return base + ".compiled.json"
    }

    /// Load a compiled scenario from disk. Returns nil if file doesn't exist.
    static func load(for scenarioPath: String) throws -> CompiledScenario? {
        let path = compiledPath(for: scenarioPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        return try decoder.decode(CompiledScenario.self, from: data)
    }

    /// Save a compiled scenario to disk alongside its source file.
    static func save(_ compiled: CompiledScenario, for scenarioPath: String) throws {
        let path = compiledPath(for: scenarioPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(compiled)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Compute SHA-256 hash of file contents.
    static func sha256(of filePath: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return sha256(data: data)
    }

    /// Compute SHA-256 hash of raw data.
    static func sha256(data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Check if a compiled scenario is stale relative to its source file.
    static func checkStaleness(compiled: CompiledScenario,
                                scenarioPath: String,
                                windowWidth: Double,
                                windowHeight: Double) -> StalenessResult {
        // Version check
        if compiled.version != CompiledScenario.currentVersion {
            return .stale(reason: "compiled version \(compiled.version) != current \(CompiledScenario.currentVersion)")
        }

        // Source hash check
        if let currentHash = try? sha256(of: scenarioPath),
           currentHash != compiled.source.sha256 {
            return .stale(reason: "source file has changed since compilation")
        }

        // Dimension check
        if compiled.device.windowWidth != windowWidth ||
           compiled.device.windowHeight != windowHeight {
            return .stale(reason: "window dimensions changed: compiled \(Int(compiled.device.windowWidth))x\(Int(compiled.device.windowHeight)) vs current \(Int(windowWidth))x\(Int(windowHeight))")
        }

        return .fresh
    }
}

/// Result of staleness checking.
enum StalenessResult: Equatable {
    case fresh
    case stale(reason: String)
}
