// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Checks the Hermes package in plugins/hermes against the rules a portable Agent Plugins loader states, and against the code it is generated from.
// ABOUTME: No Hermes is needed: the skill file must be the generated manual, and the manifests must pin this version.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class HermesPackageTests: XCTestCase {

    private static var package: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugins/hermes")
    }

    private func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.package.appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The server's name in both manifests.
    private let serverName = "mirroir"

    // MARK: - The portable form of the manual

    func testThePortableSkillFileHasOnlyAgentSkillsFrontMatter() {
        let lines = OperatingManual.portableSkillMarkdown.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(6)), [
            "---",
            "name: \(OperatingManual.skillName)",
            "description: \"\(OperatingManual.skillDescription)\"",
            "license: Apache-2.0",
            "compatibility: \"\(OperatingManual.skillCompatibility)\"",
            "---",
        ])
        XCTAssertFalse(lines.contains { $0.hasPrefix("metadata:") || $0.hasPrefix("homepage:") },
                       "nested metadata makes a portable loader skip the skill")
        XCTAssertTrue((1 ... 1024).contains(OperatingManual.skillDescription.count))
        XCTAssertTrue((1 ... 500).contains(OperatingManual.skillCompatibility.count))
    }

    func testBothFormsOfTheSkillFileShareOneBody() {
        func body(_ markdown: String) -> String {
            let parts = markdown.components(separatedBy: "\n---\n")
            return parts.dropFirst().joined(separator: "\n---\n")
        }
        XCTAssertEqual(body(OperatingManual.skillMarkdown), body(OperatingManual.portableSkillMarkdown))
        XCTAssertEqual(body(OperatingManual.skillMarkdown), "\n" + OperatingManual.manualBody)
        XCTAssertTrue(OperatingManual.manualBody.hasPrefix("# Driving an iPhone with mirroir"))
    }

    func testThePortableOptionIsExclusiveOfInstall() {
        XCTAssertNoThrow(try SkillCommand.validate([SkillCommand.portableOption]))
        XCTAssertThrowsError(try SkillCommand.validate([SkillCommand.portableOption, SkillCommand.installOption]))
    }

    // MARK: - The committed package

    /// The committed skill is generated output: `mirroir-mcp skill --portable`.
    func testTheCommittedSkillIsTheGeneratedManual() throws {
        let committed = try String(
            contentsOf: Self.package.appendingPathComponent("skills/\(OperatingManual.skillName)/SKILL.md"),
            encoding: .utf8)
        XCTAssertEqual(committed, OperatingManual.portableSkillMarkdown + "\n",
                       "regenerate with: mirroir-mcp skill --portable > plugins/hermes/skills/mirroir/SKILL.md")
    }

    func testTheSkillDirectoryIsNamedAfterTheSkill() throws {
        let skills = try FileManager.default.contentsOfDirectory(
            atPath: Self.package.appendingPathComponent("skills").path)
        XCTAssertEqual(skills, [OperatingManual.skillName])
        XCTAssertNotNil(OperatingManual.skillName.range(
            of: "^(?!.*--)[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression))
    }

    func testThePluginManifestUsesOnlyPortableFields() throws {
        let manifest = try json("plugin.json")
        let allowed: Set<String> = ["$schema", "name", "version", "description", "author", "homepage",
                                    "repository", "license", "keywords", "extensions"]
        XCTAssertTrue(Set(manifest.keys).isSubset(of: allowed), "\(Set(manifest.keys).subtracting(allowed))")
        XCTAssertEqual(manifest["$schema"] as? String,
                       "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")
        XCTAssertEqual(manifest["name"] as? String, serverName)
        XCTAssertEqual(manifest["version"] as? String, MirroirVersion.current)
        XCTAssertEqual(manifest["license"] as? String, OperatingManual.skillLicense)
        let author = try XCTUnwrap(manifest["author"] as? [String: Any])
        XCTAssertTrue(Set(author.keys).isSubset(of: ["name", "email", "url"]))
    }

    /// Hermes asks the user before a call to a tool of an untrusted server
    /// unless the tool says it is read-only.
    func testTheServerIsDeclaredUntrustedSoActionsAsk() throws {
        let extensions = try XCTUnwrap(try json("plugin.json")["extensions"] as? [String: Any])
        let hermes = try XCTUnwrap(extensions["com.nousresearch.hermes"] as? [String: Any])
        let servers = try XCTUnwrap(hermes["servers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), [serverName])
        XCTAssertEqual((servers[serverName] as? [String: Any])?["trust"] as? String, "untrusted")
        let declared = try XCTUnwrap(try json("mcp.json")["mcpServers"] as? [String: Any])
        XCTAssertNotNil(declared[serverName], "the gated server must be the one the package starts")
    }

    func testTheMCPConfigStartsThePinnedServer() throws {
        let config = try json("mcp.json")
        XCTAssertEqual(Set(config.keys), ["$schema", "mcpServers"])
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers[serverName] as? [String: Any])
        XCTAssertTrue(Set(server.keys).isSubset(of: ["type", "command", "args", "env", "cwd"]))
        XCTAssertEqual(server["type"] as? String, "stdio")
        XCTAssertEqual(server["command"] as? String, "npx")
        XCTAssertEqual(server["args"] as? [String], ["-y", "mirroir-mcp@\(MirroirVersion.current)"])
    }

    /// The property the approval gate rests on: every tool that can change
    /// something says it is not read-only, and every read says it is.
    func testEveryToolSaysWhetherItOnlyReads() {
        for tool in PermissionPolicy.mutatingTools {
            XCTAssertEqual(PermissionPolicy.annotations(for: tool)["readOnlyHint"], .bool(false), tool)
        }
        for tool in PermissionPolicy.readonlyTools {
            XCTAssertEqual(PermissionPolicy.annotations(for: tool)["readOnlyHint"], .bool(true), tool)
        }
    }

    func testTheReadmeStatesWhatThePackageRunsAndFetches() throws {
        let readme = try String(contentsOf: Self.package.appendingPathComponent("README.md"), encoding: .utf8)
        for phrase in ["hermes plugins install jfarcand/mirroir-mcp/plugins/hermes", "npx -y mirroir-mcp@",
                       "SHA-256", "registry.npmjs.org", "updateCheck", "permissions.json"] {
            XCTAssertTrue(readme.contains(phrase), phrase)
        }
    }
}
