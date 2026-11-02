// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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
