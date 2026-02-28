// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: MCP (Model Context Protocol) server implementing JSON-RPC 2.0 over stdio.
// ABOUTME: Handles initialize, tools/list, and tools/call methods per the MCP specification.

import Foundation
import HelperLib
import os

// MARK: - MCP Server

final class MCPServer: Sendable {
    private let tools = OSAllocatedUnfairLock(initialState: [String: MCPToolDefinition]())
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let policy: PermissionPolicy
    /// Counter for server-initiated request IDs (sampling, etc.).
    private let requestCounter = OSAllocatedUnfairLock(initialState: 0)
    init(policy: PermissionPolicy) {
        self.policy = policy
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func registerTool(_ tool: MCPToolDefinition) {
        tools.withLock { $0[tool.name] = tool }
    }

    /// Run the MCP server, reading JSON-RPC from stdin and writing to stdout.
    func run() {
        // Use line-delimited JSON (one JSON object per line)
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }

            guard let data = line.data(using: .utf8) else {
                writeError(id: nil, code: -32700, message: "Parse error: invalid UTF-8")
                continue
            }

            let request: JSONRPCRequest
            do {
                request = try decoder.decode(JSONRPCRequest.self, from: data)
            } catch {
                DebugLog.log("MCPServer", "JSON-RPC decode failed: \(error)")
                writeError(id: nil, code: -32700, message: "Parse error: \(error.localizedDescription)")
                continue
            }

            guard let response = handleRequest(request) else {
                continue  // Notifications produce no response per JSON-RPC 2.0
            }
            writeResponse(response)
            HotReload.reloadIfNeeded()
        }
    }

    /// Supported MCP protocol versions, most recent first.
    static let supportedProtocolVersions = ["2025-11-25", "2024-11-05"]

    func handleRequest(_ request: JSONRPCRequest) -> JSONRPCResponse? {
        // Notifications have no id — the spec says receivers MUST NOT respond
        if request.id == nil {
            return nil
        }

        switch request.method {
        case "initialize":
            return handleInitialize(request)
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
        // Negotiate protocol version: use the client's version if we support it,
        // otherwise fall back to our most recent supported version.
        let clientVersion = request.params?.getString("protocolVersion")
        let negotiatedVersion: String
        if let clientVersion, Self.supportedProtocolVersions.contains(clientVersion) {
            negotiatedVersion = clientVersion
        } else {
            negotiatedVersion = Self.supportedProtocolVersions[0]
        }

        let result: JSONValue = .object([
            "protocolVersion": .string(negotiatedVersion),
            "capabilities": .object([
                "tools": .object([:]),
                "sampling": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string("mirroir-mcp"),
                "version": .string("0.23.0"),
            ]),
        ])
        return JSONRPCResponse(id: request.id, result: result, error: nil)
    }

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let toolList: [JSONValue] = tools.withLock { snapshot in
            snapshot.values
                .filter { policy.isToolVisible($0.name) }
                .map { tool in
                    .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "inputSchema": .object(tool.inputSchema),
                    ])
                }
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

        guard let tool = tools.withLock({ $0[toolName] }) else {
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Unknown tool: \(toolName)")
            )
        }

        let decision = policy.checkTool(toolName)
        DebugLog.log("permission", "checkTool(\(toolName))=\(decision)")
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

    // MARK: - Server-to-Client Sampling

    /// Send a sampling/createMessage request to the MCP client and wait for the response.
    ///
    /// This is a server-initiated request: we write a JSON-RPC request to stdout and read
    /// the client's response from stdin. Safe to call from within a tool handler because
    /// the server's main loop is blocked waiting for the handler to return.
    ///
    /// - Parameter params: Sampling parameters (messages, max tokens, system prompt).
    /// - Returns: The sampling response text, or nil if the client doesn't support sampling.
    func sendSamplingRequest(_ params: SamplingParams) -> String? {
        let requestId = requestCounter.withLock { counter -> Int in
            counter += 1
            return counter
        }

        // Build JSON-RPC request for sampling/createMessage
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": "sampling/createMessage",
            "params": encodeSamplingParams(params),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: data, encoding: .utf8) else {
            DebugLog.log("sampling", "Failed to encode sampling request")
            return nil
        }

        // Send request to client
        print(jsonString)
        fflush(stdout)

        // Read response from client
        guard let responseLine = readLine(strippingNewline: true),
              let responseData = responseLine.data(using: .utf8) else {
            DebugLog.log("sampling", "No response from client for sampling request")
            return nil
        }

        // Parse JSON-RPC response
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let content = result["content"] as? [String: Any],
              let text = content["text"] as? String else {
            DebugLog.log("sampling", "Failed to parse sampling response")
            return nil
        }

        return text
    }

    /// Encode SamplingParams to a dictionary for JSON serialization.
    private func encodeSamplingParams(_ params: SamplingParams) -> [String: Any] {
        var dict: [String: Any] = [
            "maxTokens": params.maxTokens,
        ]
        if let systemPrompt = params.systemPrompt {
            dict["systemPrompt"] = systemPrompt
        }

        dict["messages"] = params.messages.map { message -> [String: Any] in
            var msgDict: [String: Any] = ["role": message.role]
            switch message.content {
            case .text(let text):
                msgDict["content"] = ["type": "text", "text": text]
            case .mixed(let parts):
                msgDict["content"] = parts.map { part -> [String: Any] in
                    var partDict: [String: Any] = ["type": part.type]
                    if let text = part.text { partDict["text"] = text }
                    if let data = part.data { partDict["data"] = data }
                    if let mime = part.mimeType { partDict["mimeType"] = mime }
                    return partDict
                }
            }
            return msgDict
        }

        return dict
    }

    private func writeResponse(_ response: JSONRPCResponse) {
        let data: Data
        do {
            data = try encoder.encode(response)
        } catch {
            DebugLog.log("MCPServer", "Failed to encode response: \(error)")
            // Send a minimal error response as a fallback
            let fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: response encoding failed"}}"#
            print(fallback)
            fflush(stdout)
            return
        }
        guard let jsonString = String(data: data, encoding: .utf8) else {
            DebugLog.log("MCPServer", "Response data is not valid UTF-8")
            return
        }
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
