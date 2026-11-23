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
// ABOUTME: CLI command that serves the MCP tools over HTTP on loopback, for an agent that reaches this Mac through a tunnel.
// ABOUTME: Same server, same permission policy and same one-call-at-a-time order as stdio; a bearer token is mandatory.

import Darwin
import Foundation
import HelperLib

/// Configuration parsed from `serve` arguments.
struct ServeConfig: Equatable {
    let port: UInt16
    let tokenFile: String
    let allowedOrigins: Set<String>
}

/// A `serve` command line refused for a reason no other command has.
enum ServeArgumentError: LocalizedError, Equatable {
    case skipPermissionsRefused(String)

    var errorDescription: String? {
        switch self {
        case .skipPermissionsRefused(let option):
            return "'\(option)' is not accepted by serve: over HTTP, tools are opened only by "
                + "listing them in permissions.json"
        }
    }
}

/// Runs the MCP server behind an HTTP endpoint on `127.0.0.1`.
///
/// Usage: `mirroir-mcp serve [--port N] [--token-file PATH] [--allow-origin ORIGIN]...`
enum ServeCommand {

    /// The word after `mirroir-mcp`.
    static let commandName = "serve"

    /// The port used when `--port` is not given.
    static let defaultPort: UInt16 = 8765

    /// Exit status when a listener that had started stops serving. Not 0, so
    /// the LaunchAgent's `KeepAlive` starts the server again.
    static let listenerFailureExitCode: Int32 = 1

    static var usage: String {
        """
        Usage: mirroir-mcp serve [options]

        Serves the MCP tools over HTTP at http://127.0.0.1:<port>\(MCPHTTPEndpoint.path), for an
        agent on another machine that reaches this Mac through an SSH port forward.
        It listens on loopback only and requires a bearer token on every request.
        Run it inside your login session: `mirroir-mcp install-agent` sets that up.

        Options:
          --port <n>              Port to listen on (default: \(defaultPort))
          --token-file <path>     File holding the bearer token
                                  (default: \(ServeToken.defaultPath))
          --allow-origin <origin> Accept requests whose Origin header is this value.
                                  Repeatable. By default every Origin is refused.
          --help, -h              Show this help

        Tools are limited by permissions.json, read as the stdio server reads it:
        ./.mirroir-mcp/ first, then \(PermissionPolicy.globalConfigDir)/.
        """
    }

    /// Parse a `serve` command line.
    ///
    /// - Throws: `CLIArgumentError` for an unknown option or a missing or bad
    ///   value; `ServeArgumentError` for an attempt to skip permissions.
    static func parseArguments(_ args: [String]) throws -> ServeConfig {
        var port = defaultPort
        var tokenFile = ServeToken.defaultPath
        var allowedOrigins: Set<String> = []

        var i = 0
        func value(for flag: String) throws -> String {
            i += 1
            guard i < args.count, !args[i].hasPrefix("-") else {
                throw CLIArgumentError.missingValue(flag: flag)
            }
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--port":
                port = try parsePort(try value(for: arg), flag: arg)
            case "--token-file":
                tokenFile = (try value(for: arg) as NSString).expandingTildeInPath
            case "--allow-origin":
                allowedOrigins.insert(try value(for: arg))
            case _ where PermissionPolicy.skipPermissionsOptions.contains(arg):
                throw ServeArgumentError.skipPermissionsRefused(arg)
            default:
                throw CLIArguments.unrecognized(arg, command: commandName)
            }
            i += 1
        }
        return ServeConfig(port: port, tokenFile: tokenFile, allowedOrigins: allowedOrigins)
    }

    /// A port number from a command line: 1 to 65535.
    ///
    /// - Throws: `CLIArgumentError.invalidValue` for anything else.
    static func parsePort(_ raw: String, flag: String) throws -> UInt16 {
        guard let port = UInt16(raw), port > 0 else {
            throw CLIArgumentError.invalidValue(
                flag: flag, value: raw, expected: "a port number from 1 to 65535")
        }
        return port
    }

    /// Start the server and serve until the process is told to stop. Returns
    /// only when it could not start: 1 for a token file or a port it cannot
    /// use, 2 for refused arguments.
    static func run(arguments: [String]) -> Int32 {
        let config: ServeConfig
        let token: String
        do {
            config = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }
        do {
            token = try ServeToken.load(path: config.tokenFile)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }

        let server = MirroirMCP.startServer(skipPermissions: false, transport: .http)
        let mainThread = SerialJobLoop()
        let endpoint = MCPHTTPEndpoint.Config(token: token, allowedOrigins: config.allowedOrigins)
        // A listener that stops serving leaves a process nobody can reach.
        // Exiting lets launchd start a fresh one, and releases held input on the way out.
        let listener = NetworkHTTPServer(port: config.port) { reason in
            DebugLog.persist("serve", "the listener stopped serving (\(reason)); exiting")
            Darwin.exit(listenerFailureExitCode)
        }
        do {
            try listener.start(responder: responder(for: server, endpoint: endpoint, on: mainThread))
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }
        // The token itself is never printed or logged; only where it lives.
        DebugLog.persist("serve", "mirroir-mcp serve: listening on "
            + "http://\(NetworkHTTPServer.loopbackHost):\(listener.boundPort ?? config.port)"
            + "\(MCPHTTPEndpoint.path) (token file \(config.tokenFile))")
        mainThread.run()
    }

    /// How `serve` answers. Headers are judged on the network's threads before
    /// a body is read. A request that passes waits its turn on `loop`'s
    /// thread: one tool call at a time, in arrival order, as on stdio. A call
    /// whose client has gone by the time its turn comes is not run: the screen
    /// it was meant for is no longer the screen showing. A client that leaves
    /// while its call runs cancels it, and the tool stops at its next check.
    static func responder(
        for server: MCPServer, endpoint: MCPHTTPEndpoint.Config, on loop: SerialJobLoop
    ) -> HTTPResponder {
        HTTPResponder(
            refuse: { MCPHTTPEndpoint.refusalBeforeBody($0, config: endpoint) },
            respond: { request, channel in
                MCPHTTPEndpoint.respond(to: request, config: endpoint, channel: channel) { rpc, call in
                    loop.perform { call.isCancelled ? nil : server.handleRequest(rpc, call: call) }
                }
            })
    }
}
