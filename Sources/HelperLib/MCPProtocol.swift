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

    /// Return the value at `key` if this is an object, else nil. Unlike
    /// `getString`/`getNumber` this preserves the nested `JSONValue`, so callers
    /// can walk paths like `params.member("_meta")?.member(metaKey)`.
    public func member(_ key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
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

    /// The number truncated toward zero, or nil when it is not a number or
    /// has no `Int` value (NaN, infinity, or outside `Int`'s range). Never
    /// traps, so a hostile argument becomes a missing one instead of a crash.
    public func asInt() -> Int? {
        guard case .number(let n) = self else { return nil }
        return Int(exactly: n.rounded(.towardZero))
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
    /// Optional structured payload. Carries `{supported, requested}` for the
    /// modern `UnsupportedProtocolVersionError` (-32004) and
    /// `{requiredCapabilities}` for `MissingRequiredClientCapabilityError`
    /// (-32003). Omitted from the wire when nil (synthesized `encodeIfPresent`).
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - MCP Sampling Types

/// Parameters for a sampling/createMessage server-to-client request.
public struct SamplingParams: Codable, Sendable {
    public let messages: [SamplingMessage]
    public let maxTokens: Int
    public let systemPrompt: String?

    public init(messages: [SamplingMessage], maxTokens: Int, systemPrompt: String? = nil) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
    }
}

/// A message in a sampling conversation.
public struct SamplingMessage: Codable, Sendable {
    public let role: String
    public let content: SamplingContent

    public init(role: String, content: SamplingContent) {
        self.role = role
        self.content = content
    }
}

/// Content for a sampling message — either plain text or mixed content parts.
public enum SamplingContent: Codable, Sendable {
    case text(String)
    case mixed([SamplingContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let parts = try? container.decode([SamplingContentPart].self) {
            self = .mixed(parts)
        } else if let obj = try? container.decode(SamplingContentPart.self) {
            if obj.type == "text", let text = obj.text {
                self = .text(text)
            } else {
                self = .mixed([obj])
            }
        } else {
            throw DecodingError.typeMismatch(
                SamplingContent.self,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Expected text or content parts")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(SamplingContentPart(type: "text", text: text))
        case .mixed(let parts):
            try container.encode(parts)
        }
    }
}

/// A single content part in a sampling message.
public struct SamplingContentPart: Codable, Sendable {
    public let type: String
    public let text: String?
    public let data: String?
    public let mimeType: String?

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }
}

/// Response from a sampling/createMessage request.
public struct SamplingResponse: Codable, Sendable {
    public let model: String?
    public let role: String
    public let content: SamplingContentPart
}

// MARK: - MCP Tool Definition

/// What a tool learns about its call beyond the arguments — the multi
/// round-trip exchange, where the client answers a previous `input_required`
/// result and echoes the state that came with it. Both are empty on a first
/// attempt.
public struct MCPToolCallContext: Sendable {
    /// Client answers keyed by the identifiers the tool's `inputRequests` used.
    public let inputResponses: [String: JSONValue]
    /// The opaque state this tool issued alongside those requests.
    public let requestState: String?

    public init(inputResponses: [String: JSONValue] = [:], requestState: String? = nil) {
        self.inputResponses = inputResponses
        self.requestState = requestState
    }
}

public struct MCPToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: JSONValue]
    public let handler: @Sendable ([String: JSONValue], MCPToolCallContext) -> MCPToolResult

    /// A tool that reads the call context — needed only by tools that ask the
    /// client for input and resume when it answers.
    public init(
        name: String,
        description: String,
        inputSchema: [String: JSONValue],
        contextualHandler: @Sendable @escaping (
            [String: JSONValue], MCPToolCallContext
        ) -> MCPToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = contextualHandler
    }

    /// A tool that answers from its arguments alone, which is nearly all of them.
    public init(
        name: String,
        description: String,
        inputSchema: [String: JSONValue],
        handler: @Sendable @escaping ([String: JSONValue]) -> MCPToolResult
    ) {
        self.init(
            name: name, description: description, inputSchema: inputSchema,
            contextualHandler: { args, _ in handler(args) })
    }
}

public struct MCPToolResult: Sendable {
    public let content: [MCPContent]
    public let isError: Bool
    /// Requests the client must fulfil before this tool can finish, keyed by
    /// server-assigned identifiers. Non-empty turns the response into an
    /// `InputRequiredResult`: the call ends, the client answers and retries.
    public let inputRequests: [String: MCPInputRequest]
    /// Opaque state echoed back on the retry, carrying whatever the tool needs
    /// to resume. Meaningless to the client, which must not inspect it.
    public let requestState: String?

    public init(
        content: [MCPContent],
        isError: Bool,
        inputRequests: [String: MCPInputRequest] = [:],
        requestState: String? = nil
    ) {
        self.content = content
        self.isError = isError
        self.inputRequests = inputRequests
        self.requestState = requestState
    }

    /// A result asking the client to fulfil `inputRequests` and retry, carrying
    /// `requestState` so the retry can pick up where this call stopped.
    ///
    /// The revision requires at least one of the two, so a caller supplying
    /// neither would produce an invalid result.
    public static func inputRequired(
        _ inputRequests: [String: MCPInputRequest], requestState: String? = nil
    ) -> MCPToolResult {
        MCPToolResult(
            content: [], isError: false,
            inputRequests: inputRequests, requestState: requestState)
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

/// A server-to-client request carried in an `InputRequiredResult`.
///
/// The `2026-07-28` revision replaced server-initiated requests with this
/// pattern: rather than writing a request to stdout, the server embeds it in
/// its result and the client fulfils it before retrying the original call.
/// `method` is one of `sampling/createMessage`, `elicitation/create`, or
/// `roots/list`.
public struct MCPInputRequest: Sendable {
    /// The client method being asked for.
    public let method: String
    /// Parameters for that method.
    public let params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
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
