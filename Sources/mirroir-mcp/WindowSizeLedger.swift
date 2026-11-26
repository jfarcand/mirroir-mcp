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
// ABOUTME: The window size each target was last read at, so a coordinate action can tell
// ABOUTME: whether its point came from a window of the same size (carnet#106).

import CoreGraphics
import Foundation
import os

/// The size of each target's window when its screen was last read (a describe or a
/// screenshot). Coordinates in a reply are window points of that size: after the user
/// or the app resizes the window, the same point lands elsewhere.
enum WindowSizeLedger {
    private static let sizes = OSAllocatedUnfairLock(initialState: [String: CGSize]())

    /// A change smaller than this, in points, is window-server rounding, not a resize.
    static let tolerance: CGFloat = 1.5

    static func record(target: String, size: CGSize) {
        sizes.withLock { $0[target] = size }
    }

    static func lastRead(target: String) -> CGSize? {
        sizes.withLock { $0[target] }
    }

    static func forget(target: String) {
        sizes.withLock { $0[target] = nil }
    }

    /// Why a point action must not run on a window now `current`, or nil when the last
    /// read was at the same size (or nothing was read yet).
    static func refusal(target: String, current: CGSize) -> String? {
        guard let read = lastRead(target: target),
              abs(read.width - current.width) > tolerance
                || abs(read.height - current.height) > tolerance else { return nil }
        let size = { (s: CGSize) in "\(Int(s.width.rounded()))x\(Int(s.height.rounded()))" }
        return "The '\(target)' window is now \(size(current)) points; the screen was last read at "
            + "\(size(read)), so coordinates from that read point elsewhere now. Nothing was sent. "
            + "Describe the screen again and use its coordinates."
    }
}
