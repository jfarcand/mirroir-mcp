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
// ABOUTME: Taps a window point between two screen reads and says when the screen did not change.
// ABOUTME: A point tap has no text to find, so without this a tap that never arrived reads as done.

import CoreGraphics
import Foundation
import HelperLib

/// A tap at a point, reported with what the screen shows after it.
///
/// An unlabeled control (a close ✕, an icon) is tapped by point. A text tap is
/// found in a read and compared with the read after it (`InlineStepRunner`);
/// a point tap had nothing to compare, so a tap the iPhone never received
/// came back as "Tapped at". This reads the screen just before the tap and,
/// after the same settling delay a step gets, just after it: both frames as
/// they are, because a screen that never stops moving (an animated ad, a game)
/// would hold each tap for the whole settle timeout. Local OCR only: a vision
/// describer would bill a model call for each read.
enum PointTapReport {

    /// Read, tap with `tap`, `wait`, read again.
    ///
    /// - Parameters:
    ///   - described: The reply's first line, e.g. "Tapped at (198, 56)".
    ///   - tapped: How the unchanged-screen note names the tap, e.g. "the point (198, 56)".
    ///   - read: Reads the screen as it is.
    ///   - tap: Sends the tap; returns an error message, or nil once sent.
    ///   - wait: Lets the screen answer the tap; a step's settling delay by default.
    /// - Returns: The reply, or the tap's error.
    static func run(
        described: String,
        tapped: String,
        read: () -> ScreenDescriber.DescribeResult?,
        tap: () -> String?,
        wait: () -> Void = { usleep(EnvConfig.stepSettlingDelayMs * 1000) }
    ) -> Result<String, PointTapError> {
        let before = read()
        if let error = tap() { return .failure(PointTapError(message: error)) }
        wait()
        let after = read()
        return .success(reply(described: described, tapped: tapped, before: before, after: after))
    }

    /// The reply for a sent tap, given the reads around it.
    static func reply(
        described: String,
        tapped: String,
        before: ScreenDescriber.DescribeResult?,
        after: ScreenDescriber.DescribeResult?
    ) -> String {
        var lines = [described]
        if let before, let after, InlineStepRunner.readsTheSame(before.elements, after.elements) {
            lines.append("")
            lines.append(InlineStepRunner.unchangedNotice(tapped: tapped))
        }
        if let after {
            lines.append("")
            lines.append("Screen now: \(InlineStepRunner.screenText(after))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Why a point tap was not sent.
struct PointTapError: Error, Equatable {
    let message: String
}
