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
// ABOUTME: A target that is another Mac's `mirroir-mcp serve` (carnet#102): its phone, driven from here.
// ABOUTME: Tool calls aimed at it are forwarded over HTTP with the bearer token its config names.

import Foundation
import os
import HelperLib

/// Another Mac's `mirroir-mcp serve`, configured in targets.json as
/// `{"type": "mirroir-remote", "url": "http://127.0.0.1:8765/mcp", "token_env": "DOUCHE_TOKEN"}`.
/// The phone paired with that Mac is driven by forwarding each tool call to it; the
/// screen is read there, and the reply comes back as that server wrote it.
struct RemoteTarget: Sendable, Equatable {
    static let configTypeName = "mirroir-remote"

    let name: String
    let url: URL
    /// The environment variable the bearer token is read from at each call, so the
    /// token never sits in targets.json.
    let tokenEnv: String

    /// Hosts plain HTTP is accepted for: this Mac, as an SSH port forward reaches another.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// The remote target `config` describes, or why it is refused.
    static func make(config: TargetConfig, name: String) -> Result<RemoteTarget, RemoteTargetError> {
        guard let raw = config.url, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return .failure(.config("target '\(name)' needs \"url\", the address of the other Mac's mirroir-mcp serve, e.g. http://127.0.0.1:8765/mcp"))
        }
        switch scheme {
        case "https":
            break
        case "http" where loopbackHosts.contains(host):
            break
        case "http":
            return .failure(.config("target '\(name)' sends its token in the clear to \(host). Use https, or reach that Mac through an SSH port forward to 127.0.0.1"))
        default:
            return .failure(.config("target '\(name)' has a \(scheme) url; it must be http to 127.0.0.1 or https"))
        }
        guard let tokenEnv = config.tokenEnv?.trimmingCharacters(in: .whitespaces), !tokenEnv.isEmpty else {
            return .failure(.config("target '\(name)' needs \"token_env\", the environment variable holding that serve's token"))
        }
        return .success(RemoteTarget(name: name, url: url, tokenEnv: tokenEnv))
    }

    /// Tools that stay on this Mac whatever the target: the target list itself, and
    /// tools that only read or write files here.
    static let localTools: Set<String> = PermissionPolicy.closedWorldTools.union(["list_targets", "switch_target"])

    /// The JSON-RPC body that calls `tool` with `arguments` on the remote. Its own
    /// active target answers: `target` names a target here, not there.
    func requestBody(tool: String, arguments: [String: JSONValue], id: Int) -> Data? {
        var forwarded = arguments
        forwarded.removeValue(forKey: "target")
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("tools/call"),
            "params": .object(["name": .string(tool), "arguments": .object(forwarded)]),
        ])
        return try? JSONEncoder().encode(request)
    }
}

/// Why a remote target could not be configured or called.
enum RemoteTargetError: Error, Equatable {
    case config(String)
    case call(String)

    var message: String {
        switch self {
        case .config(let text), .call(let text): return text
        }
    }
}

/// Sends one request to a remote target and waits for its answer.
protocol RemoteTransport: Sendable {
    /// POST `body` to `url` with `token`; the HTTP status and body, or why nothing came back.
    func post(_ body: Data, to url: URL, token: String, timeoutSeconds: Double) -> Result<(status: Int, body: Data), RemoteTargetError>
}

/// The transport over URLSession.
struct URLSessionRemoteTransport: RemoteTransport {
    func post(_ body: Data, to url: URL, token: String, timeoutSeconds: Double) -> Result<(status: Int, body: Data), RemoteTargetError> {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let box = OSAllocatedUnfairLock<Result<(status: Int, body: Data), RemoteTargetError>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let outcome: Result<(status: Int, body: Data), RemoteTargetError>
            if let error {
                outcome = .failure(.call("cannot reach \(url.absoluteString): \(error.localizedDescription). "
                    + "Is mirroir-mcp serve running on that Mac, and its SSH port forward open?"))
            } else {
                outcome = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            box.withLock { $0 = outcome }
            done.signal()
        }
        task.resume()
        done.wait()
        return box.withLock { $0 } ?? .failure(.call("no answer from \(url.absoluteString)"))
    }
}

extension RemoteTarget {
    /// How long one forwarded call may take: a remote screen read or a run of steps is slow.
    static let callTimeoutSeconds: Double = 600

    /// Call `tool` on the remote and return its `result` object, which this server
    /// passes on as is, or why the call failed.
    func call(
        tool: String, arguments: [String: JSONValue],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any RemoteTransport = URLSessionRemoteTransport()
    ) -> Result<[String: JSONValue], RemoteTargetError> {
        guard let token = environment[tokenEnv], !token.isEmpty else {
            return .failure(.call("target '\(name)' reads its token from \(tokenEnv), which is not set "
                + "in this server's environment. Set it to the token of the serve at \(url.absoluteString)."))
        }
        guard let body = requestBody(tool: tool, arguments: arguments, id: 1) else {
            return .failure(.call("the arguments of \(tool) could not be encoded"))
        }
        switch transport.post(body, to: url, token: token, timeoutSeconds: Self.callTimeoutSeconds) {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            return Self.result(status: reply.status, body: reply.body, target: name)
        }
    }

    /// The `result` of a JSON-RPC reply, or why there is none.
    static func result(status: Int, body: Data, target: String) -> Result<[String: JSONValue], RemoteTargetError> {
        let text = String(decoding: body.prefix(500), as: UTF8.self)
        if status == 401 {
            return .failure(.call("target '\(target)' refused the token: \(text)"))
        }
        guard let reply = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .object(let fields) = reply else {
            return .failure(.call("target '\(target)' answered HTTP \(status): \(text)"))
        }
        if case .object(let error)? = fields["error"] {
            let message = error["message"]?.asString() ?? "unknown error"
            return .failure(.call("target '\(target)' refused the call: \(message)"))
        }
        guard case .object(let result)? = fields["result"] else {
            return .failure(.call("target '\(target)' answered HTTP \(status) without a result: \(text)"))
        }
        return .success(result)
    }
}
