// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AppMdSectioning's front-matter reader — YAML comment rules on APP.md values.
// ABOUTME: Comment lines are dropped and an inline ` #` ends a value, except inside quotes or a word.

import XCTest
@testable import HelperLib

final class AppMdSectioningTests: XCTestCase {

    private func frontMatter(_ lines: String) -> [String: String] {
        AppMdSectioning.extract(content: "---\n\(lines)\n---\n\n## Structure\n\nBody.").frontMatter
    }

    /// The front-matter lines exactly as docs/APP.md.spec.md shows them.
    func testTheSpecExampleReadsWithoutItsComments() {
        let fields = frontMatter("""
        # Front matter (YAML-ish, flat key:value)
        app: AppName           # required
        version: 1             # required — schema major; a different major is refused
        obstacle_mode: auto    # optional — auto | hint | off
        """)
        XCTAssertEqual(fields, ["app": "AppName", "version": "1", "obstacle_mode": "auto"])
    }

    func testAHashInsideAWordIsPartOfTheValue() {
        XCTAssertEqual(frontMatter("app: C#Notes")["app"], "C#Notes")
    }

    func testAHashInsideQuotesIsPartOfTheValue() {
        XCTAssertEqual(frontMatter("version: \"1.2\"  # minor")["version"], "\"1.2\"")
        XCTAssertEqual(frontMatter("app: 'Notes #1'")["app"], "'Notes #1'")
        XCTAssertEqual(frontMatter("app: \"Notes #1\" # quoted")["app"], "\"Notes #1\"")
    }

    func testAValueThatIsOnlyACommentIsEmpty() {
        XCTAssertEqual(frontMatter("locale: # none")["locale"], "")
    }
}
