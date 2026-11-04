// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Writes a scene's evidence: each frame's PNG and one JSON line per frame (OCR, reply, action, picker, touch, tokens).
// ABOUTME: What a reviewer reads to judge a run the predicates alone cannot explain.

import Foundation

/// Writes `frame-NNN.png` and `frames.jsonl` into one scene's directory.
/// A write that fails is reported on stderr and never stops the scene: the
/// verdict comes from the predicates, not from the evidence.
final class SceneEvidenceWriter: @unchecked Sendable {
    let directory: String
    private let lock = NSLock()

    /// A writer for the scene at `stepIndex` of `skillName` under `baseDir`, or
    /// nil when its directory cannot be created.
    init?(baseDir: String, skillName: String, stepIndex: Int) {
        let safeSkill = skillName.replacingOccurrences(of: "/", with: "_")
        directory = (baseDir as NSString).appendingPathComponent("\(safeSkill)-scene-\(stepIndex)")
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        } catch {
            fputs("scene evidence: cannot create \(directory): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    /// Record one frame: what was read, what the model answered, what the move
    /// picker answered (or why it failed), what was touched.
    func record(
        frame: Int, png: Data, screen: ScreenDescriber.DescribeResult,
        reply: ChatCompletionReply?, action: SceneAction?, touch: String?, decision: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        let name = String(format: "frame-%03d.png", frame)
        let pngPath = (directory as NSString).appendingPathComponent(name)
        var line: [String: Any] = [
            "frame": frame,
            "png": name,
            "ocr": screen.elements.map(\.text),
            "reply": reply?.text ?? NSNull(),
            "control": action?.controlName ?? NSNull(),
            "direction": action?.direction?.rawValue ?? NSNull(),
            "cells": action.map { $0.cells as Any } ?? NSNull(),
            "decision": decision ?? NSNull(),
            "rationale": action?.rationale ?? NSNull(),
            "touch": touch ?? NSNull(),
        ]
        if let usage = reply?.usage {
            line["prompt_tokens"] = usage.promptTokens
            line["completion_tokens"] = usage.completionTokens
        }
        do {
            try png.write(to: URL(fileURLWithPath: pngPath))
            var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            data.append(Data("\n".utf8))
            try append(data, to: (directory as NSString).appendingPathComponent("frames.jsonl"))
        } catch {
            fputs("scene evidence: frame \(frame): \(error.localizedDescription)\n", stderr)
        }
    }

    private func append(_ data: Data, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try data.write(to: URL(fileURLWithPath: path))
            return
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
