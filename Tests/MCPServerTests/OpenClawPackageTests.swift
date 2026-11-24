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
// ABOUTME: Checks the OpenClaw package in plugins/openclaw against the code it mirrors: read-only tools, the skill and the version pins.
// ABOUTME: No OpenClaw is needed: the approval gate's own behaviour is tested by `node --test` in that directory.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class OpenClawPackageTests: XCTestCase {

    private static var package: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugins/openclaw")
    }

    private func json(_ name: String) throws -> Any {
        let data = try Data(contentsOf: Self.package.appendingPathComponent(name))
        return try JSONSerialization.jsonObject(with: data)
    }

    /// The gate lets a tool through without a prompt only when the server says it only reads,
    /// so the list it reads must be the server's own.
    func testTheGateReadsTheServersReadOnlyTools() throws {
        let listed = try XCTUnwrap(try json("read-only-tools.json") as? [String])
        XCTAssertEqual(listed, PermissionPolicy.readonlyTools.sorted(),
                       "regenerate plugins/openclaw/read-only-tools.json from PermissionPolicy.readonlyTools")
    }

    /// The committed skill is generated output: `mirroir-mcp skill --portable`.
    func testTheCommittedSkillIsTheGeneratedManual() throws {
        let committed = try String(
            contentsOf: Self.package.appendingPathComponent("skills/\(OperatingManual.skillName)/SKILL.md"),
            encoding: .utf8)
        XCTAssertEqual(committed, OperatingManual.portableSkillMarkdown + "\n",
                       "regenerate with: mirroir-mcp skill --portable > plugins/openclaw/skills/mirroir/SKILL.md")
    }

    func testTheManifestStartsThePinnedServerTheGateWatches() throws {
        let manifest = try XCTUnwrap(try json("openclaw.plugin.json") as? [String: Any])
        XCTAssertEqual(manifest["id"] as? String, "mirroir")
        XCTAssertEqual(manifest["version"] as? String, MirroirVersion.current)
        XCTAssertEqual(manifest["skills"] as? [String], ["skills/\(OperatingManual.skillName)"])
        XCTAssertNotNil(manifest["configSchema"] as? [String: Any], "OpenClaw requires a configSchema")
        let servers = try XCTUnwrap(manifest["mcpServers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["mirroir"], "approval.js gates the tools of the server named mirroir")
        let server = try XCTUnwrap(servers["mirroir"] as? [String: Any])
        XCTAssertEqual(server["transport"] as? String, "stdio")
        XCTAssertEqual(server["command"] as? String, "npx")
        XCTAssertEqual(server["args"] as? [String], ["-y", "mirroir-mcp@\(MirroirVersion.current)"])
        // OpenClaw's defaults are 30s to start and 60s per call. A first npx run downloads the
        // package and the binary and missed the 30s on a Gateway, and one screen read took 47s.
        XCTAssertGreaterThanOrEqual(server["connectionTimeoutMs"] as? Int ?? 0, 180_000)
        XCTAssertGreaterThanOrEqual(server["requestTimeoutMs"] as? Int ?? 0, 600_000)
    }

    func testThePackageVersionAndEntryMatch() throws {
        let package = try XCTUnwrap(try json("package.json") as? [String: Any])
        XCTAssertEqual(package["version"] as? String, MirroirVersion.current)
        XCTAssertEqual(package["type"] as? String, "module")
        let openclaw = try XCTUnwrap(package["openclaw"] as? [String: Any])
        XCTAssertEqual(openclaw["extensions"] as? [String], ["./index.js"])
        let files = try XCTUnwrap(package["files"] as? [String])
        for name in ["index.js", "approval.js", "read-only-tools.json", "openclaw.plugin.json", "skills"] {
            XCTAssertTrue(files.contains(name), "\(name) must ship in the package")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Self.package.appendingPathComponent(name).path), name)
        }
    }
}
