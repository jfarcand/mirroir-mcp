// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: One capture of the iPhone Mirroring window as Accessibility reported it, with the macOS version, app version and language it was taken on.
// ABOUTME: The file format of the live fixtures the session-state tests replay; `ax-capture` writes it.

import AppKit
import Foundation

/// One capture of the iPhone Mirroring window as Accessibility reported it,
/// with where it was taken.
///
/// The window is the exact value the session-state check reads, so a test can
/// replay a screen nobody can produce on demand. `state` and `move` are what
/// this binary made of the window at capture time: they are only worth
/// keeping when the person capturing confirmed them against the screen.
struct AXWindowCapture: Codable, Equatable {

    /// The only file version this binary reads and writes.
    static let currentVersion = 1

    /// File suffix of a saved capture.
    static let fileSuffix = ".axwindow.json"

    let version: Int
    /// What the capture shows, as its file is named: `connected`, `paused`.
    let name: String
    /// The Mac's system version and build, e.g. `26.5 (25F71)`.
    let macOSVersion: String
    /// The iPhone Mirroring app's version and build.
    let mirroringVersion: String
    /// The language the app's strings resolve to on this Mac, e.g. `en`.
    let localization: String
    /// The app's strings in `localization`, by English key, where they differ
    /// from the key. A capture in another language carries its own table, so
    /// replaying it needs neither the app nor that language.
    let strings: [String: String]
    /// The session state the window read as.
    let state: WindowState
    /// The move its interruption called for, when it showed one.
    let move: SessionBlockMove?
    /// Whether the window's frame was blank, recorded only when the state
    /// check had to ask (a window showing only unlabeled controls).
    let frameIsBlank: Bool?
    let window: MirroringAXWindow

    /// Errors raised when a saved capture cannot be read.
    enum LoadError: LocalizedError, Equatable {
        /// The file was written by a format version this binary does not read.
        case unsupportedVersion(path: String, found: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let path, let found, let expected):
                return "\(path) is window-capture version \(found); this mirroir-mcp reads only "
                    + "version \(expected)"
            }
        }
    }

    /// Read a capture saved by `write(to:)`.
    ///
    /// - Throws: a file-system or `DecodingError` when the file is unreadable
    ///   or malformed, `LoadError.unsupportedVersion` for any other version.
    static func load(path: String) throws -> AXWindowCapture {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let capture = try JSONDecoder().decode(AXWindowCapture.self, from: data)
        guard capture.version == currentVersion else {
            throw LoadError.unsupportedVersion(
                path: path, found: capture.version, expected: currentVersion)
        }
        return capture
    }

    /// Write the capture as pretty-printed, key-sorted JSON, creating the
    /// parent directory when absent.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The directory a capture taken on this macOS version and language is
    /// filed under, e.g. `macos-26.5-en`.
    var directoryName: String {
        let version = macOSVersion.split(separator: " ").first.map(String.init) ?? macOSVersion
        let majorMinor = version.split(separator: ".").prefix(2).joined(separator: ".")
        return "macos-\(majorMinor)-\(localization)"
    }

    /// Every label in the window, in reading order: what a person checks
    /// before committing a capture to a public repository.
    var labels: [String] {
        func collect(_ node: AXNodeSnapshot) -> [String] {
            (node.label.map { [$0] } ?? []) + node.children.flatMap(collect)
        }
        return (window.hostingView.map(collect) ?? []) + window.sheets.flatMap(collect)
    }
}

/// Where a capture is taken: the tags written into it.
struct AXCaptureEnvironment: Equatable, Sendable {
    let macOSVersion: String
    let mirroringVersion: String
    let localization: String
    let strings: [String: String]

    /// The tags for this Mac and its installed iPhone Mirroring app.
    static func live(bundleID: String) -> AXCaptureEnvironment {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let patch = os.patchVersion > 0 ? ".\(os.patchVersion)" : ""
        let version = "\(os.majorVersion).\(os.minorVersion)\(patch)"
        let build = systemBuild().map { " (\($0))" } ?? ""

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let info = appURL.flatMap { Bundle(url: $0)?.infoDictionary } ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = (info["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""

        let stringsBundle = InterstitialPhrases.stringsBundle(bundleID: bundleID)
        let keys = InterstitialPhrases.appKeys.flatMap(\.1) + InterstitialPhrases.resumeControlKeys
        var strings: [String: String] = [:]
        for key in keys {
            guard let rendering = stringsBundle?.localizedString(forKey: key, value: key, table: nil),
                  rendering != key else { continue }
            strings[key] = rendering
        }
        return AXCaptureEnvironment(
            macOSVersion: version + build, mirroringVersion: short + appBuild,
            localization: stringsBundle?.preferredLocalizations.first ?? englishLocalization,
            strings: strings)
    }

    /// The localization of a Mac whose app strings could not be read.
    static let englishLocalization = "en"

    /// The system's build identifier, e.g. `25F71`.
    private static func systemBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }
}
