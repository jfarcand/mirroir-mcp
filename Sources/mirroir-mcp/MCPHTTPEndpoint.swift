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
// ABOUTME: The MCP Streamable HTTP endpoint as a pure function: one HTTP request in, one HTTP response out.
// ABOUTME: Checks path, method, Origin, bearer token and the MCP headers before a request reaches the server.

import Foundation
import HelperLib

/// Turns an HTTP request into the JSON-RPC request `MCPServer` serves, and its
/// answer back into HTTP. One endpoint, POST only, one JSON object per
/// response: no event stream and no session, which is all the `2026-07-28`
/// transport requires of a server and all a `2025-11-25` client needs.
enum MCPHTTPEndpoint {

    /// The one path the server answers on.
    static let path = "/mcp"

    /// What the endpoint needs to know about its deployment.
    struct Config: Sendable {
        /// The bearer token every request must present.
        let token: String
        /// `Origin` values accepted. Empty refuses every browser page; MCP
        /// clients send no `Origin` and are not affected.
        let allowedOrigins: Set<String>
    }

    /// Request headers of the MCP HTTP transport, lower-cased as the parser stores them.
    enum Header {
        static let protocolVersion = "mcp-protocol-version"
        static let method = "mcp-method"
        static let name = "mcp-name"
    }

    /// JSON-RPC error codes the endpoint sends or maps to an HTTP status.
    enum ErrorCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let internalError = -32603
        /// An MCP header disagrees with the body it describes.
        static let headerMismatch = -32020
    }

    /// Deepest nesting of arrays and objects accepted in a body. A tool call
    /// nests four or five levels; a body nested hundreds deep exists only to
    /// exhaust the stack of the thread that decodes it.
    static let maxNestingDepth = 64

    /// How a header value carries text outside what a header may hold:
    /// `=?base64?<base64 of the UTF-8 text>?=`.
    static let base64Prefix = "=?base64?"
    static let base64Suffix = "?="

    private static let bearerPrefix = "Bearer "

    /// The refusal a request earns from its request line and headers alone, or
    /// nil when its body is worth reading: wrong path, wrong method, a browser
    /// origin, a missing or wrong token, a body that is not JSON. The listener
    /// asks this before reading any body, so a caller without the token costs
    /// the server one set of headers and learns nothing about what it parses.
    static func refusalBeforeBody(_ request: HTTPRequest, config: Config) -> HTTPResponse? {
        guard request.path == path else {
            return .text(404, "The MCP endpoint is \(path).")
        }
        guard request.method == "POST" else {
            return .text(405, "The MCP endpoint accepts POST only.", headers: ["Allow": "POST"])
        }
        if let origin = request.headers["origin"], !config.allowedOrigins.contains(origin) {
            return .text(403, "Origin \(origin) is not allowed. Pass --allow-origin to accept it.")
        }
        guard let authorization = request.headers["authorization"],
              authorization.hasPrefix(bearerPrefix),
              ServeToken.matches(presented: String(authorization.dropFirst(bearerPrefix.count)),
                                 expected: config.token) else {
            return .text(401, "Send the header Authorization: Bearer <token>.",
                         headers: ["WWW-Authenticate": "Bearer"])
        }
        let contentType = request.headers["content-type"]?
            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard contentType == "application/json" else {
            return .text(415, "Content-Type must be application/json.")
        }
        return nil
    }

    /// Answer one HTTP request. `dispatch` is called at most once, and only for
    /// a request that passed every check, with the control its call runs
    /// under; it returns nil for a notification.
    ///
    /// The client leaving cancels the call: on this transport a closed
    /// connection is the cancellation. A `tools/call` whose client asked for
    /// progress (`_meta.progressToken`) and accepts `text/event-stream` gets
    /// its progress as events, then its response as the last event. Every
    /// other reply is one JSON body, which keeps its status: a stream, once
    /// open, can only be 200.
    static func respond(
        to request: HTTPRequest, config: Config, channel: any HTTPExchangeChannel,
        dispatch: (JSONRPCRequest, MCPCallControl) -> JSONRPCResponse?
    ) -> HTTPReply {
        switch check(request, config: config) {
        case .failure(let refusal):
            return .whole(refusal.response)
        case .success(let checked):
            return reply(to: checked, channel: channel, dispatch: dispatch)
        }
    }

    /// A request that passed every check, and whether it speaks the stateless revision.
    struct CheckedRequest {
        let http: HTTPRequest
        let rpc: JSONRPCRequest
        let modern: Bool
    }

    /// The HTTP answer that ends a request before it is dispatched.
    struct Refusal: Error {
        let response: HTTPResponse
    }

    private static func reply(
        to checked: CheckedRequest, channel: any HTTPExchangeChannel,
        dispatch: (JSONRPCRequest, MCPCallControl) -> JSONRPCResponse?
    ) -> HTTPReply {
        let rpc = checked.rpc
        let streams = StreamedFlag()
        let wantsProgress = rpc.method == "tools/call"
            && SSEFrame.allowsEventStream(accept: checked.http.headers["accept"])
        let call = MCPCallControl(
            progressToken: wantsProgress ? ProgressNotification.token(in: rpc.params) : nil,
            emit: { params in
                streams.set()
                channel.sendEvent(notification(method: ProgressNotification.method, params: params))
            })
        channel.onAbandon { call.cancel(reason: "the client closed the connection") }

        let response = dispatch(rpc, call)
        // A cancelled call gets no answer: its client has gone.
        guard call.finish() else { return .whole(HTTPResponse(status: 202)) }
        guard let response else { return .whole(HTTPResponse(status: 202)) }
        guard streams.isSet else {
            return .whole(encoded(response, status: status(for: response, rpc: rpc, modern: checked.modern)))
        }
        guard let body = try? JSONEncoder().encode(response) else {
            DebugLog.log("serve", "Failed to encode the final response of a stream")
            return .streamEnded
        }
        channel.sendEvent(body)
        return .streamEnded
    }

    /// Whether a reply has started streaming; set from the call's progress.
    private final class StreamedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// A notification as one line of JSON.
    private static func notification(method: String, params: JSONValue) -> Data {
        let message: JSONValue = .object([
            "jsonrpc": .string("2.0"), "method": .string(method), "params": params,
        ])
        return (try? JSONEncoder().encode(message)) ?? Data()
    }

    /// Every check a request passes before it is dispatched, in order.
    static func check(_ request: HTTPRequest, config: Config) -> Result<CheckedRequest, Refusal> {
        if let refusal = refusalBeforeBody(request, config: config) { return refused(refusal) }
        guard nestingDepth(of: request.body) <= maxNestingDepth else {
            return refused(rpcError(400, code: ErrorCode.invalidRequest,
                            message: "Invalid request: nested deeper than \(maxNestingDepth) levels"))
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed])
        } catch {
            return refused(rpcError(400, code: ErrorCode.parseError, message: "Parse error: the body is not JSON"))
        }
        guard let object = parsed as? [String: Any] else {
            return refused(rpcError(400, code: ErrorCode.invalidRequest,
                            message: "Invalid request: send one JSON-RPC object per POST, not a batch"))
        }
        // A client's answer to a server request. This server sends none over
        // HTTP, so there is nothing to match it with.
        guard object["method"] != nil else { return refused(HTTPResponse(status: 202)) }

        let rpc: JSONRPCRequest
        do {
            rpc = try JSONDecoder().decode(JSONRPCRequest.self, from: request.body)
        } catch {
            return refused(rpcError(400, code: ErrorCode.invalidRequest,
                            message: "Invalid request: \(error.localizedDescription)"))
        }

        let modernVersion = rpc.params?.member("_meta")?
            .member(MCPServer.MetaKey.protocolVersion)?.asString()
        if let mismatch = headerMismatch(request, rpc: rpc, modernVersion: modernVersion) {
            return refused(rpcError(400, code: ErrorCode.headerMismatch, message: mismatch, id: rpc.id))
        }
        // An `initialize`-era request may send the version header; a version
        // not served here gets the list a client can retry with.
        if modernVersion == nil, let versionHeader = request.headers[Header.protocolVersion],
           !MCPServer.supportedProtocolVersions.contains(versionHeader) {
            return refused(encoded(MCPServer.unsupportedVersionError(id: rpc.id, requested: versionHeader), status: 400))
        }

        return .success(CheckedRequest(http: request, rpc: rpc, modern: modernVersion != nil))
    }

    private static func refused(_ response: HTTPResponse) -> Result<CheckedRequest, Refusal> {
        .failure(Refusal(response: response))
    }

    /// A JSON-RPC response as an HTTP response with `status`.
    private static func encoded(_ response: JSONRPCResponse, status: Int) -> HTTPResponse {
        do {
            return .json(status, try JSONEncoder().encode(response))
        } catch {
            DebugLog.log("serve", "Failed to encode response: \(error)")
            return rpcError(500, code: ErrorCode.internalError, message: "Internal error: response encoding failed",
                            id: response.id)
        }
    }

    /// The reason a request's MCP headers are refused, or nil when they agree
    /// with its body. A stateless-era request must repeat its version, its
    /// method and, for a tool call, the tool's name in headers, so a proxy can
    /// route without reading the body. Every MCP header must hold only what a
    /// header value may: visible ASCII, space and tab.
    static func headerMismatch(
        _ request: HTTPRequest, rpc: JSONRPCRequest, modernVersion: String?
    ) -> String? {
        for header in [Header.protocolVersion, Header.method, Header.name] {
            if let value = request.headers[header], !isValidHeaderValue(value) {
                return "\(header) holds characters a header value may not: encode it as \(base64Prefix)…\(base64Suffix)"
            }
        }
        let versionHeader = request.headers[Header.protocolVersion]
        guard let modernVersion else { return nil }
        guard versionHeader == modernVersion else {
            return "MCP-Protocol-Version must be '\(modernVersion)', the version in _meta"
        }
        guard request.headers[Header.method] == rpc.method else {
            return "Mcp-Method must be '\(rpc.method)', the method in the body"
        }
        if rpc.method == "tools/call", let toolName = rpc.params?.getToolName() {
            guard request.headers[Header.name].map(decodedHeaderValue) == toolName else {
                return "Mcp-Name must be '\(toolName)', the tool named in the body"
            }
        }
        return nil
    }

    /// Whether `value` holds only visible ASCII (0x21-0x7E), space and tab,
    /// the characters an HTTP header value may carry. Anything else travels in
    /// the Base64 form.
    static func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar == " " || scalar == "\t" || (0x21...0x7E).contains(scalar.value)
        }
    }

    /// A header value with the Base64 form decoded; any other value unchanged.
    static func decodedHeaderValue(_ value: String) -> String {
        guard value.hasPrefix(base64Prefix), value.hasSuffix(base64Suffix),
              value.count >= base64Prefix.count + base64Suffix.count else { return value }
        let encoded = value.dropFirst(base64Prefix.count).dropLast(base64Suffix.count)
        guard let data = Data(base64Encoded: String(encoded)),
              let decoded = String(data: data, encoding: .utf8) else { return value }
        return decoded
    }

    /// The deepest nesting of `[` and `{` in a JSON text, counted over the raw
    /// bytes so nothing recursive runs on a body before its depth is known.
    /// Brackets inside strings do not count.
    static func nestingDepth(of body: Data) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in body {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
            default:
                break
            }
        }
        return deepest
    }

    /// The HTTP status of a JSON-RPC response: errors a client must tell apart
    /// before parsing the body get their own status, everything else is 200.
    /// A stateless-era request missing a required `_meta` field is malformed,
    /// and one needing a capability the client did not declare cannot run:
    /// the revision makes both 400.
    private static func status(for response: JSONRPCResponse, rpc: JSONRPCRequest, modern: Bool) -> Int {
        guard let code = response.error?.code else { return 200 }
        switch code {
        case MCPServer.unsupportedProtocolVersionCode, MCPServer.missingClientCapabilityCode:
            return 400
        case MCPServer.invalidParamsCode where modern && MCPServer.missingRequiredMetaField(rpc) != nil:
            return 400
        case ErrorCode.methodNotFound where modern:
            return 404
        default:
            return 200
        }
    }

    /// An HTTP error whose body is a JSON-RPC error object.
    private static func rpcError(
        _ status: Int, code: Int, message: String, id: RequestID? = nil
    ) -> HTTPResponse {
        let response = JSONRPCResponse(id: id, result: nil, error: JSONRPCError(code: code, message: message))
        let body = (try? JSONEncoder().encode(response)) ?? Data()
        return .json(status, body)
    }
}
