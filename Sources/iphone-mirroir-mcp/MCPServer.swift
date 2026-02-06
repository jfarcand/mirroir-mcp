// ABOUTME: MCP (Model Context Protocol) server implementing JSON-RPC 2.0 over stdio.
// ABOUTME: Handles initialize, tools/list, and tools/call methods per the MCP specification.

import Foundation

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: RequestID?
    let method: String
    let params: JSONValue?
}

enum RequestID: Codable, Sendable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .number(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(
                RequestID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected string or integer for request ID"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }
}

/// Flexible JSON value type for parsing arbitrary MCP params/results.
enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Cannot decode JSONValue"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    /// Extract a string value from a JSON object by key.
    func getString(_ key: String) -> String? {
        guard case .object(let dict) = self,
              case .string(let val) = dict[key] else { return nil }
        return val
    }

    /// Extract a double value from a JSON object by key.
    func getNumber(_ key: String) -> Double? {
        guard case .object(let dict) = self,
              case .number(let val) = dict[key] else { return nil }
        return val
    }

    /// Extract a nested object's arguments dictionary.
    func getArguments() -> [String: JSONValue]? {
        guard case .object(let dict) = self,
              case .object(let args) = dict["arguments"] else { return nil }
        return args
    }

    /// Extract the tool name from a tools/call params object.
    func getToolName() -> String? {
        getString("name")
    }
}

struct JSONRPCResponse: Encodable {
    let jsonrpc: String = "2.0"
    let id: RequestID?
    let result: JSONValue?
    let error: JSONRPCError?
}

struct JSONRPCError: Encodable {
    let code: Int
    let message: String
}

// MARK: - MCP Tool Definition

struct MCPToolDefinition: Sendable {
    let name: String
    let description: String
    let inputSchema: [String: JSONValue]
    let handler: @Sendable ([String: JSONValue]) -> MCPToolResult
}

struct MCPToolResult: Sendable {
    let content: [MCPContent]
    let isError: Bool

    static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)], isError: false)
    }

    static func image(_ base64: String, mimeType: String = "image/png") -> MCPToolResult {
        MCPToolResult(content: [.image(base64, mimeType: mimeType)], isError: false)
    }

    static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [.text(message)], isError: true)
    }
}

enum MCPContent: Sendable {
    case text(String)
    case image(String, mimeType: String)

    func toJSON() -> JSONValue {
        switch self {
        case .text(let t):
            return .object([
                "type": .string("text"),
                "text": .string(t),
            ])
        case .image(let data, let mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType),
            ])
        }
    }
}

// MARK: - MCP Server

final class MCPServer: @unchecked Sendable {
    private var tools: [String: MCPToolDefinition] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
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
        let toolList: [JSONValue] = tools.values.map { tool in
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
