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
// ABOUTME: Tests for FieldClearing: Cmd+A then Delete empties the focused field before typing.
// ABOUTME: A select-all or delete that fails stops there, so nothing is deleted or typed after it.

import XCTest
@testable import mirroir_mcp

final class FieldClearingTests: XCTestCase {

    private var input: StubInput!

    override func setUp() {
        super.setUp()
        input = StubInput()
    }

    func testClearSelectsAllThenDeletes() {
        let result = FieldClearing.clear(using: input)
        XCTAssertTrue(result.success)
        XCTAssertEqual(input.keyboardLog, ["key:command+a", "key:delete"])
    }

    func testTypeWithClearClearsBeforeTyping() {
        let result = FieldClearing.type("Burger", clearFirst: true, using: input)
        XCTAssertTrue(result.success)
        XCTAssertEqual(input.keyboardLog, ["key:command+a", "key:delete", "type:Burger"])
    }

    func testTypeWithoutClearOnlyTypes() {
        _ = FieldClearing.type("Burger", clearFirst: false, using: input)
        XCTAssertEqual(input.keyboardLog, ["type:Burger"])
    }

    func testAFailedSelectAllDeletesAndTypesNothing() {
        input.pressKeyResultByKey["a"] = TypeResult(success: false, error: "key dropped")
        let result = FieldClearing.type("Burger", clearFirst: true, using: input)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Could not select the field's text (Cmd+A): key dropped")
        XCTAssertEqual(input.keyboardLog, ["key:command+a"])
    }

    func testAFailedDeleteTypesNothing() {
        input.pressKeyResultByKey["delete"] = TypeResult(success: false, error: nil)
        let result = FieldClearing.type("Burger", clearFirst: true, using: input)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Could not delete the field's text (Delete): key not delivered")
        XCTAssertEqual(input.keyboardLog, ["key:command+a", "key:delete"])
    }
}
