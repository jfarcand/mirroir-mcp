// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Extracts comparable fingerprints from OCR elements for screen deduplication.
// ABOUTME: Filters status bar noise and sorts text to detect when a screen is unchanged.

import Foundation
import HelperLib

/// Extracts a comparable fingerprint from a screen's OCR elements.
/// Used to detect when a capture action produced no screen change (failed tap).
/// Filters the same status bar noise as `LandmarkPicker` but keeps all remaining text
/// for full-screen comparison rather than picking a single landmark.
enum ScreenFingerprint {

    /// Extract a sorted array of meaningful text from OCR elements.
    /// Filters out status bar elements (tapY < 80), time patterns, and bare numbers.
    static func extract(from elements: [TapPoint]) -> [String] {
        elements
            .filter { el in
                el.tapY >= LandmarkPicker.statusBarMaxY
                    && !LandmarkPicker.isTimePattern(el.text)
                    && !LandmarkPicker.isBareNumber(el.text)
            }
            .map(\.text)
            .sorted()
    }

    /// Compare two screens by their fingerprints.
    /// Returns `true` if the meaningful text content is identical.
    static func areEqual(_ lhs: [TapPoint], _ rhs: [TapPoint]) -> Bool {
        extract(from: lhs) == extract(from: rhs)
    }
}
