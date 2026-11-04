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
    private let sequenceAdvisor = RepeatedSequenceAdvisor()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let policy: PermissionPolicy
    /// Counter for server-initiated request IDs (sampling, etc.).
    let requestCounter = OSAllocatedUnfairLock(initialState: 0)
    /// Capabilities the client declared in its `initialize` handshake, which
    /// tell us which server-initiated requests it can answer.
    let clientCapabilities = OSAllocatedUnfairLock(initialState: JSONValue?.none)
    /// Whether the request being served right now came from a stateless-era
    /// client. The run loop serves one request at a time, so this describes the
    /// request a tool handler is running under.
    let servingModernRequest = OSAllocatedUnfairLock(initialState: false)
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
        while true {
            guard let line = readLine(strippingNewline: true) else { break }
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
        }
    }

    /// Revisions that negotiate statelessly, carrying the protocol version in
    /// each request's `_meta`. Only these are meaningful in
    /// `_meta.io.modelcontextprotocol/protocolVersion`: naming an
    /// `initialize`-era revision there asks for a negotiation that revision has
    /// no concept of.
    static let modernProtocolVersions = ["2026-07-28"]

    /// Every revision this server serves, most recent first. `server/discover`
    /// advertises the whole list — a client reads the legacy entries to decide
    /// whether falling back to the `initialize` handshake is available.
    static var supportedProtocolVersions: [String] {
        modernProtocolVersions + legacyProtocolVersions
    }

    /// Reserved `_meta` keys of the modern (`2026-07-28`) revision. The first
    /// three ride on every client request; `serverInfo` is the canonical place
    /// for server identity on a result.
    enum MetaKey {
        static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        static let clientInfo = "io.modelcontextprotocol/clientInfo"
        static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        static let serverInfo = "io.modelcontextprotocol/serverInfo"
    }

    /// Server identity, which the spec says to report on every modern result.
    /// `Implementation` requires both `name` and `version`.
    static let serverInfo: JSONValue = .object([
        "name": .string("mirroir-mcp"),
        "version": .string(MirroirVersion.current),
    ])

    /// How long a client may cache a `server/discover` response (1 hour).
    private static let discoverTtlMs = 3_600_000

    /// How long a client may cache a `tools/list` response (1 minute). Short by
    /// design: the visible tool set is derived from the permission policy on
    /// disk, so an edited `permissions.json` must take effect promptly.
    private static let toolsListTtlMs = 60_000

    /// Tools a client with tool search should load before the model asks. Claude
    /// Code defers MCP tools and the model loads only those it already expects
    /// to use; measured on the iPhone, it never loaded run_steps by itself.
    static let alwaysLoadedTools: Set<String> = ["run_steps"]

    /// The `_meta` key Claude Code (2.1.285 and later) reads on a tools/list entry.
    static let alwaysLoadKey = "anthropic/alwaysLoad"

    func handleRequest(_ request: JSONRPCRequest) -> JSONRPCResponse? {
        // Notifications have no id — the spec says receivers MUST NOT respond
        if request.id == nil {
            return nil
        }

        // `server/discover` is the modern MUST-implement method and the stdio
        // backward-compat probe; it is answered regardless of negotiated era.
        if request.method == "server/discover" {
            return handleDiscover(request)
        }

        // Dual-era routing: a request carrying the modern `_meta`
        // protocolVersion is served statelessly per 2026-07-28; otherwise it is
        // a legacy request (post-`initialize`) and served as before. For modern
        // requests, validate the version and required `_meta` fields up front.
        let modernVersion = request.params?
            .member("_meta")?.member(MetaKey.protocolVersion)?.asString()
        let isModern = modernVersion != nil
        if let requested = modernVersion {
            // Validated against the stateless revisions alone: a legacy version
            // here is not a legacy request, it is a request for stateless
            // negotiation at a revision that cannot do it. The error names the
            // revisions that can, and the legacy ones it can fall back to.
            if !Self.modernProtocolVersions.contains(requested) {
                return unsupportedVersionError(id: request.id, requested: requested)
            }
            if let missing = missingRequiredMetaField(request) {
                return JSONRPCResponse(
                    id: request.id, result: nil,
                    error: JSONRPCError(
                        code: -32602,
                        message: "Invalid params: missing required _meta field '\(missing)'"
                    )
                )
            }
        }

        // Tool handlers consult this to know whether server-initiated requests
        // are permitted while this request is in flight.
        servingModernRequest.withLock { $0 = isModern }

        // The stateless revision has no handshake to record capabilities from —
        // every request carries them instead, so they are read here rather than
        // in `initialize`.
        if isModern, let declared = request.params?.member("_meta")?
            .member(MetaKey.clientCapabilities) {
            clientCapabilities.withLock { $0 = declared }
        }

        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "tools/list":
            return handleToolsList(request, modern: isModern)
        case "tools/call":
            return handleToolsCall(request, modern: isModern)
        case "ping":
            return JSONRPCResponse(id: request.id, result: completeResult([:], modern: isModern), error: nil)
        default:
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)")
            )
        }
    }

    /// Wrap a modern result object with `resultType: "complete"` and the server
    /// identity every modern result should carry. Legacy (`initialize`-era)
    /// responses omit both; clients treat an absent `resultType` as
    /// `"complete"` for backward compatibility, and learn the server identity
    /// from the `initialize` handshake instead.
    private func completeResult(_ fields: [String: JSONValue], modern: Bool) -> JSONValue {
        guard modern else { return .object(fields) }
        var withType = fields
        withType["resultType"] = .string("complete")
        withType["_meta"] = .object([MetaKey.serverInfo: Self.serverInfo])
        return .object(withType)
    }

    /// Add the cache directives a modern (`2026-07-28`) list result must carry.
    /// The revision makes `ttlMs` and `cacheScope` required on `tools/list` and
    /// `server/discover` — a client validating against that schema rejects the
    /// whole result when either is absent.
    private func cacheable(
        _ fields: [String: JSONValue], ttlMs: Int, scope: CacheScope
    ) -> [String: JSONValue] {
        var withDirectives = fields
        withDirectives["ttlMs"] = .number(Double(ttlMs))
        withDirectives["cacheScope"] = .string(scope.rawValue)
        return withDirectives
    }

    /// Whether a cached result may be shared across users (`public`) or belongs
    /// to the client that fetched it (`private`).
    private enum CacheScope: String {
        case publicScope = "public"
        case privateScope = "private"
    }

    /// First required modern `_meta` field that is absent, or nil if all present.
    /// The revision requires only `protocolVersion` (already established by the
    /// time this runs) and `clientCapabilities` — `clientInfo` is optional, so
    /// rejecting a request that omits it would turn away conformant clients.
    private func missingRequiredMetaField(_ request: JSONRPCRequest) -> String? {
        let meta = request.params?.member("_meta")
        if meta?.member(MetaKey.clientCapabilities) == nil { return MetaKey.clientCapabilities }
        return nil
    }

    /// `UnsupportedProtocolVersionError` with the versions we support.
    private func unsupportedVersionError(id: RequestID?, requested: String) -> JSONRPCResponse {
        let supported = Self.supportedProtocolVersions.map { JSONValue.string($0) }
        let data: JSONValue = .object([
            "supported": .array(supported),
            "requested": .string(requested),
        ])
        return JSONRPCResponse(
            id: id, result: nil,
            error: JSONRPCError(
                code: Self.unsupportedProtocolVersionCode,
                message: "Unsupported protocol version", data: data)
        )
    }

    /// Spec-allocated code for `UnsupportedProtocolVersionError`. It has to come
    /// from the `-32020`…`-32099` specification range: the `-32000`…`-32019`
    /// range is implementation-defined, so a code there carries no meaning
    /// across implementations and a client cannot recognise the version
    /// mismatch it signals.
    private static let unsupportedProtocolVersionCode = -32022

    /// Modern `server/discover` — advertise supported versions, capabilities,
    /// and identity so a client can pick a version without a round-trip error.
    private func handleDiscover(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let supported = Self.supportedProtocolVersions.map { JSONValue.string($0) }
        var fields: [String: JSONValue] = [
            "supportedVersions": .array(supported),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "instructions": .string(OperatingManual.essentials),
        ]
        // Identity and capabilities are the same for every client, so the
        // response is shareable. `server/discover` exists only in the modern
        // revision, so its result always carries the modern envelope.
        fields = cacheable(fields, ttlMs: Self.discoverTtlMs, scope: .publicScope)
        return JSONRPCResponse(
            id: request.id, result: completeResult(fields, modern: true), error: nil)
    }

    /// Legacy (`initialize`-handshake) protocol versions, most recent first.
    /// `initialize` negotiates only among these — the modern `2026-07-28`
    /// revision has no handshake, so it is never the outcome of `initialize`.
    static let legacyProtocolVersions = ["2025-11-25", "2024-11-05"]

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        // Negotiate protocol version: use the client's version if it is a legacy
        // version we support, otherwise fall back to our most recent legacy one.
        let clientVersion = request.params?.getString("protocolVersion")
        let negotiatedVersion: String
        if let clientVersion, Self.legacyProtocolVersions.contains(clientVersion) {
            negotiatedVersion = clientVersion
        } else {
            negotiatedVersion = Self.legacyProtocolVersions[0]
        }

        // Remember what the client can do — sampling is a client capability,
        // and we may only ask for it if the client offered it.
        clientCapabilities.withLock { $0 = request.params?.member("capabilities") }

        let result: JSONValue = .object([
            "protocolVersion": .string(negotiatedVersion),
            // `tools` is the only capability we implement. Sampling belongs to
            // the client, so it is never advertised here.
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string("mirroir-mcp"),
                "version": .string(MirroirVersion.current),
            ]),
            "instructions": .string(OperatingManual.essentials),
        ])
        return JSONRPCResponse(id: request.id, result: result, error: nil)
    }

    private func handleToolsList(_ request: JSONRPCRequest, modern: Bool) -> JSONRPCResponse {
        let toolList: [JSONValue] = tools.withLock { snapshot in
            snapshot.values
                .filter { policy.isToolVisible($0.name) }
                .map { tool in
                    var entry: [String: JSONValue] = [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "inputSchema": .object(tool.inputSchema),
                        "annotations": .object(PermissionPolicy.annotations(for: tool.name)),
                    ]
                    if Self.alwaysLoadedTools.contains(tool.name) {
                        entry["_meta"] = .object([Self.alwaysLoadKey: .bool(true)])
                    }
                    return .object(entry)
                }
        }
        var fields: [String: JSONValue] = ["tools": .array(toolList)]
        if modern {
            // The visible tool set is filtered by this machine's permission
            // policy, so the cached list belongs to the client that fetched it.
            fields = cacheable(fields, ttlMs: Self.toolsListTtlMs, scope: .privateScope)
        }
        let result = completeResult(fields, modern: modern)
        return JSONRPCResponse(id: request.id, result: result, error: nil)
    }

    private func handleToolsCall(_ request: JSONRPCRequest, modern: Bool) -> JSONRPCResponse {
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
            let result = completeResult([
                "content": content,
                "isError": .bool(true),
            ], modern: modern)
            return JSONRPCResponse(id: request.id, result: result, error: nil)
        }

        let arguments = request.params?.getArguments() ?? [:]
        let context = MCPToolCallContext(
            inputResponses: Self.inputResponses(in: request),
            requestState: Self.requestState(in: request))
        let toolResult = tool.handler(arguments, context)

        if !toolResult.inputRequests.isEmpty || toolResult.requestState != nil {
            return inputRequiredResponse(request, toolResult: toolResult, modern: modern)
        }

        var replyContent = toolResult.content
        let advice = sequenceAdvisor.observe(
            tool: toolName, arguments: arguments, failed: toolResult.isError)
        if let advice, policy.isToolVisible("run_steps") {
            replyContent.append(.text(advice))
        }
        let content: JSONValue = .array(replyContent.map { $0.toJSON() })
        let result = completeResult([
            "content": content,
            "isError": .bool(toolResult.isError),
        ], modern: modern)
        return JSONRPCResponse(id: request.id, result: result, error: nil)
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
