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
// ABOUTME: Tests that each request relies only on the client capabilities that apply to it.
// ABOUTME: A 2026-07-28 request uses its own _meta; a legacy one the stdio handshake, and over HTTP nothing.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class MCPServerRequestScopeTests: XCTestCase {

    private let sampling: JSONValue = .object(["sampling": .object([:])])

    private func server(_ transport: MCPTransport) -> MCPServer {
        MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: transport)
    }

    private func initialize(_ server: MCPServer, capabilities: JSONValue) {
        _ = server.handleRequest(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "initialize",
            params: .object(["protocolVersion": .string("2025-11-25"), "capabilities": capabilities])))
    }

    private func legacyPing(_ server: MCPServer) {
        _ = server.handleRequest(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "ping", params: nil))
    }

    private func modernPing(_ server: MCPServer, capabilities: JSONValue) {
        _ = server.handleRequest(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(3), method: "ping",
            params: .object(["_meta": .object([
                MCPServer.MetaKey.protocolVersion: .string(MCPServer.modernProtocolVersions[0]),
                MCPServer.MetaKey.clientCapabilities: capabilities,
            ])])))
    }

    func testStdioLegacyRequestsKeepTheHandshake() {
        let server = server(.stdio)
        initialize(server, capabilities: sampling)
        legacyPing(server)
        XCTAssertTrue(server.clientSupportsSampling())
        XCTAssertTrue(server.maySendSamplingRequest())
    }

    func testModernRequestUsesOnlyItsOwnCapabilities() {
        let server = server(.stdio)
        initialize(server, capabilities: sampling)
        modernPing(server, capabilities: .object([:]))
        XCTAssertFalse(server.clientSupportsSampling(),
                       "the handshake does not speak for a request that declared nothing")
    }

    func testModernCapabilitiesDoNotLeakIntoTheNextRequest() {
        let server = server(.stdio)
        initialize(server, capabilities: .object([:]))
        modernPing(server, capabilities: sampling)
        XCTAssertTrue(server.clientSupportsSampling())
        XCTAssertFalse(server.maySendSamplingRequest(), "a 2026-07-28 request carries no sampling request")
        legacyPing(server)
        XCTAssertFalse(server.clientSupportsSampling(),
                       "the legacy request relies on its own handshake, which declared nothing")
    }

    func testHTTPHandshakeSpeaksForNoOtherRequest() {
        let server = server(.http)
        initialize(server, capabilities: sampling)
        legacyPing(server)
        XCTAssertFalse(server.clientSupportsSampling(),
                       "over HTTP one client's handshake must not decide what another may be asked")
        modernPing(server, capabilities: sampling)
        XCTAssertTrue(server.clientSupportsSampling(), "a 2026-07-28 request declares its own")
        XCTAssertFalse(server.maySendSamplingRequest(), "HTTP has no channel for a server request")
    }
}
