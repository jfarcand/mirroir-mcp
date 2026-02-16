// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: MCP (Model Context Protocol) JSON-RPC 2.0 types for request/response parsing and encoding.
// ABOUTME: Provides JSONValue, tool definitions, and result types shared across MCP server components.

import Foundation

// MARK: - JSON-RPC Types

public struct JSONRPCRequest: Decodable, Sendable {
    public let jsonrpc: String
    public let id: RequestID?
    public let method: String
    public let params: JSONValue?

    public init(jsonrpc: String = "2.0", id: RequestID?, method: String, params: JSONValue?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum RequestID: Codable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }
}

/// Flexible JSON value type for parsing arbitrary MCP params/results.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public func getString(_ key: String) -> String? {
        guard case .object(let dict) = self,
              case .string(let val) = dict[key] else { return nil }
        return val
    }

    /// Extract a double value from a JSON object by key.
    public func getNumber(_ key: String) -> Double? {
        guard case .object(let dict) = self,
              case .number(let val) = dict[key] else { return nil }
        return val
    }

    /// Extract a nested object's arguments dictionary.
    public func getArguments() -> [String: JSONValue]? {
        guard case .object(let dict) = self,
              case .object(let args) = dict["arguments"] else { return nil }
        return args
    }

    /// Extract the tool name from a tools/call params object.
    public func getToolName() -> String? {
        getString("name")
    }
}

// MARK: - JSONValue Convenience Extensions

extension JSONValue {
    public func asString() -> String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public func asNumber() -> Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public func asInt() -> Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    public func asStringArray() -> [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { $0.asString() }
    }

    public func asBool() -> Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

public struct JSONRPCResponse: Encodable, Sendable {
    public let jsonrpc: String
    public let id: RequestID?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: RequestID?, result: JSONValue?, error: JSONRPCError?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct JSONRPCError: Encodable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - MCP Tool Definition

public struct MCPToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: JSONValue]
    public let handler: @Sendable ([String: JSONValue]) -> MCPToolResult

    public init(
        name: String,
        description: String,
        inputSchema: [String: JSONValue],
        handler: @Sendable @escaping ([String: JSONValue]) -> MCPToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

public struct MCPToolResult: Sendable {
    public let content: [MCPContent]
    public let isError: Bool

    public init(content: [MCPContent], isError: Bool) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)], isError: false)
    }

    public static func image(_ base64: String, mimeType: String = "image/png") -> MCPToolResult {
        MCPToolResult(content: [.image(base64, mimeType: mimeType)], isError: false)
    }

    public static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [.text(message)], isError: true)
    }
}

public enum MCPContent: Sendable {
    case text(String)
    case image(String, mimeType: String)

    public func toJSON() -> JSONValue {
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
