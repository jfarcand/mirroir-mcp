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
// ABOUTME: Tests a tool call's control: progress only rises and stops at the end, cancel hooks fire once.
// ABOUTME: Also covers reading the progress token from a request's _meta.

import XCTest
import os
import HelperLib

final class MCPCallControlTests: XCTestCase {

    /// Collects what a control emits.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [JSONValue] = []
        var emitted: [JSONValue] { lock.withLock { items } }
        lazy var emit: MCPCallControl.Emit = { [unowned self] params in
            self.lock.withLock { self.items.append(params) }
        }
    }

    func testProgressMustRise() {
        let sink = Sink()
        let call = MCPCallControl(progressToken: .string("t"), emit: sink.emit)
        call.report(progress: 1, total: 3)
        call.report(progress: 1, total: 3)
        call.report(progress: 0.5)
        call.report(progress: 2, total: 3, message: "step 2")
        let progress = sink.emitted.compactMap { $0.member("progress") }
        XCTAssertEqual(progress, [.number(1), .number(2)])
        XCTAssertEqual(sink.emitted.last?.member("message"), .string("step 2"))
        XCTAssertEqual(sink.emitted.last?.member("total"), .number(3))
        XCTAssertEqual(sink.emitted.last?.member("progressToken"), .string("t"))
    }

    func testNoProgressWithoutAToken() {
        let sink = Sink()
        let call = MCPCallControl(progressToken: nil, emit: sink.emit)
        call.report(progress: 1)
        XCTAssertTrue(sink.emitted.isEmpty)
    }

    func testNoProgressAfterFinishOrCancel() {
        let sink = Sink()
        let finished = MCPCallControl(progressToken: .number(7), emit: sink.emit)
        XCTAssertTrue(finished.finish())
        finished.report(progress: 1)
        let cancelled = MCPCallControl(progressToken: .number(8), emit: sink.emit)
        cancelled.cancel(reason: nil)
        cancelled.report(progress: 1)
        XCTAssertTrue(sink.emitted.isEmpty)
    }

    func testACancelledCallGetsNoResponse() {
        let call = MCPCallControl()
        call.cancel(reason: "user stopped it")
        XCTAssertTrue(call.isCancelled)
        XCTAssertEqual(call.cancelReason, "user stopped it")
        XCTAssertFalse(call.finish())
    }

    func testCancelAfterFinishIsIgnored() {
        let call = MCPCallControl()
        XCTAssertTrue(call.finish())
        call.cancel(reason: "late")
        XCTAssertFalse(call.isCancelled, "a cancel that arrives after the response changes nothing")
    }

    func testCancelHooksFireOnceEvenWhenRegisteredLate() {
        let call = MCPCallControl()
        let fired = OSAllocatedUnfairLock(initialState: 0)
        call.onCancel { fired.withLock { $0 += 1 } }
        call.cancel(reason: nil)
        call.cancel(reason: nil)
        XCTAssertEqual(fired.withLock { $0 }, 1)
        call.onCancel { fired.withLock { $0 += 1 } }
        XCTAssertEqual(fired.withLock { $0 }, 2, "a hook added after the cancel runs at once")
    }

    func testTokenIsAStringOrAnInteger() {
        func params(_ token: JSONValue) -> JSONValue { .object(["_meta": .object(["progressToken": token])]) }
        XCTAssertEqual(ProgressNotification.token(in: params(.string("a"))), .string("a"))
        XCTAssertEqual(ProgressNotification.token(in: params(.number(3))), .number(3))
        XCTAssertNil(ProgressNotification.token(in: params(.number(1.5))))
        XCTAssertNil(ProgressNotification.token(in: params(.bool(true))))
        XCTAssertNil(ProgressNotification.token(in: .object([:])))
    }
}
