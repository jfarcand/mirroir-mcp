/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: MCP (Model Context Protocol) server: JSON-RPC 2.0 dispatch, and the stdio loop that feeds it.
// ABOUTME: Handles initialize, tools/list, and tools/call methods per the MCP specification.

import Foundation
import HelperLib
import os

// MARK: - MCP Server

final class MCPServer: Sendable {
    private let tools = OSAllocatedUnfairLock(initialState: [String: MCPToolDefinition]())
    private let sequenceAdvisor = RepeatedSequenceAdvisor()
    private let policy: PermissionPolicy
    /// Reads the screen of the target a tool call names, for the driving check
    /// (`DrivingGuard`) in front of every input. Nil until tools are registered.
    private let screenReader = OSAllocatedUnfairLock(
        initialState: (@Sendable ([String: JSONValue]) -> ScreenDescriber.DescribeResult?)?.none)
    /// Counter for server-initiated request IDs (sampling, etc.).
    let requestCounter = OSAllocatedUnfairLock(initialState: 0)
    /// Capabilities the stdio client declared in its `initialize` handshake.
    /// Only stdio keeps them: its process serves one client for its whole
    /// life. Over HTTP there is no session to keep them in.
    let handshakeCapabilities = OSAllocatedUnfairLock(initialState: JSONValue?.none)
    /// The revision and declared capabilities of the request being served.
    /// Both transports serve one request at a time, so this describes the
    /// request a tool handler is running under, and no other.
    let currentScope = OSAllocatedUnfairLock(initialState: RequestScope.none)
    /// How requests reach this server, which decides whether it may send its own.
    let transport: MCPTransport
    /// The stdio connection while `run(input:output:)` serves it; nil over HTTP.
    let stdioSession = OSAllocatedUnfairLock(initialState: StdioSession?.none)
    init(policy: PermissionPolicy, transport: MCPTransport) {
        self.policy = policy
        self.transport = transport
    }

    func registerTool(_ tool: MCPToolDefinition) {
        tools.withLock { $0[tool.name] = tool }
    }

    /// Set how the driving check reads the screen of the target a call names.
    func setScreenReader(_ reader: @escaping @Sendable ([String: JSONValue]) -> ScreenDescriber.DescribeResult?) {
        screenReader.withLock { $0 = reader }
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

    /// A tool's display name: its words capitalized, `describe_screen` as
    /// "Describe Screen". Derived from the name, so the two never disagree.
    static func title(for name: String) -> String {
        name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The `_meta` key Claude Code (2.1.285 and later) reads on a tools/list entry.
    static let alwaysLoadKey = "anthropic/alwaysLoad"

    /// Serve one request. `call` carries a tool call's cancellation and
    /// progress from the transport that received it.
    func handleRequest(_ request: JSONRPCRequest, call: MCPCallControl = MCPCallControl()) -> JSONRPCResponse? {
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
                return Self.unsupportedVersionError(id: request.id, requested: requested)
            }
            if let missing = Self.missingRequiredMetaField(request) {
                return JSONRPCResponse(
                    id: request.id, result: nil,
                    error: JSONRPCError(
                        code: Self.invalidParamsCode,
                        message: "Invalid params: missing required _meta field '\(missing)'"
                    )
                )
            }
        }

        // Tool handlers read the revision and capabilities of this request, and
        // of no other, from here.
        currentScope.withLock { $0 = scope(for: request, modern: isModern) }

        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "tools/list":
            return handleToolsList(request, modern: isModern)
        case "tools/call":
            return handleToolsCall(request, modern: isModern, call: call)
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
    static func missingRequiredMetaField(_ request: JSONRPCRequest) -> String? {
        let meta = request.params?.member("_meta")
        if meta?.member(MetaKey.clientCapabilities) == nil { return MetaKey.clientCapabilities }
        return nil
    }

    /// `UnsupportedProtocolVersionError` with the versions we support.
    static func unsupportedVersionError(id: RequestID?, requested: String) -> JSONRPCResponse {
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
    static let unsupportedProtocolVersionCode = -32022

    /// Spec-allocated code for `MissingRequiredClientCapabilityError`: the
    /// request needs a capability the client did not declare.
    static let missingClientCapabilityCode = -32021

    /// JSON-RPC `Invalid params`, which the revision also uses for a request
    /// missing a required `_meta` field.
    static let invalidParamsCode = -32602

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
        recordHandshake(request.params?.member("capabilities"))

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
            // Sorted by name, so every call lists the tools in the same order.
            snapshot.values
                .filter { policy.isToolVisible($0.name) }
                .sorted { $0.name < $1.name }
                .map { tool in
                    var entry: [String: JSONValue] = [
                        "name": .string(tool.name),
                        "title": .string(Self.title(for: tool.name)),
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

    private func handleToolsCall(_ request: JSONRPCRequest, modern: Bool, call: MCPCallControl) -> JSONRPCResponse {
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
        let reader = screenReader.withLock { $0 }
        if let refusal = DrivingGuard.refusal(tool: toolName, policy: policy, read: { reader?(arguments) }) {
            DebugLog.log("permission", "driving refused \(toolName)")
            let result = completeResult([
                "content": .array([MCPContent.text(refusal).toJSON()]),
                "isError": .bool(true),
            ], modern: modern)
            return JSONRPCResponse(id: request.id, result: result, error: nil)
        }
        let context = MCPToolCallContext(
            inputResponses: Self.inputResponses(in: request),
            requestState: Self.requestState(in: request),
            call: call)
        // Synthetic input does not reset the idle timer: keep the screen saver off the mirror.
        let toolResult = DisplayAwake.shared.during("mirroir-mcp \(toolName)") { tool.handler(arguments, context) }

        if let required = toolResult.missingClientCapabilities {
            return missingCapabilityResponse(request, toolResult: toolResult, required: required, modern: modern)
        }
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

}
