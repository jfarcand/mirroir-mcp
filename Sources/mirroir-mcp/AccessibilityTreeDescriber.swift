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
// ABOUTME: Adds the exact text a macOS app reports through its accessibility tree to what a describer read from pixels.
// ABOUTME: A decorator for macOS window targets only: iPhone Mirroring's tree is opaque, so the iPhone stays on OCR.

import Foundation
import HelperLib

/// Decorates a describer for a macOS app window: its elements gain the text
/// the app itself reports, marked `.tree`, and lose the pixel readings of
/// that same text. When the tree cannot be read the pixel result is returned
/// as it is, with the reason, so a caller is never told text is exact when it
/// is not.
final class AccessibilityTreeDescriber: ScreenDescribing, Sendable {
    private let wrapped: any ScreenDescribing
    private let bridge: any WindowBridging
    private let reader: any AccessibilityTextReading

    init(wrapping wrapped: any ScreenDescribing, bridge: any WindowBridging,
         reader: any AccessibilityTextReading = LiveAccessibilityTextReader()) {
        self.wrapped = wrapped
        self.bridge = bridge
        self.reader = reader
    }

    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult? {
        guard let result = wrapped.describe(settleTimeoutUs: settleTimeoutUs) else { return nil }
        guard let window = bridge.getWindowInfo() else { return result }
        switch reader.readText(in: window) {
        case .failure(let unreadable):
            return result.withTree(elements: result.elements, failure: unreadable.reason, truncated: false)
        case .success(let snapshot):
            return result.withTree(
                elements: AccessibilityTreeText.merge(
                    snapshot: snapshot, pixels: result.elements, windowSize: window.size),
                failure: nil, truncated: snapshot.truncated)
        }
    }
}
