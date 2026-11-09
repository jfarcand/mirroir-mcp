// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the MCP HTTP endpoint: what is refused before a request reaches the server, and how answers map to HTTP.
// ABOUTME: Dispatch is a real MCPServer on the HTTP transport with every tool registered over stub hardware.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class MCPHTTPEndpointTests: XCTestCase {

    private static let token = String(repeating: "t", count: ServeToken.minimumLength)
    private static let modernVersion = MCPServer.modernProtocolVersions[0]

    /// A server on the HTTP transport, and how many requests reached it.
    private final class Harness: @unchecked Sendable {
        let server: MCPServer
        private(set) var dispatched = 0

        init(skipPermissions: Bool) {
            let policy = PermissionPolicy(skipPermissions: skipPermissions, config: nil)
            server = MCPServer(policy: policy, transport: .http)
            MirroirMCP.registerTools(
                server: server, registry: makeTestRegistry(bridge: StubBridge(), input: StubInput()),
                policy: policy)
        }

        func respond(_ request: HTTPRequest, origins: Set<String> = []) -> HTTPResponse {
            let config = MCPHTTPEndpoint.Config(token: MCPHTTPEndpointTests.token, allowedOrigins: origins)
            return MCPHTTPEndpoint.respond(to: request, config: config) { rpc in
                self.dispatched += 1
                return self.server.handleRequest(rpc)
            }
        }
    }

    private func harness(skipPermissions: Bool = true) -> Harness { Harness(skipPermissions: skipPermissions) }

    /// A well-formed POST; `headers` override or, with an empty value, remove a default.
    private func post(_ body: String, headers: [String: String] = [:], path: String = "/mcp",
                      method: String = "POST") -> HTTPRequest {
        var all = ["authorization": "Bearer " + Self.token, "content-type": "application/json"]
        for (name, value) in headers {
            all[name] = value.isEmpty ? nil : value
        }
        return HTTPRequest(method: method, path: path, headers: all, body: Data(body.utf8))
    }

    private func modernBody(method: String, id: Int = 1, extraParams: String = "",
                            version: String = MCPHTTPEndpointTests.modernVersion) -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"method":"\(method)","params":{\(extraParams)"_meta":{\
        "io.modelcontextprotocol/protocolVersion":"\(version)",\
        "io.modelcontextprotocol/clientCapabilities":{}}}}
        """
    }

    private func modernHeaders(method: String, name: String? = nil) -> [String: String] {
        var headers = ["mcp-protocol-version": Self.modernVersion, "mcp-method": method]
        headers["mcp-name"] = name
        return headers
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func errorCode(_ response: HTTPResponse) throws -> Int? {
        (try json(response)["error"] as? [String: Any])?["code"] as? Int
    }

    private let legacyInitialize =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#

    // MARK: - Refused before dispatch

    func testUnknownPathIs404() {
        let harness = harness()
        XCTAssertEqual(harness.respond(post(legacyInitialize, path: "/")).status, 404)
        XCTAssertEqual(harness.respond(post(legacyInitialize, path: "/mcp/extra")).status, 404)
        XCTAssertEqual(harness.dispatched, 0)
    }

    func testGetAndDeleteAre405WithAllowPost() {
        let harness = harness()
        for method in ["GET", "DELETE", "PUT"] {
            let response = harness.respond(post("", method: method))
            XCTAssertEqual(response.status, 405, method)
            XCTAssertEqual(response.headers["Allow"], "POST", method)
        }
        XCTAssertEqual(harness.dispatched, 0)
    }

    func testAnyOriginIsRefusedByDefault() {
        let harness = harness()
        for origin in ["http://evil.example", "http://localhost:3000", "null"] {
            XCTAssertEqual(harness.respond(post(legacyInitialize, headers: ["origin": origin])).status, 403, origin)
        }
        XCTAssertEqual(harness.dispatched, 0)
    }

    func testAnAllowedOriginPasses() {
        let harness = harness()
        let request = post(legacyInitialize, headers: ["origin": "http://localhost:3000"])
        XCTAssertEqual(harness.respond(request, origins: ["http://localhost:3000"]).status, 200)
        XCTAssertEqual(harness.respond(request, origins: ["http://localhost:3001"]).status, 403,
                       "an origin is matched whole, port included")
    }

    func testMissingOrWrongTokenIs401() {
        let harness = harness()
        let wrong = String(repeating: "x", count: ServeToken.minimumLength)
        for authorization in ["", "Bearer " + wrong, "Bearer ", Self.token, "Basic " + Self.token,
                              "bearer " + Self.token + "x"] {
            let response = harness.respond(post(legacyInitialize, headers: ["authorization": authorization]))
            XCTAssertEqual(response.status, 401, authorization)
            XCTAssertEqual(response.headers["WWW-Authenticate"], "Bearer")
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(Self.token),
                           "a refusal never echoes the token")
        }
        XCTAssertEqual(harness.dispatched, 0, "an unauthenticated request never reaches the server")
    }

    /// The token is checked before the body is looked at, so a caller without
    /// it learns nothing about what the endpoint parses.
    func testTheTokenIsCheckedBeforeTheBody() {
        let harness = harness()
        let response = harness.respond(
            post("not json", headers: ["authorization": "", "content-type": "text/plain"]))
        XCTAssertEqual(response.status, 401)
    }

    func testWrongContentTypeIs415() {
        let harness = harness()
        XCTAssertEqual(harness.respond(post(legacyInitialize, headers: ["content-type": "text/plain"])).status, 415)
        XCTAssertEqual(harness.respond(post(legacyInitialize, headers: ["content-type": ""])).status, 415,
                       "no Content-Type header at all")
        // A header that is present and empty, as `curl -H "Content-Type;"` sends.
        for empty in ["", ";", " ; charset=utf-8", "   "] {
            let request = HTTPRequest(
                method: "POST", path: "/mcp",
                headers: ["authorization": "Bearer " + Self.token, "content-type": empty],
                body: Data(legacyInitialize.utf8))
            XCTAssertEqual(harness.respond(request).status, 415, "Content-Type '\(empty)'")
        }
        XCTAssertEqual(harness.dispatched, 0)
        XCTAssertEqual(
            harness.respond(post(legacyInitialize, headers: ["content-type": "Application/JSON; charset=utf-8"])).status,
            200, "parameters and case do not matter")
    }

    func testInvalidJSONIs400ParseError() throws {
        let harness = harness()
        let response = harness.respond(post("{not json"))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try errorCode(response), -32700)
        XCTAssertEqual(harness.dispatched, 0)
    }

    func testABatchArrayIs400() throws {
        let harness = harness()
        let response = harness.respond(post("[" + legacyInitialize + "]"))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try errorCode(response), -32600)
        XCTAssertEqual(harness.dispatched, 0)
    }

    /// The thread that decodes a body has a small stack; depth is bounded
    /// before anything recursive runs on it.
    func testADeeplyNestedBodyIs400BeforeItIsDecoded() throws {
        let harness = harness()
        func body(depth: Int) -> String {
            let nest = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            return #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","arguments":{"x":"#
                + nest + "}}}"
        }
        let deep = harness.respond(post(body(depth: 5000)))
        XCTAssertEqual(deep.status, 400)
        XCTAssertEqual(try errorCode(deep), -32600)
        XCTAssertEqual(harness.dispatched, 0)

        // `arguments` sits three levels down, so this body is exactly at the bound.
        let atBound = harness.respond(post(body(depth: MCPHTTPEndpoint.maxNestingDepth - 3)))
        XCTAssertEqual(atBound.status, 200, "a body at the bound is served")
        XCTAssertEqual(harness.respond(post(body(depth: MCPHTTPEndpoint.maxNestingDepth - 2))).status, 400)
    }

    func testNestingDepthIgnoresBracketsInsideStrings() {
        func depth(_ text: String) -> Int { MCPHTTPEndpoint.nestingDepth(of: Data(text.utf8)) }
        XCTAssertEqual(depth(#"{"a":[1,{"b":2}]}"#), 3)
        XCTAssertEqual(depth(#"{"a":"[[[[{{{{"}"#), 1)
        XCTAssertEqual(depth(#"{"a":"\"[[[","b":[]}"#), 2, "an escaped quote does not end the string")
        XCTAssertEqual(depth(#"{"a":"\\","b":[[]]}"#), 3, "an escaped backslash does not escape the quote")
        XCTAssertEqual(depth("42"), 0)
    }

    /// What the listener asks before reading a body agrees with the full answer.
    func testTheHeaderOnlyRefusalsMatchTheFullOnes() {
        let harness = harness()
        let config = MCPHTTPEndpoint.Config(token: Self.token, allowedOrigins: [])
        let cases: [HTTPRequest] = [
            post("", path: "/elsewhere"), post("", method: "GET"),
            post("", headers: ["origin": "http://evil.example"]),
            post("", headers: ["authorization": ""]), post("", headers: ["content-type": "text/plain"]),
        ]
        for request in cases {
            let early = MCPHTTPEndpoint.refusalBeforeBody(request, config: config)
            XCTAssertNotNil(early)
            XCTAssertEqual(early, harness.respond(request))
        }
        XCTAssertNil(MCPHTTPEndpoint.refusalBeforeBody(post(""), config: config),
                     "a well-formed head is not refused before its body is read")
        XCTAssertEqual(harness.dispatched, 0)
    }

    // MARK: - Messages with no answer

    func testANotificationIs202WithNoBody() {
        let harness = harness()
        let response = harness.respond(post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual(response.status, 202)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testAClientResponseIs202() {
        let harness = harness()
        let response = harness.respond(post(#"{"jsonrpc":"2.0","id":7,"result":{}}"#))
        XCTAssertEqual(response.status, 202)
        XCTAssertEqual(harness.dispatched, 0, "there is no server request for it to answer")
    }

    // MARK: - Stateless-era headers

    func testModernRequestNeedsMatchingVersionHeader() throws {
        let harness = harness()
        let body = modernBody(method: "tools/list")
        for version in ["", "2025-11-25"] {
            var headers = modernHeaders(method: "tools/list")
            headers["mcp-protocol-version"] = version
            let response = harness.respond(post(body, headers: headers))
            XCTAssertEqual(response.status, 400, version)
            XCTAssertEqual(try errorCode(response), -32020, version)
        }
        XCTAssertEqual(harness.dispatched, 0)
    }

    func testModernRequestNeedsMatchingMethodHeader() throws {
        let harness = harness()
        let body = modernBody(method: "tools/list")
        for method in ["", "ping"] {
            let response = harness.respond(post(body, headers: modernHeaders(method: method)))
            XCTAssertEqual(response.status, 400, method)
            XCTAssertEqual(try errorCode(response), -32020, method)
            let message = (try json(response)["error"] as? [String: Any])?["message"] as? String
            XCTAssertEqual(message, "Mcp-Method must be 'tools/list', the method in the body")
        }
    }

    private let listSkillsCall = #""name":"list_skills","arguments":{},"#

    func testToolCallNeedsMatchingNameHeader() throws {
        let harness = harness()
        let body = modernBody(method: "tools/call", extraParams: listSkillsCall)
        for name in [nil, "tap"] as [String?] {
            let response = harness.respond(post(body, headers: modernHeaders(method: "tools/call", name: name)))
            XCTAssertEqual(response.status, 400)
            XCTAssertEqual(try errorCode(response), -32020)
        }
        XCTAssertEqual(harness.dispatched, 0)
        let matching = harness.respond(
            post(body, headers: modernHeaders(method: "tools/call", name: "list_skills")))
        XCTAssertEqual(matching.status, 200)
    }

    func testNameHeaderAcceptsTheBase64Sentinel() {
        let harness = harness()
        let encoded = "=?base64?" + Data("list_skills".utf8).base64EncodedString() + "?="
        let response = harness.respond(post(
            modernBody(method: "tools/call", extraParams: listSkillsCall),
            headers: modernHeaders(method: "tools/call", name: encoded)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(MCPHTTPEndpoint.decodedHeaderValue("=?base64?bm90IGJhc2U2NA"), "=?base64?bm90IGJhc2U2NA",
                       "a value without the closing mark is taken as written")
        XCTAssertEqual(MCPHTTPEndpoint.decodedHeaderValue("=?base64?!!!?="), "=?base64?!!!?=")
    }

    func testUnsupportedModernVersionIs400With32022() throws {
        let harness = harness()
        let body = modernBody(method: "tools/list", version: "2099-01-01")
        var headers = modernHeaders(method: "tools/list")
        headers["mcp-protocol-version"] = "2099-01-01"
        let response = harness.respond(post(body, headers: headers))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try errorCode(response), -32022)
    }

    func testUnknownMethodIs404OnModern() throws {
        let harness = harness()
        let response = harness.respond(
            post(modernBody(method: "resources/list"), headers: modernHeaders(method: "resources/list")))
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(try errorCode(response), -32601)

        let legacy = harness.respond(post(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#))
        XCTAssertEqual(legacy.status, 200, "the initialize era reports it in the body only")
        XCTAssertEqual(try errorCode(legacy), -32601)
    }

    // MARK: - Initialize era

    func testLegacyInitializeWorksWithoutVersionHeader() throws {
        let harness = harness()
        let response = harness.respond(post(legacyInitialize))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
        let result = try XCTUnwrap(try json(response)["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
        XCTAssertFalse(response.headers.keys.contains { $0.lowercased() == "mcp-session-id" },
                       "there is no session to name")
    }

    func testLegacyRequestWithUnknownVersionHeaderIs400() throws {
        let harness = harness()
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        XCTAssertEqual(harness.respond(post(list, headers: ["mcp-protocol-version": "1999-01-01"])).status, 400)
        XCTAssertEqual(harness.respond(post(list, headers: ["mcp-protocol-version": "2025-11-25"])).status, 200)
    }

    // MARK: - Permissions

    func testModernToolsListIsFilteredByTheSamePolicy() throws {
        let harness = harness(skipPermissions: false)
        let list = harness.respond(
            post(modernBody(method: "tools/list"), headers: modernHeaders(method: "tools/list")))
        XCTAssertEqual(list.status, 200)
        let tools = try XCTUnwrap((try json(list)["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), PermissionPolicy.readonlyTools,
                       "with no permission file, HTTP exposes the read-only tools and nothing else")

        let tap = harness.respond(post(
            modernBody(method: "tools/call", extraParams: #""name":"tap","arguments":{"x":1,"y":1},"#),
            headers: modernHeaders(method: "tools/call", name: "tap")))
        XCTAssertEqual(tap.status, 200)
        let result = try XCTUnwrap(try json(tap)["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        guard case .denied(let reason) = policy.checkTool("tap") else { return XCTFail("tap should be denied") }
        XCTAssertEqual(text, reason)
    }

    // MARK: - Server-initiated requests

    func testHTTPTransportNeverInitiatesRequests() {
        let declaresSampling = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "initialize",
            params: .object(["protocolVersion": .string("2025-11-25"),
                             "capabilities": .object(["sampling": .object([:])])]))
        let policy = PermissionPolicy(skipPermissions: true, config: nil)

        let overHTTP = MCPServer(policy: policy, transport: .http)
        _ = overHTTP.handleRequest(declaresSampling)
        XCTAssertTrue(overHTTP.clientSupportsSampling(), "precondition: the client offered sampling")
        XCTAssertFalse(overHTTP.mayInitiateRequest(), "there is no channel to write a request on")
        let params = SamplingParams(
            messages: [SamplingMessage(role: "user", content: .text("classify"))],
            maxTokens: 16, systemPrompt: nil)
        XCTAssertNil(overHTTP.sendSamplingRequest(params), "returns at once instead of reading stdin")

        let overStdio = MCPServer(policy: policy, transport: .stdio)
        _ = overStdio.handleRequest(declaresSampling)
        XCTAssertTrue(overStdio.mayInitiateRequest())
    }
}
