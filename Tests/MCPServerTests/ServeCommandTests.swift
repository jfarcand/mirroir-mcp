// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the `mirroir-mcp serve` command line and for the loop that runs tool calls one at a time.
// ABOUTME: Parsing only; the listener and the endpoint have their own suites.

import XCTest
import HelperLib
import os
@testable import mirroir_mcp

final class ServeCommandTests: XCTestCase {

    func testDefaults() throws {
        let config = try ServeCommand.parseArguments([])
        XCTAssertEqual(config.port, 8765)
        XCTAssertEqual(config.tokenFile, ServeToken.defaultPath)
        XCTAssertTrue(ServeToken.defaultPath.hasSuffix("/.mirroir-mcp/serve-token"))
        XCTAssertEqual(config.allowedOrigins, [], "no browser origin is accepted unless named")
    }

    func testRejectsANonNumericPort() {
        for raw in ["abc", "0", "65536", "-1", "80.5"] {
            XCTAssertThrowsError(try ServeCommand.parseArguments(["--port", raw]), raw)
        }
        XCTAssertThrowsError(try ServeCommand.parseArguments(["--port", "abc"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .invalidValue(
                flag: "--port", value: "abc", expected: "a port number from 1 to 65535"))
        }
        XCTAssertEqual(try ServeCommand.parseArguments(["--port", "9000"]).port, 9000)
    }

    func testRepeatedAllowOriginAccumulates() throws {
        let config = try ServeCommand.parseArguments(
            ["--allow-origin", "http://localhost:3000", "--allow-origin", "https://app.example"])
        XCTAssertEqual(config.allowedOrigins, ["http://localhost:3000", "https://app.example"])
    }

    func testTokenFileExpandsTheTilde() throws {
        let config = try ServeCommand.parseArguments(["--token-file", "~/elsewhere/token"])
        XCTAssertEqual(config.tokenFile, NSHomeDirectory() + "/elsewhere/token")
    }

    /// Over HTTP the permission file is the only way to open a tool.
    func testSkippingPermissionsIsRefused() {
        for option in PermissionPolicy.skipPermissionsOptions {
            XCTAssertThrowsError(try ServeCommand.parseArguments([option]), option) {
                XCTAssertEqual($0 as? ServeArgumentError, .skipPermissionsRefused(option))
            }
        }
    }

    func testThereIsNoOptionToBindAnotherAddress() {
        for option in ["--bind", "--host", "--address"] {
            XCTAssertThrowsError(try ServeCommand.parseArguments([option, "0.0.0.0"]), option) {
                XCTAssertEqual($0 as? CLIArgumentError, .unknownOption(option, command: "serve"))
            }
        }
    }

    // MARK: - Responder

    /// A call whose client left before its turn never reaches a tool.
    func testAnAbandonedCallIsNotRun() {
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        let server = MCPServer(policy: policy, transport: .http)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        server.registerTool(MCPToolDefinition(
            name: "probe", description: "Counts its calls.",
            inputSchema: ["type": .string("object"), "properties": .object([:])],
            handler: { _ in
                calls.withLock { $0 += 1 }
                return .text("ran")
            }))
        let loop = SerialJobLoop()
        Thread { loop.run() }.start()
        let token = String(repeating: "k", count: ServeToken.minimumLength)
        let responder = ServeCommand.responder(
            for: server, endpoint: MCPHTTPEndpoint.Config(token: token, allowedOrigins: []), on: loop)
        let request = HTTPRequest(
            method: "POST", path: "/mcp",
            headers: ["authorization": "Bearer " + token, "content-type": "application/json"],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"probe","arguments":{}}}"#.utf8))

        XCTAssertNil(responder.refuse(request))
        _ = responder.respond(request) { true }
        XCTAssertEqual(calls.withLock { $0 }, 0, "nobody is waiting, so the phone is not touched")
        XCTAssertEqual(responder.respond(request) { false }.status, 200)
        XCTAssertEqual(calls.withLock { $0 }, 1)

        let unauthenticated = HTTPRequest(method: "POST", path: "/mcp", headers: [:], body: Data())
        XCTAssertEqual(responder.refuse(unauthenticated)?.status, 401)
    }

    // MARK: - SerialJobLoop

    func testTheLoopRunsJobsOneAtATimeInOrderOnItsOwnThread() {
        let loop = SerialJobLoop()
        let loopThread = Thread { loop.run() }
        loopThread.start()

        let record = Recorder()
        let submitted = DispatchGroup()
        let callers = DispatchQueue(label: "serve-tests.callers", attributes: .concurrent)
        for index in 0..<8 {
            submitted.enter()
            callers.async {
                let echoed: Int? = loop.perform {
                    record.enter()
                    Thread.sleep(forTimeInterval: 0.01)
                    record.leave(on: Thread.current)
                    return index
                }
                XCTAssertEqual(echoed, index, "each caller gets its own result")
                submitted.leave()
            }
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(record.maxConcurrent, 1, "never two jobs at once")
        XCTAssertEqual(record.threads, [loopThread], "every job ran on the loop's thread")
        XCTAssertEqual(record.completed, 8)
    }

    func testANilResultIsReturnedAsNil() {
        let loop = SerialJobLoop()
        Thread { loop.run() }.start()
        let nothing: Int? = loop.perform { nil }
        XCTAssertNil(nothing, "a notification's absent response passes through")
    }

    /// Counts how many jobs overlap and which threads ran them.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var maxConcurrent = 0
        private(set) var completed = 0
        private(set) var threads: Set<Thread> = []

        func enter() {
            lock.withLock {
                running += 1
                maxConcurrent = max(maxConcurrent, running)
            }
        }

        func leave(on thread: Thread) {
            lock.withLock {
                running -= 1
                completed += 1
                threads.insert(thread)
            }
        }
    }
}
