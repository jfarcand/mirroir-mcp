// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decorator around ScreenDescribing that caches the last OCR result.
// ABOUTME: Used during skill compilation to capture coordinates and timing for compiled replay.

import Foundation

/// Wraps a real `ScreenDescribing` implementation, forwarding every `describe()` call
/// and caching the result. The compile command reads `lastResult` after each step
/// to build `StepHints` without any extra OCR overhead.
final class RecordingDescriber: ScreenDescribing, @unchecked Sendable {
    private let wrapped: ScreenDescribing

    /// The most recent describe result, available after each `describe()` call.
    private(set) var lastResult: ScreenDescriber.DescribeResult?

    /// Number of describe() calls made.
    private(set) var callCount: Int = 0

    init(wrapping describer: ScreenDescribing) {
        self.wrapped = describer
    }

    func describe(skipOCR: Bool) -> ScreenDescriber.DescribeResult? {
        let result = wrapped.describe(skipOCR: skipOCR)
        lastResult = result
        callCount += 1
        return result
    }
}
