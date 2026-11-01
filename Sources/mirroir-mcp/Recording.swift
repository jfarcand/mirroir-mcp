// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The saved form of a `record` session: each interaction with the screen it acted on, plus the final screen.
// ABOUTME: Encoded as versioned JSON so a session can be re-rendered into a scenario without the device.

import Foundation
import HelperLib

/// The type of user interaction the recorder observed. Coordinates are
/// window-relative points; a label is the nearest OCR text, nil when none was
/// close enough to name the touched element.
enum RecordedEventKind: Codable, Equatable {
    case tap(x: Double, y: Double, label: String?)
    case swipe(direction: String)
    case longPress(x: Double, y: Double, label: String?, durationMs: Int)
    case type(text: String)
    case pressKey(keyName: String, modifiers: [String])
}

/// One recorded interaction and the OCR elements of the screen it acted on —
/// the same snapshot the recorder looked the tap label up in.
struct RecordedStep: Codable, Equatable {
    let kind: RecordedEventKind
    let screenBefore: [TapPoint]
}

/// A whole `record` session: the app and flow it was recorded for, every
/// interaction in order, and the screen the last one reached.
struct Recording: Codable, Equatable {
    /// The only file version this binary reads and writes.
    static let currentVersion = 1

    /// File suffix of a saved recording.
    static let fileSuffix = ".recording.json"

    let version: Int
    let appName: String
    let flowName: String
    let steps: [RecordedStep]
    let finalScreen: [TapPoint]

    init(appName: String, flowName: String, steps: [RecordedStep], finalScreen: [TapPoint]) {
        self.version = Self.currentVersion
        self.appName = appName
        self.flowName = flowName
        self.steps = steps
        self.finalScreen = finalScreen
    }

    /// Errors raised when a saved recording cannot be read.
    enum LoadError: LocalizedError, Equatable {
        /// The file was written by a format version this binary does not read.
        case unsupportedVersion(path: String, found: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let path, let found, let expected):
                return "\(path) is recording version \(found); this mirroir-mcp reads only " +
                    "version \(expected)"
            }
        }
    }

    /// Read a recording saved by `write(to:)`.
    ///
    /// - Throws: a file-system or `DecodingError` when the file is unreadable
    ///   or malformed, `LoadError.unsupportedVersion` for any other version.
    static func load(path: String) throws -> Recording {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let recording = try JSONDecoder().decode(Recording.self, from: data)
        guard recording.version == currentVersion else {
            throw LoadError.unsupportedVersion(
                path: path, found: recording.version, expected: currentVersion)
        }
        return recording
    }

    /// Write the recording as pretty-printed, key-sorted JSON, creating the
    /// parent directory when absent.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
