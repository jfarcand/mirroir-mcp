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
// ABOUTME: The bytes of a server-sent event stream: the response head, one event per JSON-RPC message, and the keep-alive.
// ABOUTME: Also reads whether a request's Accept header allows an event stream.

import Foundation

/// Server-sent events, as the MCP Streamable HTTP transport uses them for a
/// reply that carries progress before its response.
enum SSEFrame {
    static let contentType = "text/event-stream"

    /// How often a quiet stream sends a comment, so nothing between the client
    /// and the server closes it for being idle.
    static let keepAliveInterval: TimeInterval = 15

    /// The status line and headers that open the stream. There is no
    /// `Content-Length`: the stream ends when the connection closes.
    static let head: Data = {
        let lines: [String] = [
            "HTTP/1.1 200 OK",
            "Cache-Control: no-cache",
            "Connection: close",
            "Content-Type: \(contentType)",
            "X-Accel-Buffering: no",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }()

    /// A comment line, which carries no event and keeps the stream open.
    static let keepAlive = Data(": keep-alive\n\n".utf8)

    /// One event carrying one JSON-RPC message. `json` must be on a single
    /// line, which `JSONEncoder` without pretty printing guarantees.
    static func event(_ json: Data) -> Data {
        Data("event: message\ndata: ".utf8) + json + Data("\n\n".utf8)
    }

    /// Whether an `Accept` header lists `text/event-stream` with a non-zero
    /// quality.
    static func allowsEventStream(accept: String?) -> Bool {
        guard let accept else { return false }
        return accept.split(separator: ",").contains { range in
            let parts = range.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first?.lowercased() == contentType else { return false }
            let quality = parts.dropFirst().first { $0.lowercased().hasPrefix("q=") }
                .flatMap { Double($0.dropFirst(2)) }
            return quality.map { $0 > 0 } ?? true
        }
    }
}
