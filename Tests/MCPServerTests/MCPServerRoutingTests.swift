// ABOUTME: Tests for MCPServer JSON-RPC routing: initialize, tools/list, tools/call, ping, errors.
// ABOUTME: Verifies protocol version, capability negotiation, and error code compliance.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class MCPServerRoutingTests: XCTestCase {

    private func makeServer(skipPermissions: Bool = true) -> MCPServer {
        let policy = PermissionPolicy(skipPermissions: skipPermissions, config: nil)
        return MCPServer(policy: policy)
    }

    private func makeRequest(method: String, id: RequestID? = .number(1), params: JSONValue? = nil) -> JSONRPCRequest {
        return JSONRPCRequest(jsonrpc: "2.0", id: id, method: method, params: params)
    }

    // MARK: - initialize

    func testInitializeReturnsProtocolVersionAndServerInfo() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(method: "initialize"))

        XCTAssertNil(response.error)
        guard case .object(let result) = response.result else {
            return XCTFail("Expected object result")
        }

        XCTAssertEqual(result["protocolVersion"], .string("2024-11-05"))

        guard case .object(let serverInfo) = result["serverInfo"] else {
            return XCTFail("Expected serverInfo object")
        }
        XCTAssertEqual(serverInfo["name"], .string("iphone-mirroir-mcp"))
        XCTAssertEqual(serverInfo["version"], .string("0.9.1"))

        guard case .object(let capabilities) = result["capabilities"] else {
            return XCTFail("Expected capabilities object")
        }
        guard case .object(let tools) = capabilities["tools"] else {
            return XCTFail("Expected tools capability object")
        }
        XCTAssertTrue(tools.isEmpty)
    }

    // MARK: - tools/list

    func testToolsListWithNoToolsRegistered() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(method: "tools/list"))

        XCTAssertNil(response.error)
        guard case .object(let result) = response.result,
              case .array(let tools) = result["tools"] else {
            return XCTFail("Expected tools array in result")
        }
        XCTAssertTrue(tools.isEmpty)
    }

    func testToolsListWithRegisteredTools() {
        let server = makeServer()
        server.registerTool(MCPToolDefinition(
            name: "test_tool",
            description: "A test tool",
            inputSchema: ["type": .string("object"), "properties": .object([:])],
            handler: { _ in .text("ok") }
        ))

        let response = server.handleRequest(makeRequest(method: "tools/list"))
        guard case .object(let result) = response.result,
              case .array(let tools) = result["tools"] else {
            return XCTFail("Expected tools array")
        }
        XCTAssertEqual(tools.count, 1)

        guard case .object(let tool) = tools.first else {
            return XCTFail("Expected tool object")
        }
        XCTAssertEqual(tool["name"], .string("test_tool"))
        XCTAssertEqual(tool["description"], .string("A test tool"))
    }

    func testToolsListRespectsPermissionPolicy() {
        // Without skip-permissions, mutating tools are hidden
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        let server = MCPServer(policy: policy)

        server.registerTool(MCPToolDefinition(
            name: "tap",
            description: "Tap tool",
            inputSchema: ["type": .string("object")],
            handler: { _ in .text("ok") }
        ))
        server.registerTool(MCPToolDefinition(
            name: "screenshot",
            description: "Screenshot tool",
            inputSchema: ["type": .string("object")],
            handler: { _ in .text("ok") }
        ))

        let response = server.handleRequest(makeRequest(method: "tools/list"))
        guard case .object(let result) = response.result,
              case .array(let tools) = result["tools"] else {
            return XCTFail("Expected tools array")
        }

        // Only screenshot should be visible (readonly); tap is mutating and not permitted
        let toolNames = tools.compactMap { value -> String? in
            guard case .object(let obj) = value else { return nil }
            return obj["name"]?.asString()
        }
        XCTAssertTrue(toolNames.contains("screenshot"))
        XCTAssertFalse(toolNames.contains("tap"))
    }

    // MARK: - tools/call

    func testToolsCallMissingToolName() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(
            method: "tools/call",
            params: .object([:])
        ))

        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertEqual(response.error?.message, "Missing tool name")
    }

    func testToolsCallUnknownTool() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(
            method: "tools/call",
            params: .object(["name": .string("nonexistent")])
        ))

        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertTrue(response.error?.message.contains("Unknown tool") ?? false)
    }

    func testToolsCallDeniedTool() {
        let policy = PermissionPolicy(skipPermissions: false, config: nil)
        let server = MCPServer(policy: policy)

        server.registerTool(MCPToolDefinition(
            name: "tap",
            description: "Tap",
            inputSchema: ["type": .string("object")],
            handler: { _ in .text("tapped") }
        ))

        let response = server.handleRequest(makeRequest(
            method: "tools/call",
            params: .object(["name": .string("tap")])
        ))

        // Denied tools return a result with isError=true, not a JSON-RPC error
        XCTAssertNil(response.error)
        guard case .object(let result) = response.result else {
            return XCTFail("Expected result object")
        }
        XCTAssertEqual(result["isError"], .bool(true))
    }

    func testToolsCallValidTool() {
        let server = makeServer()
        server.registerTool(MCPToolDefinition(
            name: "test_tool",
            description: "Test",
            inputSchema: ["type": .string("object")],
            handler: { args in
                let name = args["name"]?.asString() ?? "world"
                return .text("hello \(name)")
            }
        ))

        let response = server.handleRequest(makeRequest(
            method: "tools/call",
            params: .object([
                "name": .string("test_tool"),
                "arguments": .object(["name": .string("test")]),
            ])
        ))

        XCTAssertNil(response.error)
        guard case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let textObj) = content.first else {
            return XCTFail("Expected content array with text object")
        }
        XCTAssertEqual(textObj["text"], .string("hello test"))
        XCTAssertEqual(result["isError"], .bool(false))
    }

    // MARK: - ping

    func testPingReturnsEmptyResult() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(method: "ping"))

        XCTAssertNil(response.error)
        guard case .object(let result) = response.result else {
            return XCTFail("Expected empty object")
        }
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Unknown method

    func testUnknownMethodReturnsError() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(method: "bogus/method"))

        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertTrue(response.error?.message.contains("Method not found") ?? false)
    }

    // MARK: - notifications/initialized

    func testNotificationsInitializedReturnsNull() {
        let server = makeServer()
        let response = server.handleRequest(makeRequest(method: "notifications/initialized"))

        XCTAssertNil(response.error)
        guard case .null = response.result else {
            return XCTFail("Expected null result for notification acknowledgment")
        }
    }
}
