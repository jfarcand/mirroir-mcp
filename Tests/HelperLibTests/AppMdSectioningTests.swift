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
