// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for MCPServer modern protocol (2026-07-28): server/discover and per-request _meta.
// ABOUTME: Covers multi round-trip requests (MRTR) routing and error handling.

import XCTest
import HelperLib
@testable import mirroir_mcp

extension MCPServerRoutingTests {

    // MARK: - Modern protocol (2026-07-28): server/discover + per-request _meta

    /// Build a modern request whose `_meta` carries the required reverse-DNS
    /// protocol fields for the given version.
    private func modernRequest(
        method: String, version: String = "2026-07-28",
        includeClientInfo: Bool = true, includeClientCapabilities: Bool = true,
        extraParams: [String: JSONValue] = [:]
    ) -> JSONRPCRequest {
        var meta: [String: JSONValue] = [
            "io.modelcontextprotocol/protocolVersion": .string(version),
        ]
        if includeClientInfo {
            meta["io.modelcontextprotocol/clientInfo"] =
                .object(["name": .string("test-client"), "version": .string("1.0")])
        }
        if includeClientCapabilities {
            meta["io.modelcontextprotocol/clientCapabilities"] = .object([:])
        }
        var params = extraParams
        params["_meta"] = .object(meta)
        return makeRequest(method: method, params: .object(params))
    }

    func testServerDiscoverReturnsSupportedVersionsAndCapabilities() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(method: "server/discover"))
        guard let response else { return XCTFail("Expected response") }
        XCTAssertNil(response.error)
        guard case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }
        XCTAssertEqual(result["resultType"], .string("complete"))
        guard case .array(let versions) = result["supportedVersions"] else {
            return XCTFail("Expected supportedVersions array")
        }
        XCTAssertTrue(versions.contains(.string("2026-07-28")), "must advertise the modern version")
        XCTAssertTrue(versions.contains(.string("2025-11-25")), "must still advertise legacy")
        guard case .object(let caps) = result["capabilities"],
              case .object = caps["tools"] else {
            return XCTFail("Expected tools capability")
        }
        // Identity lives in result `_meta`, the revision's canonical location
        // for it — `DiscoverResult` itself has no serverInfo field.
        guard case .object(let meta) = result["_meta"],
              case .object(let info)? = meta["io.modelcontextprotocol/serverInfo"] else {
            return XCTFail("Expected _meta serverInfo")
        }
        XCTAssertEqual(info["name"], .string("mirroir-mcp"))
        XCTAssertNotNil(info["version"], "Implementation requires name and version")
        XCTAssertNil(result["serverInfo"], "identity belongs in _meta, not top level")
        // Cacheable per the spec: both directives are required, not optional.
        XCTAssertNotNil(result["ttlMs"])
        XCTAssertEqual(result["cacheScope"], .string("public"))
    }

    func testModernToolsListIncludesResultType() {
        let server = makeServer()
        let response = server.handleRequest(modernRequest(method: "tools/list"))
        guard let response, case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }
        XCTAssertNil(response.error)
        XCTAssertEqual(result["resultType"], .string("complete"),
            "modern result responses must carry resultType")
        XCTAssertNotNil(result["tools"])
    }

    /// The revision says servers should report their identity on every modern
    /// result, in `_meta` under the reserved reverse-DNS key.
    func testModernResultsCarryServerInfoMeta() {
        let server = makeServer()
        for method in ["tools/list", "ping"] {
            guard let response = server.handleRequest(modernRequest(method: method)),
                  case .object(let result) = response.result,
                  case .object(let meta)? = result["_meta"],
                  case .object(let info)? = meta["io.modelcontextprotocol/serverInfo"] else {
                return XCTFail("\(method): expected _meta serverInfo")
            }
            XCTAssertEqual(info["name"], .string("mirroir-mcp"), "\(method): server name")
            XCTAssertNotNil(info["version"], "\(method): server version")
        }
    }

    func testLegacyResultsOmitServerInfoMeta() {
        let server = makeServer()
        // Legacy clients learn the identity from the initialize handshake.
        guard let response = server.handleRequest(makeRequest(method: "tools/list")),
              case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }
        XCTAssertNil(result["_meta"], "legacy results carry no modern _meta envelope")
    }

    /// `2026-07-28` makes `ttlMs`/`cacheScope` required on `tools/list`; a client
    /// validating against that schema rejects the entire result if either is
    /// missing, so tool discovery fails outright.
    func testModernToolsListCarriesCacheDirectives() {
        let server = makeServer()
        let response = server.handleRequest(modernRequest(method: "tools/list"))
        guard let response, case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }
        guard case .number(let ttl)? = result["ttlMs"] else {
            return XCTFail("modern tools/list must carry ttlMs")
        }
        XCTAssertGreaterThanOrEqual(ttl, 0, "ttlMs must be a non-negative integer")
        XCTAssertEqual(ttl, ttl.rounded(), "ttlMs must be an integer")
        XCTAssertEqual(result["cacheScope"], .string("private"),
            "the tool set is filtered per-machine by the permission policy")
    }

    func testLegacyToolsListOmitsResultType() {
        let server = makeServer()
        // No modern _meta → legacy request → no resultType (clients treat absence as complete).
        let response = server.handleRequest(makeRequest(method: "tools/list"))
        guard let response, case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }
        XCTAssertNil(result["resultType"], "legacy responses must not include resultType")
        XCTAssertNil(result["ttlMs"], "cache directives are a modern-revision field")
        XCTAssertNil(result["cacheScope"], "cache directives are a modern-revision field")
    }

    func testModernUnsupportedVersionReturnsError() {
        let server = makeServer()
        let response = server.handleRequest(modernRequest(method: "tools/list", version: "1900-01-01"))
        guard let response, let error = response.error else {
            return XCTFail("Expected error")
        }
        // -32022 is the spec-allocated code; the -32000..-32019 range is
        // implementation-defined and carries no cross-implementation meaning.
        XCTAssertEqual(error.code, -32022, "unsupported version → UnsupportedProtocolVersionError")
        guard case .object(let data)? = error.data,
              case .array(let supported) = data["supported"] else {
            return XCTFail("Expected data.supported list")
        }
        XCTAssertTrue(supported.contains(.string("2026-07-28")))
        XCTAssertEqual(data["requested"], .string("1900-01-01"))
    }

    /// An `initialize`-era revision named in `_meta` is not a legacy request —
    /// it asks for stateless negotiation at a revision that has no such concept,
    /// and must not be answered with a stateless result envelope.
    func testLegacyVersionInMetaIsRejected() {
        let server = makeServer()
        for legacy in MCPServer.legacyProtocolVersions {
            let response = server.handleRequest(
                modernRequest(method: "tools/list", version: legacy))
            guard let response, let error = response.error else {
                return XCTFail("\(legacy) in _meta must not be served statelessly")
            }
            XCTAssertEqual(error.code, -32022, "\(legacy): UnsupportedProtocolVersionError")
            XCTAssertNil(response.result, "\(legacy): must not return a result envelope")
        }
    }

    /// The error names every revision the server serves, so a client can pick a
    /// stateless one or fall back to the handshake.
    func testUnsupportedVersionErrorAdvertisesBothEras() {
        let server = makeServer()
        guard let response = server.handleRequest(
                modernRequest(method: "tools/list", version: "1900-01-01")),
              case .object(let data)? = response.error?.data,
              case .array(let supported) = data["supported"] else {
            return XCTFail("Expected data.supported list")
        }
        XCTAssertTrue(supported.contains(.string("2026-07-28")), "stateless revision")
        XCTAssertTrue(supported.contains(.string("2025-11-25")), "fallback revision")
    }

    func testModernMissingRequiredMetaFieldReturnsInvalidParams() {
        let server = makeServer()
        // protocolVersion present but clientCapabilities missing → malformed
        // modern request; the revision requires that field.
        let response = server.handleRequest(
            modernRequest(method: "tools/list", includeClientCapabilities: false))
        guard let response, let error = response.error else {
            return XCTFail("Expected error")
        }
        XCTAssertEqual(error.code, -32602, "missing required _meta field → Invalid params")
    }

    /// `clientInfo` is optional in the revision's request envelope — rejecting a
    /// request that omits it would turn away conformant clients.
    func testModernRequestWithoutClientInfoIsAccepted() {
        let server = makeServer()
        let response = server.handleRequest(
            modernRequest(method: "tools/list", includeClientInfo: false))
        guard let response, case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }
        XCTAssertNil(response.error, "clientInfo is optional, not required")
        XCTAssertNotNil(result["tools"])
    }

    /// The revision's stdio transport forbids a server from writing JSON-RPC
    /// requests to stdout, so nothing may be initiated while serving one.
    func testServerInitiatedRequestsForbiddenWhileServingModernRequest() {
        let server = makeServer()
        _ = server.handleRequest(modernRequest(method: "tools/list"))
        XCTAssertFalse(server.mayInitiateRequest(),
            "2026-07-28 forbids server-initiated requests on stdio")

        // A legacy request lifts the restriction again — that era allows them.
        _ = server.handleRequest(makeRequest(method: "tools/list"))
        XCTAssertTrue(server.mayInitiateRequest())
    }

    func testSamplingRequiresClientDeclaredCapability() {
        let server = makeServer()
        _ = server.handleRequest(makeRequest(
            method: "initialize",
            params: .object(["capabilities": .object([:])])
        ))
        XCTAssertFalse(server.clientSupportsSampling(),
            "a client that declared no sampling must not be asked")

        _ = server.handleRequest(makeRequest(
            method: "initialize",
            params: .object(["capabilities": .object(["sampling": .object([:])])])
        ))
        XCTAssertTrue(server.clientSupportsSampling())
    }

    // MARK: - Multi round-trip requests (MRTR)

    /// A stateless-revision client never handshakes, so its capabilities are
    /// read from the `_meta` on each request instead.
    func testModernRequestCapabilitiesAreRecorded() {
        let server = makeServer()
        XCTAssertFalse(server.clientSupportsSampling(), "nothing declared yet")

        var meta: [String: JSONValue] = [
            "io.modelcontextprotocol/protocolVersion": .string("2026-07-28"),
            "io.modelcontextprotocol/clientCapabilities": .object(["sampling": .object([:])]),
        ]
        _ = server.handleRequest(makeRequest(
            method: "tools/list", params: .object(["_meta": .object(meta)])))
        XCTAssertTrue(server.clientSupportsSampling(),
            "capabilities declared per-request must be honoured")

        // And a later request that declares none takes it away again.
        meta["io.modelcontextprotocol/clientCapabilities"] = .object([:])
        _ = server.handleRequest(makeRequest(
            method: "tools/list", params: .object(["_meta": .object(meta)])))
        XCTAssertFalse(server.clientSupportsSampling())
    }

    /// A tool that needs client input ends the call with an `input_required`
    /// result carrying the requests and the state to resume from.
    func testToolNeedingInputReturnsInputRequiredResult() {
        let server = makeServer()
        server.registerTool(MCPToolDefinition(
            name: "needs_input", description: "asks", inputSchema: [:],
            handler: { _ in
                .inputRequired(
                    ["classify": MCPInputRequest(
                        method: "sampling/createMessage",
                        params: .object(["maxTokens": .number(100)]))],
                    requestState: "opaque-blob")
            }))

        let response = server.handleRequest(modernRequest(
            method: "tools/call",
            extraParams: ["name": .string("needs_input"), "arguments": .object([:])]))
        guard let response, case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }
        XCTAssertNil(response.error)
        XCTAssertEqual(result["resultType"], .string("input_required"))
        XCTAssertEqual(result["requestState"], .string("opaque-blob"))
        guard case .object(let requests)? = result["inputRequests"],
              case .object(let classify)? = requests["classify"] else {
            return XCTFail("Expected inputRequests entry")
        }
        XCTAssertEqual(classify["method"], .string("sampling/createMessage"))
        XCTAssertNil(result["content"], "an input_required result carries no tool content")
    }

    /// The exchange exists only in the stateless revision. A legacy client cannot
    /// fulfil the requests or retry with them, so it is told plainly.
    func testInputRequiredRefusedOnLegacyRequest() {
        let server = makeServer()
        server.registerTool(MCPToolDefinition(
            name: "needs_input", description: "asks", inputSchema: [:],
            handler: { _ in .inputRequired(["k": MCPInputRequest(method: "roots/list", params: .object([:]))]) }))

        let response = server.handleRequest(makeRequest(
            method: "tools/call",
            params: .object(["name": .string("needs_input"), "arguments": .object([:])])))
        guard let response, let error = response.error else {
            return XCTFail("Expected an error for a legacy client")
        }
        XCTAssertEqual(error.code, -32603)
        XCTAssertTrue(error.message.contains("2026-07-28"), "names the revision required")
    }

    /// On the retry the client echoes the state and supplies the answers; both
    /// must reach the handler.
    func testRetryCarriesInputResponsesAndRequestState() {
        let server = makeServer()
        let request = modernRequest(
            method: "tools/call",
            extraParams: [
                "name": .string("t"), "arguments": .object([:]),
                "requestState": .string("blob"),
                "inputResponses": .object([
                    "classify": .object(["content": .object(["text": .string("answer")])]),
                ]),
            ])

        XCTAssertEqual(MCPServer.requestState(in: request), "blob")
        let responses = MCPServer.inputResponses(in: request)
        XCTAssertEqual(responses.count, 1)
        XCTAssertNotNil(responses["classify"], "the answer is keyed by the request identifier")
    }

    func testFirstAttemptCarriesNoInputState() {
        let request = modernRequest(
            method: "tools/call",
            extraParams: ["name": .string("t"), "arguments": .object([:])])
        XCTAssertNil(MCPServer.requestState(in: request))
        XCTAssertTrue(MCPServer.inputResponses(in: request).isEmpty)
    }

    /// `sampling` is a client capability. Advertising it as a server capability
    /// tells the client nothing and misreports what this server offers.
    func testInitializeAdvertisesOnlyServerCapabilities() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-11-25")])
        ))
        guard let response, case .object(let result) = response.result,
              case .object(let capabilities)? = result["capabilities"] else {
            return XCTFail("Expected capabilities")
        }
        XCTAssertNotNil(capabilities["tools"], "tools is the capability we implement")
        XCTAssertNil(capabilities["sampling"], "sampling is a client capability")
    }

    func testInitializeNeverNegotiatesModernVersion() {
        let server = makeServer()
        // A legacy initialize must not yield the handshake-less modern version,
        // even if the client names it.
        let response = server.handleRequest(makeRequest(
            method: "initialize",
            params: .object(["protocolVersion": .string("2026-07-28")])
        ))
        guard let response, case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }
        XCTAssertEqual(result["protocolVersion"], .string("2025-11-25"),
            "initialize negotiates only legacy versions")
    }
}
