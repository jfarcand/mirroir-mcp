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
// ABOUTME: Tests for WindowSizeLedger (carnet#106): a point action is refused when the window
// ABOUTME: changed size since the screen was last read, and allowed when it did not.

import CoreGraphics
import XCTest
@testable import mirroir_mcp

final class WindowSizeLedgerTests: XCTestCase {

    private let target = "ledger-test-\(UUID().uuidString)"

    override func tearDown() {
        WindowSizeLedger.forget(target: target)
        super.tearDown()
    }

    func testNothingReadYetRefusesNothing() {
        XCTAssertNil(WindowSizeLedger.refusal(target: target, current: CGSize(width: 317, height: 699)))
    }

    func testTheSameSizeOrRoundingIsAllowed() {
        WindowSizeLedger.record(target: target, size: CGSize(width: 317, height: 699))
        XCTAssertNil(WindowSizeLedger.refusal(target: target, current: CGSize(width: 317, height: 699)))
        XCTAssertNil(WindowSizeLedger.refusal(target: target, current: CGSize(width: 318, height: 700)))
    }

    /// 2026-11-24/25: the window went 357x786 → 212x471 → 424x782 → 317x699 between calls.
    func testAResizeSinceTheReadIsRefusedWithBothSizes() {
        WindowSizeLedger.record(target: target, size: CGSize(width: 424, height: 782))
        let refusal = WindowSizeLedger.refusal(target: target, current: CGSize(width: 317, height: 699))
        XCTAssertEqual(refusal, "The '\(target)' window is now 317x699 points; the screen was last read at "
            + "424x782, so coordinates from that read point elsewhere now. Nothing was sent. "
            + "Describe the screen again and use its coordinates.")
    }

    func testANewReadAtTheNewSizeClearsTheRefusal() {
        WindowSizeLedger.record(target: target, size: CGSize(width: 424, height: 782))
        WindowSizeLedger.record(target: target, size: CGSize(width: 317, height: 699))
        XCTAssertNil(WindowSizeLedger.refusal(target: target, current: CGSize(width: 317, height: 699)))
    }
}
