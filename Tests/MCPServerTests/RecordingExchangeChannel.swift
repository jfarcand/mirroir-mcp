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
// ABOUTME: An HTTP exchange channel for tests: records the events a responder streams and lets a test play the client leaving.
// ABOUTME: Stands in for NetworkHTTPServer's connection, which needs a real socket.

import Foundation
import os
@testable import mirroir_mcp

/// A connection a test controls. Mocked because the real channel lives on a
/// socket; `NetworkHTTPServerTests` covers that one end to end.
final class RecordingExchangeChannel: HTTPExchangeChannel, @unchecked Sendable {
    private struct State {
        var departed = false
        var hooks: [@Sendable () -> Void] = []
        var events: [Data] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(departed: Bool = false) {
        state.withLock { $0.departed = departed }
    }

    var isAbandoned: Bool { state.withLock { $0.departed } }

    /// The events streamed so far, each one JSON message.
    var events: [Data] { state.withLock { $0.events } }

    func onAbandon(_ hook: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { state -> Bool in
            if state.departed { return true }
            state.hooks.append(hook)
            return false
        }
        if runNow { hook() }
    }

    func sendEvent(_ json: Data) {
        state.withLock { $0.events.append(json) }
    }

    /// Play the client closing its connection.
    func depart() {
        let hooks = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.departed else { return [] }
            state.departed = true
            defer { state.hooks = [] }
            return state.hooks
        }
        hooks.forEach { $0() }
    }
}

extension HTTPReply {
    /// The whole response, for tests of replies that do not stream.
    var whole: HTTPResponse? {
        if case .whole(let response) = self { return response }
        return nil
    }
}
