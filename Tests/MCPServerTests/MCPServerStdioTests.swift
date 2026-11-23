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
// ABOUTME: Drives the stdio server over pipes, as a client would: cancel a running call, read its progress, answer a sampling request.
// ABOUTME: Also checks the line classifier and that the server returns once its input ends.

import XCTest
import HelperLib
import os
@testable import mirroir_mcp

final class MCPServerStdioTests: XCTestCase {

    /// A stdio server on pipes, running on its own thread.
    private final class Connection: @unchecked Sendable {
        let server: MCPServer
        private let input = Pipe()
        private let output = Pipe()
        private let linesLock = NSLock()
        private var lines: [[String: Any]] = []
        private let finished = DispatchSemaphore(value: 0)

        init(server: MCPServer) {
            self.server = server
            let output = output
            Thread { [input] in
                server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
                try? output.fileHandleForWriting.close()
                self.finished.signal()
            }.start()
            Thread {
                MCPServer.readLines(from: output.fileHandleForReading) { line in
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                    self.linesLock.withLock { self.lines.append(object) }
                }
            }.start()
        }

        func send(_ json: String) {
            input.fileHandleForWriting.write(Data((json + "\n").utf8))
        }

        func close() {
            try? input.fileHandleForWriting.close()
        }

        /// Wait until the server returned from `run`.
        func waitForEnd(timeout: TimeInterval = 10) -> Bool {
            finished.wait(timeout: .now() + timeout) == .success
        }

        var received: [[String: Any]] { linesLock.withLock { lines } }

        /// Wait until a line matching `predicate` has arrived.
        func waitFor(timeout: TimeInterval = 10, _ predicate: ([String: Any]) -> Bool) -> [String: Any]? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let match = received.first(where: predicate) { return match }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }
    }

    private func makeServer() -> MCPServer {
        MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .stdio)
    }

    private func id(_ line: [String: Any]) -> Int? { line["id"] as? Int }

    /// A tool that reports progress and runs until it is cancelled, up to a bound.
    private func registerSlowTool(on server: MCPServer, iterations: OSAllocatedUnfairLock<Int>,
                                  started: DispatchSemaphore) {
        server.registerTool(MCPToolDefinition(
            name: "slow", description: "Loops until cancelled.", inputSchema: [:],
            contextualHandler: { _, context in
                started.signal()
                for step in 1 ... 500 {
                    if context.call.isCancelled { return .text("stopped") }
                    iterations.withLock { $0 = step }
                    context.call.report(progress: Double(step), total: 500)
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return .text("ran to the end")
            }))
    }

    private let slowCall = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow","arguments":{},"_meta":{"progressToken":"tok"}}}"#

    func testACancelStopsARunningCallAndItGetsNoResponse() {
        let server = makeServer()
        let iterations = OSAllocatedUnfairLock(initialState: 0)
        let started = DispatchSemaphore(value: 0)
        registerSlowTool(on: server, iterations: iterations, started: started)
        let connection = Connection(server: server)

        connection.send(slowCall)
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        connection.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"user"}}"#)
        connection.send(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)

        XCTAssertNotNil(connection.waitFor { self.id($0) == 6 }, "the next request is served")
        XCTAssertLessThan(iterations.withLock { $0 }, 500, "the tool stopped at its next check")
        connection.close()
        XCTAssertTrue(connection.waitForEnd())
        XCTAssertFalse(connection.received.contains { id($0) == 5 }, "a cancelled call gets no response")
    }

    func testProgressPrecedesTheResponseAndRises() {
        let server = makeServer()
        server.registerTool(MCPToolDefinition(
            name: "steps", description: "Reports three steps.", inputSchema: [:],
            contextualHandler: { _, context in
                for step in 1 ... 3 { context.call.report(progress: Double(step), total: 3) }
                return .text("done")
            }))
        let connection = Connection(server: server)
        connection.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"steps","arguments":{},"_meta":{"progressToken":7}}}"#)
        XCTAssertNotNil(connection.waitFor { self.id($0) == 1 })
        connection.close()
        XCTAssertTrue(connection.waitForEnd())

        let received = connection.received
        let responseIndex = received.firstIndex { id($0) == 1 } ?? -1
        let progress = received.enumerated().filter { $0.element["method"] as? String == ProgressNotification.method }
        XCTAssertEqual(progress.map { ($0.element["params"] as? [String: Any])?["progress"] as? Double }, [1, 2, 3])
        XCTAssertEqual(progress.compactMap { ($0.element["params"] as? [String: Any])?["progressToken"] as? Int },
                       [7, 7, 7])
        XCTAssertTrue(progress.allSatisfy { $0.offset < responseIndex }, "no progress after the response")
    }

    func testACancelForAQueuedCallSkipsIt() {
        let server = makeServer()
        let iterations = OSAllocatedUnfairLock(initialState: 0)
        let started = DispatchSemaphore(value: 0)
        registerSlowTool(on: server, iterations: iterations, started: started)
        let ran = OSAllocatedUnfairLock(initialState: 0)
        server.registerTool(MCPToolDefinition(
            name: "count", description: "Counts.", inputSchema: [:],
            handler: { _ in ran.withLock { $0 += 1 }; return .text("ran") }))
        let connection = Connection(server: server)

        connection.send(slowCall)
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        connection.send(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"count","arguments":{}}}"#)
        connection.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":8}}"#)
        connection.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#)
        connection.close()
        XCTAssertTrue(connection.waitForEnd())
        XCTAssertEqual(ran.withLock { $0 }, 0, "the queued call was cancelled before its turn")
        XCTAssertFalse(connection.received.contains { id($0) == 8 })
    }

    func testASamplingAnswerIsMatchedByIdAcrossOtherLines() {
        let server = makeServer()
        let answer = OSAllocatedUnfairLock(initialState: String?.none)
        server.registerTool(MCPToolDefinition(
            name: "ask", description: "Asks the client's model.", inputSchema: [:],
            handler: { _ in
                let reply = server.sendSamplingRequest(SamplingParams(
                    messages: [SamplingMessage(role: "user", content: .text("hi"))], maxTokens: 8, systemPrompt: nil))
                answer.withLock { $0 = reply }
                return .text(reply ?? "none")
            }))
        let connection = Connection(server: server)
        connection.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"sampling":{}}}}"#)
        connection.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask","arguments":{}}}"#)
        guard let request = connection.waitFor({ $0["method"] as? String == "sampling/createMessage" }),
              let samplingID = request["id"] as? Int else {
            return XCTFail("expected a sampling request")
        }
        connection.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        connection.send(#"{"jsonrpc":"2.0","id":\#(samplingID + 100),"result":{"content":{"type":"text","text":"wrong"}}}"#)
        connection.send(#"{"jsonrpc":"2.0","id":\#(samplingID),"result":{"content":{"type":"text","text":"right"}}}"#)
        XCTAssertNotNil(connection.waitFor { self.id($0) == 2 })
        XCTAssertEqual(answer.withLock { $0 }, "right")
        connection.close()
        XCTAssertTrue(connection.waitForEnd())
    }

    func testTheServerReturnsWhenInputEnds() {
        let connection = Connection(server: makeServer())
        connection.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        connection.close()
        XCTAssertTrue(connection.waitForEnd())
        XCTAssertNotNil(connection.waitFor { self.id($0) == 1 }, "requests already received still run")
    }

    // MARK: - Line classifier

    func testLinesAreSortedBeforeDecoding() {
        func classify(_ text: String) -> StdioLine { StdioLineClassifier.classify(Data(text.utf8)) }
        guard case .malformed(-32700, _) = classify("nope") else { return XCTFail("not JSON") }
        guard case .malformed(-32600, _) = classify("[1]") else { return XCTFail("a batch") }
        guard case .clientResponse(.number(4), _) = classify(#"{"jsonrpc":"2.0","id":4,"result":{}}"#) else {
            return XCTFail("an answer to our request")
        }
        guard case .cancel(.string("a"), "why") = classify(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"a","reason":"why"}}"#)
        else { return XCTFail("a cancel") }
        guard case .ignored = classify(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#) else {
            return XCTFail("a cancel naming nothing")
        }
        guard case .message(let request) = classify(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) else {
            return XCTFail("a request")
        }
        XCTAssertEqual(request.method, "ping")
        guard case .ignored = classify("") else { return XCTFail("an empty line") }
    }
}
