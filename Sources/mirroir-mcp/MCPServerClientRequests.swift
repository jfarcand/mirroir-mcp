// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The MCP server's client-facing requests — the MRTR exchange and sampling.
// ABOUTME: Both ask the client for something; which one is available depends on the revision.

import Foundation
import HelperLib

/// How requests reach an `MCPServer`.
enum MCPTransport: Sendable {
    /// Line-delimited JSON on stdin and stdout, one client for the life of the process.
    case stdio
    /// One POST per message (`mirroir-mcp serve`); nothing is ever written unasked.
    case http
}

extension MCPServer {

    /// Build the `InputRequiredResult` for a tool that needs the client to
    /// answer something before it can finish.
    ///
    /// Only the stateless revision defines this exchange. A legacy client has no
    /// way to fulfil the requests or retry with them, so asking it would strand
    /// the call — it gets an error naming the shortfall instead.
    func inputRequiredResponse(
        _ request: JSONRPCRequest, toolResult: MCPToolResult, modern: Bool
    ) -> JSONRPCResponse {
        guard modern else {
            return JSONRPCResponse(
                id: request.id, result: nil,
                error: JSONRPCError(
                    code: -32603,
                    message: "Tool needs client input, which requires protocol revision "
                        + "\(Self.modernProtocolVersions[0]) or later")
            )
        }

        var requests: [String: JSONValue] = [:]
        for (key, inputRequest) in toolResult.inputRequests {
            requests[key] = .object([
                "method": .string(inputRequest.method),
                "params": inputRequest.params,
            ])
        }

        var fields: [String: JSONValue] = ["resultType": .string("input_required")]
        if !requests.isEmpty {
            fields["inputRequests"] = .object(requests)
        }
        if let state = toolResult.requestState {
            fields["requestState"] = .string(state)
        }
        fields["_meta"] = .object([MetaKey.serverInfo: Self.serverInfo])
        return JSONRPCResponse(id: request.id, result: .object(fields), error: nil)
    }

    /// Answers the client supplied when retrying a call that asked for input,
    /// keyed by the identifiers the previous `inputRequests` used.
    static func inputResponses(in request: JSONRPCRequest) -> [String: JSONValue] {
        guard case .object(let responses)? = request.params?.member("inputResponses") else {
            return [:]
        }
        return responses
    }

    /// The opaque state echoed back on a retry, or nil on a first attempt.
    static func requestState(in request: JSONRPCRequest) -> String? {
        request.params?.member("requestState")?.asString()
    }

    // MARK: - Server-to-Client Sampling

    /// Whether the client declared the `sampling` capability when it connected.
    func clientSupportsSampling() -> Bool {
        clientCapabilities.withLock { $0?.member("sampling") != nil }
    }

    /// Whether a server-initiated request may be written to stdout right now.
    /// Only on stdio, where stdout reaches the client: over HTTP there is no
    /// channel to write one on. And never while serving a `2026-07-28`
    /// request: that revision's server writes only responses and
    /// notifications, and reaches the client through `InputRequiredResult`.
    func mayInitiateRequest() -> Bool {
        transport == .stdio && !servingModernRequest.withLock { $0 }
    }

    /// Send a sampling/createMessage request to the MCP client and wait for the response.
    ///
    /// This is a server-initiated request: we write a JSON-RPC request to stdout and read
    /// the client's response from stdin. Safe to call from within a tool handler because
    /// the server's main loop is blocked waiting for the handler to return.
    ///
    /// Two conditions gate it. `mayInitiateRequest()` must hold: the transport
    /// is stdio, and the request being served is not from the `2026-07-28`
    /// revision, which forbids a server from writing JSON-RPC requests to
    /// stdout; a tool reaches that client by returning input requests instead
    /// (`inputRequiredResponse`). Beyond that, only clients that declared
    /// `sampling` in their `initialize` handshake are asked, since sampling is
    /// a client capability.
    ///
    /// - Parameter params: Sampling parameters (messages, max tokens, system prompt).
    /// - Returns: The sampling response text, or nil if the client doesn't support sampling.
    func sendSamplingRequest(_ params: SamplingParams) -> String? {
        guard mayInitiateRequest() else {
            DebugLog.log(
                "sampling",
                "No server-initiated request here: HTTP transport, or a 2026-07-28 request")
            return nil
        }
        guard clientSupportsSampling() else {
            DebugLog.log("sampling", "Client did not declare sampling support — skipping request")
            return nil
        }

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
}
