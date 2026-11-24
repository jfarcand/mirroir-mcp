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
// ABOUTME: Serves MCP over stdio: a reader thread routes each line while the calling thread runs requests in order.
// ABOUTME: A cancel reaches a running tool call at once; a cancelled call gets no response; progress is written as it comes.

import Foundation
import HelperLib

extension MCPServer {

    /// Serve the client on `input` and `output`, line-delimited JSON, until
    /// `input` ends. Requests run one at a time on the calling thread, in
    /// arrival order. A separate thread reads `input` the whole time, so a
    /// `notifications/cancelled` reaches a tool while it runs, and the answer
    /// to a sampling request reaches the call waiting for it.
    func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        let session = StdioSession(output: output)
        stdioSession.withLock { $0 = session }
        let loop = SerialJobLoop()
        let reader = Thread { [self] in
            Self.readLines(from: input) { line in route(line, session: session, loop: loop) }
            // The client is gone: nothing will answer a request we sent, and
            // the requests already received still run, in order.
            session.failWaiters()
            loop.close()
        }
        reader.name = "mirroir-mcp stdin"
        reader.start()
        loop.runUntilClosed()
        stdioSession.withLock { $0 = nil }
    }

    /// Hand one line to whoever acts on it.
    private func route(_ line: Data, session: StdioSession, loop: SerialJobLoop) {
        switch StdioLineClassifier.classify(line) {
        case .ignored:
            return
        case .malformed(let code, let message):
            // Answered in turn, so the error does not overtake the replies to
            // requests that arrived before the line.
            loop.submit { [self] in
                write(JSONRPCResponse(id: nil, result: nil, error: JSONRPCError(code: code, message: message)),
                      to: session)
            }
        case .clientResponse(let id, let answer):
            session.deliver(id, answer)
        case .cancel(let id, let reason):
            session.cancel(id, reason: reason)
        case .message(let request):
            guard request.method == "tools/call", let id = request.id else {
                loop.submit { [self] in
                    if let response = handleRequest(request) { write(response, to: session) }
                }
                return
            }
            // Registered now, on the reader's thread, so a cancel that arrives
            // while the call still waits its turn finds it.
            let call = MCPCallControl(
                progressToken: ProgressNotification.token(in: request.params),
                emit: { params in session.writeNotification(method: ProgressNotification.method, params: params) })
            session.begin(id, call: call)
            loop.submit { [self] in
                defer { session.end(id) }
                guard !call.isCancelled else { return }
                let response = handleRequest(request, call: call)
                if call.finish(), let response { write(response, to: session) }
            }
        }
    }

    private func write(_ response: JSONRPCResponse, to session: StdioSession) {
        do {
            session.write(try JSONEncoder().encode(response))
        } catch {
            DebugLog.log("MCPServer", "Failed to encode response: \(error)")
            session.write(Data(
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: response encoding failed"}}"#
                    .utf8))
        }
    }

    /// Call `body` with each line of `input`, without its newline, until the
    /// input ends.
    static func readLines(from input: FileHandle, _ body: (Data) -> Void) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<newline]
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                body(Data(line))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { body(buffer) }
    }
}
