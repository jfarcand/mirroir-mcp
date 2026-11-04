// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the agent operating manual: served in initialize, printable as a SKILL.md, and naming only real tools.
// ABOUTME: The tool catalog comes from registering every tool on a server, so a renamed tool fails here.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class OperatingManualTests: XCTestCase {

    /// Every registered tool, with the names of its parameters.
    static func registeredCatalog() -> [String: Set<String>] {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        MirroirMCP.registerTools(
            server: server, registry: makeTestRegistry(bridge: StubBridge(), input: StubInput()),
            policy: PermissionPolicy(skipPermissions: true, config: nil))
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "tools/list", params: nil)
        guard case .object(let result)? = server.handleRequest(request)?.result,
              case .array(let tools)? = result["tools"] else { return [:] }
        var catalog: [String: Set<String>] = [:]
        for case .object(let tool) in tools {
            guard case .string(let name)? = tool["name"] else { continue }
            var parameters: Set<String> = []
            if case .object(let schema)? = tool["inputSchema"],
               case .object(let properties)? = schema["properties"] {
                parameters = Set(properties.keys)
            }
            catalog[name] = parameters
        }
        return catalog
    }

    /// The identifiers a text names as code: the leading word of each backtick
    /// span when it contains an underscore or is called like `tap(`.
    static func codeIdentifiers(in text: String) -> Set<String> {
        var names: Set<String> = []
        for span in text.components(separatedBy: "`").enumerated() where span.offset % 2 == 1 {
            let word = span.element.prefix { $0.isLetter || $0 == "_" }
            let rest = span.element.dropFirst(word.count)
            guard !word.isEmpty, word.contains("_") || rest.hasPrefix("(") else { continue }
            names.insert(String(word))
        }
        return names
    }

    func testInitializeCarriesTheEssentials() {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "initialize",
                                     params: .object([:]))
        guard case .object(let result)? = server.handleRequest(request)?.result else {
            return XCTFail("no initialize result")
        }
        XCTAssertEqual(result["instructions"], .string(OperatingManual.essentials))
    }

    func testTheSkillFileHasFrontMatterAHostCanParse() {
        let lines = OperatingManual.skillMarkdown.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "---")
        XCTAssertEqual(lines[1], "name: \(OperatingManual.skillName)")
        XCTAssertEqual(lines[2], "description: \"\(OperatingManual.skillDescription)\"")
        XCTAssertFalse(OperatingManual.skillDescription.contains("\""),
                       "a quote would end the YAML string early")
        XCTAssertEqual(lines[3], "---")
    }

    func testTheManualNamesOnlyRealToolsAndParameters() {
        let catalog = Self.registeredCatalog()
        XCTAssertGreaterThan(catalog.count, 30, "the catalog must hold the registered tools")
        let known = Set(catalog.keys).union(catalog.values.flatMap { $0 })
        let named = Self.codeIdentifiers(in: OperatingManual.skillMarkdown)
            .union(Self.codeIdentifiers(in: OperatingManual.essentials))
        XCTAssertTrue(named.contains("run_steps"), "the scan must see the tools the manual names")
        XCTAssertEqual(named.subtracting(known), [], "named in the manual but not a tool or parameter")
    }

    func testTheEssentialsNameTheirToolsAsTools() {
        let catalog = Self.registeredCatalog()
        for tool in ["describe_screen", "launch_app", "press_back", "press_home", "run_steps"] {
            XCTAssertNotNil(catalog[tool], tool)
            XCTAssertTrue(OperatingManual.essentials.contains(tool), tool)
        }
    }

    func testInstallGoesToClaudeAndCodexSkillDirectories() {
        XCTAssertEqual(SkillCommand.installDirectories(environment: ["HOME": "/Users/a"]), [
            "/Users/a/.claude/skills/mirroir", "/Users/a/.codex/skills/mirroir",
        ])
        XCTAssertEqual(
            SkillCommand.installDirectories(environment: ["HOME": "/Users/a", "CODEX_HOME": "/opt/codex"])
                .last, "/opt/codex/skills/mirroir")
    }
}
