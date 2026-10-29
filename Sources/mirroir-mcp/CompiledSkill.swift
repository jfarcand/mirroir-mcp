// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Data model for compiled skills — pre-recorded coordinates, timing, and scroll sequences.
// ABOUTME: Eliminates OCR during replay by storing all decision data from a learning run.

import CommonCrypto
import Foundation

/// A compiled skill ready for OCR-free replay.
struct CompiledSkill: Codable, Equatable {
    /// Format version for forward compatibility.
    let version: Int
    /// Metadata about the source YAML file.
    let source: SourceInfo
    /// Device dimensions at compilation time.
    let device: DeviceInfo
    /// Pre-compiled steps with cached coordinates and timing.
    let steps: [CompiledStep]
    /// OCR-based fingerprint of the screen the skill starts from, captured before its
    /// first step ran. Every producer (`mirroir-mcp compile`, `save_compiled`) records
    /// that same moment, so a caller can compare it against the screen a run starts on.
    /// `mirroir-mcp test` never compares or rewrites it. Nil when no start screen was read.
    var screenFingerprint: ScreenFingerprint? = nil

    /// Current format version. Bump forces recompilation of all existing compiled skills.
    /// Version 3: a step's `label` is its replay value, which a SKILL.md's steps are
    /// rebuilt from, where earlier versions held a free-form display label.
    static let currentVersion = 3
}

/// Structural fingerprint of the screen a compiled skill starts from.
struct ScreenFingerprint: Codable, Equatable {
    /// SHA-256 of sorted structural texts + icon count for fast-path equality.
    let hash: String
    /// Sorted structural text elements for Jaccard comparison when hash differs.
    let structuralTexts: [String]
    /// Number of detected icons (coarse structural signal).
    let iconCount: Int
}

/// Metadata about the source skill file used to detect staleness.
struct SourceInfo: Codable, Equatable {
    /// SHA-256 hash of the source skill file content.
    let sha256: String
    /// ISO 8601 timestamp of when the skill was compiled.
    let compiledAt: String
}

/// Device dimensions captured during compilation for dimension mismatch detection.
struct DeviceInfo: Codable, Equatable {
    let windowWidth: Double
    let windowHeight: Double
    let orientation: String
}

/// A single step in a compiled skill, combining the original step type with cached hints.
struct CompiledStep: Codable, Equatable {
    /// Original step index in the skill.
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

    /// Create hints for a sleep action (wait_for, measure).
    static func sleep(delayMs: Int) -> StepHints {
        StepHints(compiledAction: .sleep, tapX: nil, tapY: nil,
                  confidence: nil, matchStrategy: nil,
                  observedDelayMs: delayMs, scrollCount: nil, scrollDirection: nil)
    }

    /// Create hints for an assertion action — sleeps observed delay, then performs real OCR.
    static func assertion(delayMs: Int) -> StepHints {
        StepHints(compiledAction: .assertion, tapX: nil, tapY: nil,
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
    /// Sleep for observed delay (used for wait_for, measure).
    case sleep
    /// Sleep observed delay then delegate to normal StepExecutor for real OCR assertion.
    case assertion
    /// Replay a sequence of scroll/swipe gestures.
    case scrollSequence = "scroll_sequence"
    /// Delegate to normal StepExecutor (step is already OCR-free).
    case passthrough
}

/// File I/O for compiled skill JSON files.
enum CompiledSkillIO {

    /// Derive the compiled JSON path from a skill file path.
    /// Works for both `.yaml` and `.md` since `deletingPathExtension` handles either.
    /// `apps/settings/check-about.yaml` → `apps/settings/check-about.compiled.json`
    /// `apps/settings/check-about.md` → `apps/settings/check-about.compiled.json`
    static func compiledPath(for skillPath: String) -> String {
        let base = (skillPath as NSString).deletingPathExtension
        return base + ".compiled.json"
    }

    /// Load a compiled skill from disk. Returns nil if file doesn't exist.
    static func load(for skillPath: String) throws -> CompiledSkill? {
        let path = compiledPath(for: skillPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CompiledSkill.self, from: data)
        return CompiledSkill(
            version: decoded.version, source: decoded.source, device: decoded.device,
            steps: normalizedSteps(decoded.steps),
            screenFingerprint: decoded.screenFingerprint)
    }

    /// Compiled steps in step order, one per index. Replay pairs the i-th step of a
    /// skill with the i-th compiled step, but an AI can record steps out of order or
    /// record a retried step twice; the last record of an index is the one that ran.
    static func normalizedSteps(_ steps: [CompiledStep]) -> [CompiledStep] {
        var latest: [Int: CompiledStep] = [:]
        for step in steps {
            latest[step.index] = step
        }
        return latest.keys.sorted().compactMap { latest[$0] }
    }

    /// The SKILL.md beside a YAML skill whose recorded steps fill the compiled file both
    /// share (`foo.md` and `foo.yaml` both map to `foo.compiled.json`), or nil. Compiling
    /// the YAML would overwrite the only replayable copy of the SKILL.md's steps.
    static func skillMdTwinOwningCompiledFile(for skillPath: String) -> String? {
        guard !skillPath.hasSuffix(".md") else { return nil }
        let twin = (skillPath as NSString).deletingPathExtension + ".md"
        guard FileManager.default.fileExists(atPath: twin),
              let compiled = try? load(for: skillPath),
              sourceStaleness(compiled: compiled, skillPath: twin) == nil else { return nil }
        return twin
    }

    /// Step indices missing from `steps` (already normalized) between 0 and the last
    /// recorded index. Replay pairs steps by position, so a gap would shift every later
    /// step onto the wrong hints.
    /// Gaps are returned as ranges, so a huge recorded index costs nothing to report.
    static func missingIndices(_ steps: [CompiledStep]) -> [ClosedRange<Int>] {
        var gaps: [ClosedRange<Int>] = []
        var expected = 0
        for index in Set(steps.map(\.index)).sorted() where index >= 0 {
            if index > expected {
                gaps.append(expected...(index - 1))
            }
            // The largest index has no successor to expect.
            guard index < Int.max else { break }
            expected = index + 1
        }
        return gaps
    }

    /// Gaps as `1` or `3...7`, comma-separated, for an error message.
    static func describe(_ gaps: [ClosedRange<Int>]) -> String {
        gaps.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)...\($0.upperBound)" }
            .joined(separator: ", ")
    }

    /// Recorded indices below 0, which no step of a skill can have.
    static func negativeIndices(_ steps: [CompiledStep]) -> [Int] {
        steps.map(\.index).filter { $0 < 0 }.sorted()
    }

    /// Why a compiled skill no longer matches its source file, or nil when it does:
    /// a different compiled-format version, or a source file edited since it was
    /// compiled. Window size is judged separately, against a device.
    static func sourceStaleness(compiled: CompiledSkill, skillPath: String) -> String? {
        if compiled.version != CompiledSkill.currentVersion {
            return "compiled version \(compiled.version) != current \(CompiledSkill.currentVersion)"
        }
        if let currentHash = try? sha256(of: skillPath),
           currentHash != compiled.source.sha256 {
            return "source file has changed since compilation"
        }
        return nil
    }

    /// Save a compiled skill to disk alongside its source file.
    static func save(_ compiled: CompiledSkill, for skillPath: String) throws {
        let path = compiledPath(for: skillPath)
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

    /// Check if a compiled skill is stale relative to its source file and the
    /// window it would replay in. Reading a compiled skill never writes it.
    static func checkStaleness(compiled: CompiledSkill,
                                skillPath: String,
                                windowWidth: Double,
                                windowHeight: Double) -> StalenessResult {
        if let reason = sourceStaleness(compiled: compiled, skillPath: skillPath) {
            return .stale(reason: reason)
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
