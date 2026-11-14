/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
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

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        let result = wrapped.describe(settleTimeoutUs: settleTimeoutUs)
        lastResult = result
        callCount += 1
        return result
    }
}
