// ABOUTME: MCP (Model Context Protocol) server implementing JSON-RPC 2.0 over stdio.
// ABOUTME: Handles initialize, tools/list, and tools/call methods per the MCP specification.

import Foundation
import HelperLib

// MARK: - MCP Server

final class MCPServer: @unchecked Sendable {
    private var tools: [String: MCPToolDefinition] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let policy: PermissionPolicy
    private let debug: Bool

    init(policy: PermissionPolicy, debug: Bool = false) {
        self.policy = policy
        self.debug = debug
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func registerTool(_ tool: MCPToolDefinition) {
        tools[tool.name] = tool
    }

    /// Run the MCP server, reading JSON-RPC from stdin and writing to stdout.
    func run() {
        // Use line-delimited JSON (one JSON object per line)
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }

            guard let data = line.data(using: .utf8),
                  let request = try? decoder.decode(JSONRPCRequest.self, from: data)
            else {
                writeError(id: nil, code: -32700, message: "Parse error")
                continue
            }

            let response = handleRequest(request)
            writeResponse(response)
        }
    }

    private func handleRequest(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "notifications/initialized":
            // Client acknowledgment — no response needed for notifications
            return JSONRPCResponse(id: request.id, result: .null, error: nil)
        case "tools/list":
            return handleToolsList(request)
        case "tools/call":
            return handleToolsCall(request)
        case "ping":
            return JSONRPCResponse(id: request.id, result: .object([:]), error: nil)
        default:
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)")
            )
        }
    }

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string("iphone-mirroir-mcp"),
                "version": .string("0.1.0"),
            ]),
        ])
        return JSONRPCResponse(id: request.id, result: result, error: nil)
    }

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let toolList: [JSONValue] = tools.values
            .filter { policy.isToolVisible($0.name) }
            .map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": .object(tool.inputSchema),
                ])
            }
        let result: JSONValue = .object(["tools": .array(toolList)])
        return JSONRPCResponse(id: request.id, result: result, error: nil)
    }

    private func handleToolsCall(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard let toolName = request.params?.getToolName() else {
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Missing tool name")
            )
        }

        guard let tool = tools[toolName] else {
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Unknown tool: \(toolName)")
            )
        }

        let decision = policy.checkTool(toolName)
        if debug {
            fputs("[permission] checkTool(\(toolName))=\(decision)\n", stderr)
        }
        if case .denied(let reason) = decision {
            let content: JSONValue = .array([
                MCPContent.text(reason).toJSON()
            ])
            let result: JSONValue = .object([
                "content": content,
                "isError": .bool(true),
            ])
            return JSONRPCResponse(id: request.id, result: result, error: nil)
        }

        let arguments = request.params?.getArguments() ?? [:]
        let toolResult = tool.handler(arguments)

        let content: JSONValue = .array(toolResult.content.map { $0.toJSON() })
        let result: JSONValue = .object([
            "content": content,
            "isError": .bool(toolResult.isError),
        ])
        return JSONRPCResponse(id: request.id, result: result, error: nil)
    }

    private func writeResponse(_ response: JSONRPCResponse) {
        guard let data = try? encoder.encode(response),
              let jsonString = String(data: data, encoding: .utf8)
        else { return }
        print(jsonString)
        fflush(stdout)
    }

    private func writeError(id: RequestID?, code: Int, message: String) {
        let response = JSONRPCResponse(
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message)
        )
        writeResponse(response)
    }
}
