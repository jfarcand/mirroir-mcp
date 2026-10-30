// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Proves generate_skill explore reports a refused APP.md on its early returns too.
// ABOUTME: Covers the playable-game skip and the launch failure, both after the APP.md lookup.

import Foundation
import HelperLib
import XCTest
@testable import mirroir_mcp

final class ExploreRefusalNoteTests: XCTestCase {

    private let policy = PermissionPolicy(skipPermissions: true, config: nil)

    /// A fresh directory holding `apps/<dir>/APP.md` files, removed after the test.
    private func appMdDir(_ files: [String: String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-explore-note-\(UUID().uuidString)")
        for (sub, content) in files {
            let folder = dir.appendingPathComponent(sub)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try content.write(
                to: folder.appendingPathComponent("APP.md"), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func appMd(app: String, frontMatter: String) -> String {
        "---\n\(frontMatter)app: \(app)\n---\n\n# \(app)\n\n## Structure\n\nOne screen.\n"
    }

    private func uniqueApp() -> String {
        let name = "RefusalNote-\(UUID().uuidString)"
        addTeardownBlock { _ = GraphPersistence.delete(bundleID: name) }
        return name
    }

    private func explore(app: String, searchPaths: [String]) -> MCPToolResult {
        let registry = makeTestRegistry(
            bridge: StubBridge(), input: StubInput(), describer: StubDescriber(),
            ocrDescriber: StubDescriber())
        return MirroirMCP.handleExplore(
            args: ["app_name": .string(app)], session: ExplorationSession(),
            registry: registry, server: MCPServer(policy: policy), policy: policy,
            appMdSearchPaths: searchPaths)
    }

    private func text(_ result: MCPToolResult) -> String {
        result.content.compactMap {
            if case .text(let value) = $0 { return value }
            return nil
        }.joined(separator: "\n")
    }

    /// The launch fails (no describable first screen); the error still names
    /// the APP.md the version gate refused.
    func testLaunchFailureCarriesTheRefusedAppMdNote() throws {
        let app = uniqueApp()
        let dir = try appMdDir(["refused": appMd(app: app, frontMatter: "")])

        let result = explore(app: app, searchPaths: [dir.path])

        XCTAssertTrue(result.isError, "an undescribable first screen must abort the explore")
        XCTAssertTrue(text(result).contains("APP.md refused"), text(result))
        XCTAssertTrue(text(result).contains("refused/APP.md: no version: front-matter field"),
                      text(result))
    }

    /// A playable game is skipped before launch; the skip still names the
    /// other APP.md for the app that the version gate refused.
    func testPlayableGameSkipCarriesTheRefusedAppMdNote() throws {
        let app = uniqueApp()
        let dir = try appMdDir([
            "game": appMd(app: app, frontMatter: "version: 1\nplayable: single-control\n"),
            "refused": appMd(app: app, frontMatter: ""),
        ])

        let result = explore(app: app, searchPaths: [dir.path])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(text(result).hasPrefix("Exploration skipped:"), text(result))
        XCTAssertTrue(text(result).contains("\n\n---\nAPP.md refused"), text(result))
    }
}
