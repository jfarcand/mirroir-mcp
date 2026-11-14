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
// ABOUTME: Decorator around ScreenDescribing that drops a read the target window resized across.
// ABOUTME: A frame read while the mirror rotates places its elements in the old orientation.

import Foundation

/// Wraps a `ScreenDescribing`, returning nil for any read during which the
/// target window changed size. The mirror resizes when the device rotates — a
/// landscape game handing over to portrait Spotlight, say — and a frame read in
/// that window places every element in the orientation it is leaving, so its
/// tap points miss the window it lands in. Callers that poll treat nil as "read
/// again"; the next read sees one orientation from start to end.
final class WindowStableDescriber: ScreenDescribing, @unchecked Sendable {
    private let wrapped: any ScreenDescribing
    private let bridge: any WindowBridging

    init(wrapping describer: any ScreenDescribing, bridge: any WindowBridging) {
        self.wrapped = describer
        self.bridge = bridge
    }

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        let sizeBefore = bridge.getWindowInfo()?.size
        let result = wrapped.describe(settleTimeoutUs: settleTimeoutUs)
        guard bridge.getWindowInfo()?.size == sizeBefore else {
            DebugLog.log("describe", "dropped a read the window resized across (rotation)")
            return nil
        }
        return result
    }
}
