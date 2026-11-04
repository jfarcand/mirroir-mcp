// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Ties what the docs and website claim to code facts: the tool count, the tools reference table, the MIRROIR_* variables.
// ABOUTME: Reads the repository's own files; a renamed tool or a dropped variable fails here instead of drifting.

import Foundation
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class DocClaimsTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ relative: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    /// Repository files under `directory` with one of `extensions`, as relative paths.
    private static func files(under directory: String, extensions: Set<String>) -> [String] {
        let base = root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(atPath: base.path) else { return [] }
        return walker.compactMap { $0 as? String }
            .filter { extensions.contains(($0 as NSString).pathExtension) && !$0.contains("node_modules") }
            .map { "\(directory)/\($0)" }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// Pages a reader sees: the README, llms.txt, docs/ and the website.
    private static var publicPages: [String] {
        ["README.md", "llms.txt"] + files(under: "docs", extensions: ["md"])
            + files(under: "website/src", extensions: ["astro", "md", "mdx"])
    }

    /// A count on a line about the read-only allow-list counts that list;
    /// every other count is the whole tool set.
    func testEveryToolCountMatchesTheRegisteredTools() {
        let count = OperatingManualTests.registeredCatalog().count
        XCTAssertGreaterThan(count, 30)
        var claims = 0
        for page in Self.publicPages {
            for line in Self.read(page).components(separatedBy: "\n") {
                let expected = line.contains("readonlyTools") ? PermissionPolicy.readonlyTools.count : count
                for match in Self.matches(#"\b(\d+) (?:MCP )?tools\b"#, in: line) {
                    claims += 1
                    XCTAssertEqual(Int(match[1]), expected, "\(page) claims \(match[0])")
                }
            }
        }
        XCTAssertGreaterThan(claims, 3, "the scan must find the README and site claims")
    }

    func testTheToolsReferenceListsExactlyTheRegisteredTools() {
        let reference = Self.read("docs/tools.md")
        let toolList = reference.components(separatedBy: "\n## ").first { $0.hasPrefix("Tool List") } ?? ""
        let table = Self.matches(#"(?m)^\| `([a-z_]+)` \|"#, in: toolList).map { $0[1] }
        XCTAssertEqual(Set(table).count, table.count, "a tool listed twice")
        XCTAssertEqual(Set(table), Set(OperatingManualTests.registeredCatalog().keys))
    }

    /// Every `MIRROIR_*` variable some code reads: literal names in the Swift
    /// and Rust sources, and the names EnvConfig derives from its settings keys.
    private static var variablesInCode: Set<String> {
        let sources = files(under: "Sources", extensions: ["swift"]) + files(under: "runner/src", extensions: ["rs"])
            + files(under: "npm", extensions: ["js"]) + ["Package.swift", "mirroir.sh", "get-mirroir.sh"]
        var names: Set<String> = []
        for file in sources {
            let text = read(file)
            names.formUnion(matches(#"MIRROIR_[A-Z0-9_]*[A-Z0-9]"#, in: text).map { $0[0] })
            for key in matches(#"read[A-Za-z0-9]*\(\s*"([a-zA-Z0-9]+)""#, in: text).map({ $0[1] }) {
                names.insert(EnvConfig.envVarName(key))
            }
        }
        return names
    }

    func testEveryDocumentedVariableIsReadByCode() {
        let known = Self.variablesInCode
        XCTAssertTrue(known.contains("MIRROIR_OMIT_SCREENSHOT"), "the scan must see EnvConfig")
        for page in Self.publicPages {
            for name in Set(Self.matches(#"MIRROIR_[A-Z0-9_]*[A-Z0-9]"#, in: Self.read(page)).map({ $0[0] })) {
                XCTAssertTrue(known.contains(name), "\(page) names \(name), which no code reads")
            }
        }
    }
}
