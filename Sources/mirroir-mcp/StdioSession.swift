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
// ABOUTME: The stdio connection's shared state: the one writer to stdout, the tool calls in flight, and our requests awaiting answers.
// ABOUTME: The reader thread cancels calls and delivers answers here while the main thread runs tools.

import Foundation
import HelperLib

/// What the stdio reader thread and the thread running tools share.
///
/// Every line written to the client goes through `write`, so a progress
/// notification from a tool and a response never interleave. Tool calls in
/// flight are registered by id, so a `notifications/cancelled` reaches the one
/// it names. A request this server sends (sampling) waits here for the answer
/// with its id, which the reader delivers.
final class StdioSession: @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle
    private var calls: [RequestID: MCPCallControl] = [:]
    private var waiters: [RequestID: Waiter] = [:]

    init(output: FileHandle) {
        self.output = output
    }

    // MARK: - Writing

    /// Write one JSON message as a line.
    func write(_ data: Data) {
        lock.withLock {
            output.write(data + Data("\n".utf8))
        }
    }

    /// Write one notification as a line.
    func writeNotification(method: String, params: JSONValue) {
        let message: JSONValue = .object([
            "jsonrpc": .string("2.0"), "method": .string(method), "params": params,
        ])
        guard let data = try? JSONEncoder().encode(message) else {
            DebugLog.log("MCPServer", "Failed to encode \(method)")
            return
        }
        write(data)
    }

    // MARK: - Calls in flight

    /// Register a tool call so a cancel naming its id reaches it.
    func begin(_ id: RequestID, call: MCPCallControl) {
        lock.withLock { calls[id] = call }
    }

    /// Forget a call once it has ended.
    func end(_ id: RequestID) {
        _ = lock.withLock { calls.removeValue(forKey: id) }
    }

    /// Cancel the call `id` names. A cancel for an unknown or finished call is
    /// ignored, as the protocol says. The call being cancelled is the one that
    /// may be waiting on an answer from the client, so those waits end too.
    func cancel(_ id: RequestID, reason: String?) {
        guard let call = lock.withLock({ calls[id] }) else {
            DebugLog.log("MCPServer", "Ignoring a cancel for \(id), which is not running")
            return
        }
        DebugLog.log("MCPServer", "Cancelled \(id): \(reason ?? "no reason given")")
        call.cancel(reason: reason)
        failWaiters()
    }

    // MARK: - Answers to our requests

    /// Start waiting for the client's answer to the request `id`. Register
    /// before writing the request, so a fast answer is not missed.
    func expect(_ id: RequestID) -> Waiter {
        let waiter = Waiter()
        lock.withLock { waiters[id] = waiter }
        return waiter
    }

    /// Hand the client's answer to whoever waits for it. An answer nothing
    /// waits for (late, or for a wait that ended) is dropped.
    func deliver(_ id: RequestID, _ answer: [String: Any]) {
        guard let waiter = lock.withLock({ waiters.removeValue(forKey: id) }) else {
            DebugLog.log("MCPServer", "Ignoring an answer to \(id), which nothing waits for")
            return
        }
        waiter.resolve(answer)
    }

    /// End every wait with no answer: the client left, or the call was cancelled.
    func failWaiters() {
        let pending = lock.withLock { () -> [Waiter] in
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        pending.forEach { $0.resolve(nil) }
    }

    /// One wait for the client's answer to a request this server sent.
    final class Waiter: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var answer: [String: Any]?
        private var resolved = false

        /// Block until the answer arrives or the wait is ended; nil when ended.
        func wait() -> [String: Any]? {
            done.wait()
            return lock.withLock { answer }
        }

        fileprivate func resolve(_ answer: [String: Any]?) {
            let first = lock.withLock { () -> Bool in
                guard !resolved else { return false }
                resolved = true
                self.answer = answer
                return true
            }
            if first { done.signal() }
        }
    }
}
