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
// ABOUTME: Warn-once utility: prints each distinct warning message at most once per process.
// ABOUTME: Used by EnvConfig accessors, which re-read settings on every access, to report a bad value once.

import Foundation

/// Prints each distinct warning once per process. Settings are re-read on every
/// access, so without this a bad value would warn on every request.
final class OnceWarner: @unchecked Sendable {
    /// Shared across every EnvConfig accessor; the lock guards `printed`.
    static let shared = OnceWarner()

    private let lock = NSLock()
    private var printed: Set<String> = []
    private let sink: @Sendable (String) -> Void

    /// - Parameter sink: where a first-time message goes; stderr by default.
    init(sink: @escaping @Sendable (String) -> Void = { fputs($0, stderr) }) {
        self.sink = sink
    }

    /// Send `message` to the sink unless it was sent before.
    func warn(_ message: String) {
        lock.lock()
        let isFirst = printed.insert(message).inserted
        lock.unlock()
        if isFirst { sink(message) }
    }
}
