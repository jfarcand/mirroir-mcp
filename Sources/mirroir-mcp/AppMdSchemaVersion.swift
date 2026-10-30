// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Gates an APP.md `version:` front-matter value — a different major is refused, a newer minor tolerated.
// ABOUTME: The same rule mirroir-run applies to every artifact it loads (runner/src/parser/version.rs).

import Foundation

/// The APP.md schema version gate.
///
/// `version: 1` is canonical and means major 1, minor 0; a quoted
/// `"MAJOR.MINOR"` carries a minor. A bare float such as `1.2` is refused,
/// because `1.10` and `1.1` would be indistinguishable to a YAML reader.
/// A file whose major differs from ``supportedMajor`` is refused; a file at a
/// newer minor of the supported major parses, with whatever that minor added
/// left unread.
enum AppMdSchemaVersion {
    /// The only APP.md major this build parses.
    static let supportedMajor = 1
    /// The newest minor of ``supportedMajor`` this build models.
    static let knownMinor = 0

    /// A parsed `version:` value.
    struct Version: Equatable {
        let major: Int
        let minor: Int
    }

    /// The outcome of gating one APP.md's `version:`.
    enum Verdict: Equatable {
        /// The file is at a version this build models exactly.
        case supported(major: Int)
        /// The file is at a newer minor of the supported major: parse it,
        /// ignoring what that minor added.
        case newerMinor(major: Int, minor: Int)
        /// The file's major differs from ``supportedMajor``, or the value is malformed.
        case rejected(reason: String)
    }

    /// Gate a raw front-matter value. `version:` is required: an absent one
    /// is refused, exactly as mirroir-run refuses an APP.md without it.
    static func gate(_ raw: String?) -> Verdict {
        guard let raw else {
            return .rejected(reason:
                "no version: front-matter field; declare `version: \(supportedMajor)`")
        }
        guard let version = parse(raw) else {
            return .rejected(reason:
                "version \(raw) is neither an integer nor a quoted \"MAJOR.MINOR\"")
        }
        if version.major != supportedMajor {
            return .rejected(reason:
                "version \(raw) has major \(version.major); this build supports major \(supportedMajor)")
        }
        if version.minor > knownMinor {
            return .newerMinor(major: version.major, minor: version.minor)
        }
        return .supported(major: version.major)
    }

    /// Parse `1` or `"1.2"` (single or double quotes). An unquoted dotted
    /// value is a YAML float and is refused.
    static func parse(_ raw: String) -> Version? {
        let quoted = raw.count >= 2
            && ((raw.hasPrefix("\"") && raw.hasSuffix("\""))
                || (raw.hasPrefix("'") && raw.hasSuffix("'")))
        let text = quoted ? String(raw.dropFirst().dropLast()) : raw
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 || (parts.count == 2 && !quoted) { return nil }
        let numbers = parts.map { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else {
                return nil
            }
            return Int(part)
        }
        guard let major = numbers.first ?? nil else { return nil }
        let minor = numbers.count == 2 ? numbers[1] : 0
        guard let minor else { return nil }
        return Version(major: major, minor: minor)
    }
}
