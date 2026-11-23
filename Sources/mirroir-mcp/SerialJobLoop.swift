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
// ABOUTME: Runs jobs one at a time, in arrival order, on the thread that runs the loop.
// ABOUTME: serve and stdio both hand it their requests, so tool handlers run on the main thread.

import Foundation

/// Runs jobs one at a time, in the order they were handed over, on the thread
/// that runs the loop. Both transports run it on the main thread, so a tool
/// handler runs there while requests arrive on other threads.
final class SerialJobLoop: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var closed = false

    /// Hand `work` to the loop's thread and wait for what it returns.
    func perform<Value: Sendable>(_ work: @escaping @Sendable () -> Value?) -> Value? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<Value>()
        submit {
            box.value = work()
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// Hand `job` to the loop's thread without waiting for it.
    func submit(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    /// Accept no more jobs: `runUntilClosed` returns once those already
    /// handed over have run.
    func close() {
        condition.lock()
        closed = true
        condition.signal()
        condition.unlock()
    }

    /// Run jobs on the calling thread until the process exits.
    func run() -> Never {
        while true { next()?() }
    }

    /// Run jobs on the calling thread until the loop is closed and empty.
    func runUntilClosed() {
        while let job = next() { job() }
    }

    /// Wait for the oldest job; nil once the loop is closed and empty.
    private func next() -> (@Sendable () -> Void)? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty {
            if closed { return nil }
            condition.wait()
        }
        return jobs.removeFirst()
    }

    /// Carries one result from the loop's thread to the thread that asked.
    private final class ResultBox<Value>: @unchecked Sendable {
        var value: Value?
    }
}
