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
// ABOUTME: Reads the `at` argument of the scrolling tools: a point [x, y] inside the target window.
// ABOUTME: Shared by scroll_to and describe_screen's full-page read, so both accept and refuse the same points.

import CoreGraphics
import HelperLib

/// The `at` argument: the point to scroll at, for a list inside the screen.
enum ScrollAnchorArgument {

    /// What an `at` argument holds.
    enum Parsed: Equatable {
        /// No `at` was given: scroll the page.
        case absent
        /// A point inside the window.
        case point(CGPoint)
        /// Not a point inside the window; the message says what is expected.
        case invalid(String)
    }

    /// Read `value` against the window `bridge` reports.
    static func parse(_ value: JSONValue?, bridge: any WindowBridging) -> Parsed {
        guard let value else { return .absent }
        let window = bridge.getWindowInfo()?.size
        guard case .array(let pair) = value, pair.count == 2,
              let x = pair[0].asNumber(), let y = pair[1].asNumber(),
              let window,
              (0 ... window.width).contains(x), (0 ... window.height).contains(y) else {
            let size = window.map { "\(Int($0.width))x\(Int($0.height)) " } ?? ""
            return .invalid("at must be [x, y] inside the \(size)window")
        }
        return .point(CGPoint(x: x, y: y))
    }
}
