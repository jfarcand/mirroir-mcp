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
// ABOUTME: Tests for remote targets (carnet#102): another Mac's serve, reached by forwarding tool calls.
// ABOUTME: Covers config validation, which calls are routed there, the request sent and the reply read.

import Foundation
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class RemoteTargetTests: XCTestCase {

    private func config(url: String?, tokenEnv: String? = "XR_TOKEN") -> TargetConfig {
        TargetConfig(type: RemoteTarget.configTypeName, bundleID: nil, processName: nil,
                     windowTitleContains: nil, url: url, tokenEnv: tokenEnv)
    }

    private func remote(_ name: String = "xr") -> RemoteTarget {
        guard case .success(let target) = RemoteTarget.make(
            config: config(url: "http://127.0.0.1:7457/mcp"), name: name) else {
            fatalError("a loopback URL is accepted")
        }
        return target
    }

    // MARK: - Configuration

    func testPlainHTTPIsAcceptedOnlyToThisMac() {
        XCTAssertNotNil(try? RemoteTarget.make(config: config(url: "http://127.0.0.1:7457/mcp"), name: "a").get())
        XCTAssertNotNil(try? RemoteTarget.make(config: config(url: "http://localhost:7457/mcp"), name: "a").get())
        XCTAssertNotNil(try? RemoteTarget.make(config: config(url: "https://douche.example/mcp"), name: "a").get())
        guard case .failure(let error) = RemoteTarget.make(
            config: config(url: "http://douche.example:7457/mcp"), name: "xr") else {
            return XCTFail("a token sent in the clear off this Mac must be refused")
        }
        XCTAssertTrue(error.message.contains("in the clear to douche.example"), error.message)
    }

    func testAURLAndATokenVariableAreRequired() {
        guard case .failure(let noURL) = RemoteTarget.make(config: config(url: nil), name: "xr"),
              case .failure(let noToken) = RemoteTarget.make(
                config: config(url: "http://127.0.0.1:7457/mcp", tokenEnv: " "), name: "xr") else {
            return XCTFail("both are required")
        }
        XCTAssertTrue(noURL.message.contains("needs \"url\""), noURL.message)
        XCTAssertTrue(noToken.message.contains("needs \"token_env\""), noToken.message)
    }

    func testTargetsJSONDecodesARemoteEntry() throws {
        let json = #"{"targets": {"xr": {"type": "mirroir-remote", "url": "http://127.0.0.1:7457/mcp", "token_env": "XR_TOKEN"}}}"#
        let file = try JSONDecoder().decode(TargetsFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.targets["xr"]?.url, "http://127.0.0.1:7457/mcp")
        XCTAssertEqual(file.targets["xr"]?.tokenEnv, "XR_TOKEN")
    }

    // MARK: - Routing

    private func registry() -> TargetRegistry {
        let ctx = TargetContext(name: "iphone", targetType: "iphone-mirroring", bundleID: nil,
                                bridge: StubBridge(), input: StubInput(), capture: StubCapture(),
                                describer: StubDescriber(), recorder: StubRecorder())
        return TargetRegistry(targets: ["iphone": ctx], defaultName: "iphone", remotes: ["xr": remote()])
    }

    func testACallGoesToTheRemoteItNamesOrTheActiveOne() {
        let registry = registry()
        XCTAssertNil(registry.remoteTarget(tool: "tap", arguments: [:]), "the local iPhone is active")
        XCTAssertEqual(registry.remoteTarget(tool: "tap", arguments: ["target": .string("xr")])?.name, "xr")
        XCTAssertNil(registry.remoteTarget(tool: "tap", arguments: ["target": .string("iphone")]))

        XCTAssertTrue(registry.switchActive(to: "xr"))
        XCTAssertEqual(registry.remoteTarget(tool: "describe_screen", arguments: [:])?.name, "xr")
        XCTAssertEqual(registry.activeTargetName, "iphone", "local tools keep the local target")
        XCTAssertNil(registry.remoteTarget(tool: "tap", arguments: ["target": .string("iphone")]))

        XCTAssertTrue(registry.switchActive(to: "iphone"))
        XCTAssertNil(registry.remoteTarget(tool: "tap", arguments: [:]))
    }

    func testTargetListsAndFilesStayOnThisMac() {
        let registry = registry()
        _ = registry.switchActive(to: "xr")
        for tool in ["list_targets", "switch_target", "list_skills", "get_skill", "get_notes", "save_note"] {
            XCTAssertNil(registry.remoteTarget(tool: tool, arguments: [:]), tool)
        }
        XCTAssertEqual(registry.allTargetNames, ["iphone", "xr"])
    }

    // MARK: - The call

    private final class RecordingTransport: RemoteTransport, @unchecked Sendable {
        var reply: Result<(status: Int, body: Data), RemoteTargetError>
        var sent: [(body: Data, url: URL, token: String)] = []
        init(_ reply: Result<(status: Int, body: Data), RemoteTargetError>) { self.reply = reply }
        func post(_ body: Data, to url: URL, token: String, timeoutSeconds: Double)
            -> Result<(status: Int, body: Data), RemoteTargetError> {
            sent.append((body, url, token))
            return reply
        }
    }

    func testTheCallCarriesTheTokenAndDropsTheLocalTargetName() throws {
        let transport = RecordingTransport(.success((200, Data(
            #"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Tapped at (10, 20)"}],"isError":false}}"#.utf8))))
        let result = remote().call(tool: "tap",
                                   arguments: ["x": .number(10), "y": .number(20), "target": .string("xr")],
                                   environment: ["XR_TOKEN": "secret"], transport: transport)

        XCTAssertEqual(try result.get()["isError"], .bool(false))
        XCTAssertEqual(transport.sent.first?.token, "secret")
        XCTAssertEqual(transport.sent.first?.url.absoluteString, "http://127.0.0.1:7457/mcp")
        let sent = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(transport.sent.first?.body))
        guard case .object(let body) = sent, case .object(let params)? = body["params"],
              case .object(let arguments)? = params["arguments"] else { return XCTFail("\(sent)") }
        XCTAssertEqual(body["method"], .string("tools/call"))
        XCTAssertEqual(params["name"], .string("tap"))
        XCTAssertNil(arguments["target"], "the remote answers for its own active target")
        XCTAssertEqual(arguments["x"], .number(10))
    }

    func testAMissingTokenVariableSendsNothing() {
        let transport = RecordingTransport(.success((200, Data())))
        let result = remote().call(tool: "tap", arguments: [:], environment: [:], transport: transport)
        guard case .failure(let error) = result else { return XCTFail("no token, no call") }
        XCTAssertTrue(error.message.contains("XR_TOKEN, which is not set"), error.message)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testRefusalsAreNamed() {
        let unauthorized = RemoteTarget.result(status: 401, body: Data("Send the header".utf8), target: "xr")
        let rpcError = RemoteTarget.result(status: 200, body: Data(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Unknown tool: tapp"}}"#.utf8), target: "xr")
        let notJSON = RemoteTarget.result(status: 502, body: Data("Bad Gateway".utf8), target: "xr")
        XCTAssertEqual(unauthorized, .failure(.call("target 'xr' refused the token: Send the header")))
        XCTAssertEqual(rpcError, .failure(.call("target 'xr' refused the call: Unknown tool: tapp")))
        XCTAssertEqual(notJSON, .failure(.call("target 'xr' answered HTTP 502: Bad Gateway")))
    }
}
