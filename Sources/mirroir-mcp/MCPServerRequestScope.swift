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
// ABOUTME: The revision and client capabilities that apply to the one request being served.
// ABOUTME: A 2026-07-28 request brings its own; a legacy one uses the stdio handshake, and over HTTP has none.

import Foundation
import HelperLib

/// What the request being served may rely on: which revision it speaks and
/// which client capabilities it declared.
struct RequestScope: Sendable, Equatable {
    /// Whether the request carries the `2026-07-28` `_meta`.
    let modern: Bool
    /// The `ClientCapabilities` that apply to it, or nil when none were declared.
    let capabilities: JSONValue?

    /// Before any request has been served.
    static let none = RequestScope(modern: false, capabilities: nil)
}

extension MCPServer {

    /// The scope a request runs under. A stateless-era request declares its
    /// capabilities in its own `_meta`, and the server must not rely on any it
    /// did not declare there. A legacy request relies on its `initialize`
    /// handshake, which only stdio keeps.
    func scope(for request: JSONRPCRequest, modern: Bool) -> RequestScope {
        guard !modern else {
            let declared = request.params?.member("_meta")?.member(MetaKey.clientCapabilities)
            return RequestScope(modern: true, capabilities: declared)
        }
        return RequestScope(modern: false, capabilities: handshakeCapabilities.withLock { $0 })
    }

    /// Keep the capabilities an `initialize` handshake declared, for the legacy
    /// requests that follow it. Only on stdio, where one process serves one
    /// client: over HTTP every client shares the process, and a handshake from
    /// one must not speak for another.
    func recordHandshake(_ capabilities: JSONValue?) {
        guard transport == .stdio else { return }
        handshakeCapabilities.withLock { $0 = capabilities }
        currentScope.withLock { $0 = RequestScope(modern: false, capabilities: capabilities) }
    }

    /// Whether the request being served carries the `2026-07-28` `_meta`.
    func isServingModernRequest() -> Bool {
        currentScope.withLock { $0.modern }
    }

    /// Whether the request being served declared the `sampling` capability.
    func clientSupportsSampling() -> Bool {
        currentScope.withLock { $0.capabilities?.member("sampling") != nil }
    }

    /// Whether a server-initiated request may be written to stdout right now.
    /// Only on stdio, where stdout reaches the client: over HTTP there is no
    /// channel to write one on. And never while serving a `2026-07-28`
    /// request: that revision's server writes only responses and
    /// notifications, and reaches the client through `InputRequiredResult`.
    func mayInitiateRequest() -> Bool {
        transport == .stdio && !isServingModernRequest()
    }

    /// Whether a `sampling/createMessage` request may be sent to the client
    /// right now: it declared sampling, and a server request can reach it.
    func maySendSamplingRequest() -> Bool {
        clientSupportsSampling() && mayInitiateRequest()
    }
}
