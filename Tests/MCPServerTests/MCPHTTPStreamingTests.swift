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
// ABOUTME: Tests the HTTP endpoint's event-stream replies (progress, then the response) and that a client leaving cancels its call.
// ABOUTME: Also covers the SSE framing, the Accept check, and the job loop that runs both transports' calls.

import XCTest
import HelperLib
import os
@testable import mirroir_mcp

final class MCPHTTPStreamingTests: XCTestCase {

    private static let token = String(repeating: "s", count: ServeToken.minimumLength)

    private func makeServer() -> MCPServer {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .http)
        server.registerTool(MCPToolDefinition(
            name: "steps", description: "Reports two steps.", inputSchema: [:],
            contextualHandler: { _, context in
                context.call.report(progress: 1, total: 2)
                context.call.report(progress: 2, total: 2)
                return .text("done")
            }))
        return server
    }

    private func toolCall(accept: String?, token: Bool) -> HTTPRequest {
        let meta = token ? #","_meta":{"progressToken":"p"}"# : ""
        var headers = ["authorization": "Bearer " + Self.token, "content-type": "application/json"]
        headers["accept"] = accept
        return HTTPRequest(
            method: "POST", path: "/mcp", headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"steps","arguments":{}\#(meta)}}"#.utf8))
    }

    private func reply(_ request: HTTPRequest, server: MCPServer, channel: RecordingExchangeChannel) -> HTTPReply {
        MCPHTTPEndpoint.respond(
            to: request, config: MCPHTTPEndpoint.Config(token: Self.token, allowedOrigins: []), channel: channel
        ) { rpc, call in server.handleRequest(rpc, call: call) }
    }

    private func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testProgressStreamsAsEventsThenTheResponse() {
        let channel = RecordingExchangeChannel()
        let result = reply(toolCall(accept: "application/json, text/event-stream", token: true),
                           server: makeServer(), channel: channel)
        XCTAssertEqual(result, .streamEnded)
        let events = channel.events.compactMap(object)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.prefix(2).map { $0["method"] as? String }, [ProgressNotification.method,
                                                                         ProgressNotification.method])
        XCTAssertEqual(events.last?["id"] as? Int, 3, "the response is the last event")
        XCTAssertTrue(channel.events.allSatisfy { !$0.contains(UInt8(ascii: "\n")) }, "one line per event")
    }

    func testWithoutAnEventStreamOrATokenTheReplyIsOneJSONBody() {
        for (accept, token) in [("application/json", true), ("application/json, text/event-stream", false)] {
            let channel = RecordingExchangeChannel()
            let result = reply(toolCall(accept: accept, token: token), server: makeServer(), channel: channel)
            XCTAssertEqual(result.whole?.status, 200, accept)
            XCTAssertTrue(channel.events.isEmpty, accept)
        }
    }

    func testAClientLeavingCancelsTheRunningCall() {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .http)
        let channel = RecordingExchangeChannel()
        let sawCancel = OSAllocatedUnfairLock(initialState: false)
        server.registerTool(MCPToolDefinition(
            name: "steps", description: "Leaves, then checks.", inputSchema: [:],
            contextualHandler: { _, context in
                channel.depart()
                sawCancel.withLock { $0 = context.call.isCancelled }
                return .text("finished anyway")
            }))
        let result = reply(toolCall(accept: nil, token: false), server: server, channel: channel)
        XCTAssertTrue(sawCancel.withLock { $0 }, "the tool sees the cancel at its next check")
        XCTAssertEqual(result.whole?.status, 202, "nobody is left to answer")
        XCTAssertTrue(result.whole?.body.isEmpty ?? false)
    }

    // MARK: - Framing

    func testEventFraming() {
        let event = String(decoding: SSEFrame.event(Data(#"{"a":1}"#.utf8)), as: UTF8.self)
        XCTAssertEqual(event, "event: message\ndata: {\"a\":1}\n\n")
        let head = String(decoding: SSEFrame.head, as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("Content-Type: text/event-stream\r\n"))
        XCTAssertTrue(head.contains("X-Accel-Buffering: no\r\n"))
        XCTAssertFalse(head.contains("Content-Length"), "the stream ends when the connection closes")
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
    }

    func testAcceptMustListTheEventStream() {
        XCTAssertTrue(SSEFrame.allowsEventStream(accept: "application/json, text/event-stream"))
        XCTAssertTrue(SSEFrame.allowsEventStream(accept: "TEXT/EVENT-STREAM;q=0.5"))
        XCTAssertFalse(SSEFrame.allowsEventStream(accept: "text/event-stream;q=0"))
        XCTAssertFalse(SSEFrame.allowsEventStream(accept: "application/json"))
        XCTAssertFalse(SSEFrame.allowsEventStream(accept: nil))
    }

    // MARK: - Job loop

    func testAClosedLoopRunsWhatItHasThenReturns() {
        let loop = SerialJobLoop()
        let ran = OSAllocatedUnfairLock(initialState: [Int]())
        for index in 1 ... 3 { loop.submit { ran.withLock { $0.append(index) } } }
        loop.close()
        loop.runUntilClosed()
        XCTAssertEqual(ran.withLock { $0 }, [1, 2, 3])
    }
}
