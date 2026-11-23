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
// ABOUTME: Tests the 2026-07-28 rules on tool listing order and on a tool that needs an undeclared client capability.
// ABOUTME: Also covers how classify_screen picks a model for each revision and transport.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class MCPServerConformanceTests: XCTestCase {

    private func makeServer() -> MCPServer {
        MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .stdio)
    }

    private func modernRequest(method: String, params: [String: JSONValue] = [:]) -> JSONRPCRequest {
        var withMeta = params
        withMeta["_meta"] = .object([
            MCPServer.MetaKey.protocolVersion: .string(MCPServer.modernProtocolVersions[0]),
            MCPServer.MetaKey.clientCapabilities: .object([:]),
        ])
        return JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: method, params: .object(withMeta))
    }

    private func legacyRequest(method: String, params: [String: JSONValue] = [:]) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: method, params: .object(params))
    }

    private func register(_ names: [String], on server: MCPServer) {
        for name in names {
            server.registerTool(MCPToolDefinition(
                name: name, description: name, inputSchema: [:], handler: { _ in .text(name) }))
        }
    }

    // MARK: - tools/list order

    func testToolsListIsSortedByName() {
        let server = makeServer()
        register(["zeta", "alpha", "mu", "beta"], on: server)
        guard case .object(let result)? = server.handleRequest(legacyRequest(method: "tools/list"))?.result,
              case .array(let tools)? = result["tools"] else {
            return XCTFail("Expected a tools array")
        }
        let names = tools.compactMap { $0.member("name")?.asString() }
        XCTAssertEqual(names, ["alpha", "beta", "mu", "zeta"])
    }

    func testEveryToolHasATitleFromItsName() {
        let server = makeServer()
        register(["describe_screen", "run_steps", "tap"], on: server)
        guard case .object(let result)? = server.handleRequest(legacyRequest(method: "tools/list"))?.result,
              case .array(let tools)? = result["tools"] else {
            return XCTFail("Expected a tools array")
        }
        let titles = tools.compactMap { $0.member("title")?.asString() }
        XCTAssertEqual(titles, ["Describe Screen", "Run Steps", "Tap"])
    }

    // MARK: - Missing client capability

    private func registerNeedsSampling(on server: MCPServer) {
        server.registerTool(MCPToolDefinition(
            name: "needs_sampling", description: "asks", inputSchema: [:],
            handler: { _ in
                .missingClientCapability(.object(["sampling": .object([:])]), message: "No model available")
            }))
    }

    private let callNeedsSampling: [String: JSONValue] = [
        "name": .string("needs_sampling"), "arguments": .object([:]),
    ]

    func testModernCallNeedingAnUndeclaredCapabilityIs32021() {
        let server = makeServer()
        registerNeedsSampling(on: server)
        let response = server.handleRequest(modernRequest(method: "tools/call", params: callNeedsSampling))
        guard let error = response?.error else { return XCTFail("Expected MissingRequiredClientCapabilityError") }
        XCTAssertNil(response?.result)
        XCTAssertEqual(error.code, -32021)
        XCTAssertEqual(error.message, "No model available")
        XCTAssertEqual(error.data?.member("requiredCapabilities"), .object(["sampling": .object([:])]))
    }

    func testLegacyCallNeedingAnUndeclaredCapabilityIsAFailedResult() {
        let server = makeServer()
        registerNeedsSampling(on: server)
        let response = server.handleRequest(legacyRequest(method: "tools/call", params: callNeedsSampling))
        XCTAssertNil(response?.error, "the initialize era has no -32021")
        guard case .object(let result)? = response?.result else { return XCTFail("Expected a result") }
        XCTAssertEqual(result["isError"], .bool(true))
        guard case .array(let content)? = result["content"] else { return XCTFail("Expected content") }
        XCTAssertEqual(content.first?.member("text")?.asString(), "No model available")
    }

    // MARK: - classify_screen model route

    func testModernRequestWithSamplingAsksTheClient() {
        XCTAssertEqual(ScreenClassification.route(
            samplingDeclared: true, modernRequest: true, mayInitiateRequest: false, agentConfigured: true),
            .askClient)
    }

    func testLegacyStdioRequestWithSamplingSendsASamplingRequest() {
        XCTAssertEqual(ScreenClassification.route(
            samplingDeclared: true, modernRequest: false, mayInitiateRequest: true, agentConfigured: false),
            .samplingRequest, "a legacy client is asked over stdio, never sent an input_required result")
    }

    func testLegacyHTTPRequestWithSamplingFallsBackToTheAgent() {
        XCTAssertEqual(ScreenClassification.route(
            samplingDeclared: true, modernRequest: false, mayInitiateRequest: false, agentConfigured: true),
            .agent)
        XCTAssertEqual(ScreenClassification.route(
            samplingDeclared: true, modernRequest: false, mayInitiateRequest: false, agentConfigured: false),
            .unreachableSampling)
    }

    func testNoSamplingUsesTheAgentOrReportsTheMissingCapability() {
        for modern in [true, false] {
            XCTAssertEqual(ScreenClassification.route(
                samplingDeclared: false, modernRequest: modern, mayInitiateRequest: !modern,
                agentConfigured: true), .agent)
            XCTAssertEqual(ScreenClassification.route(
                samplingDeclared: false, modernRequest: modern, mayInitiateRequest: !modern,
                agentConfigured: false), .missingSampling)
        }
    }
}
