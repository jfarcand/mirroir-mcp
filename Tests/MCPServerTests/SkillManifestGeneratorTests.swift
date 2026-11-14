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
// ABOUTME: Unit tests for SkillManifestGenerator: manifest generation and filename sanitization.
// ABOUTME: Verifies markdown index output and edge cases in name-to-filename conversion.

import XCTest
@testable import mirroir_mcp

final class SkillManifestGeneratorTests: XCTestCase {

    // MARK: - Manifest Generation

    func testGenerateManifestWithMultipleSkills() {
        let skills: [(name: String, content: String)] = [
            (name: "general to about", content: "skill1 content"),
            (name: "general to software update", content: "skill2 content"),
            (name: "privacy to location", content: "skill3 content"),
        ]

        let manifest = SkillManifestGenerator.generate(appName: "Settings", skills: skills)

        XCTAssertTrue(manifest.contains("# Settings"), "Should include app name in header")
        XCTAssertTrue(manifest.contains("3 skills"), "Should include skill count")
        XCTAssertTrue(manifest.contains("**general to about**"), "Should list first skill")
        XCTAssertTrue(manifest.contains("`general-to-about.md`"), "Should include sanitized filename")
        XCTAssertTrue(manifest.contains("**privacy to location**"), "Should list third skill")
        XCTAssertTrue(manifest.contains("1. "), "Should be numbered")
        XCTAssertTrue(manifest.contains("3. "), "Should have all numbers")
    }

    func testGenerateManifestWithSingleSkill() {
        let skills: [(name: String, content: String)] = [
            (name: "exploration", content: "content"),
        ]

        let manifest = SkillManifestGenerator.generate(appName: "Maps", skills: skills)

        XCTAssertTrue(manifest.contains("# Maps"))
        XCTAssertTrue(manifest.contains("1 skills"))
        XCTAssertTrue(manifest.contains("**exploration**"))
    }

    func testGenerateManifestWithEmptySkills() {
        let skills: [(name: String, content: String)] = []

        let manifest = SkillManifestGenerator.generate(appName: "App", skills: skills)

        XCTAssertTrue(manifest.contains("# App"))
        XCTAssertTrue(manifest.contains("0 skills"))
    }

    // MARK: - Filename Sanitization

    func testSanitizeSimpleName() {
        let result = SkillManifestGenerator.sanitizeFilename("general to about")
        XCTAssertEqual(result, "general-to-about")
    }

    func testSanitizeNameWithSpecialChars() {
        let result = SkillManifestGenerator.sanitizeFilename("general > about (v2)")
        XCTAssertEqual(result, "general-about-v2")
    }

    func testSanitizeNameWithMultipleSpaces() {
        let result = SkillManifestGenerator.sanitizeFilename("general   to   about")
        XCTAssertEqual(result, "general-to-about")
    }

    func testSanitizeNameAlreadyClean() {
        let result = SkillManifestGenerator.sanitizeFilename("settings-general")
        XCTAssertEqual(result, "settings-general")
    }

    func testSanitizeNameWithLeadingTrailingSpecialChars() {
        let result = SkillManifestGenerator.sanitizeFilename("  hello world  ")
        XCTAssertEqual(result, "hello-world")
    }

    func testSanitizeEmptyName() {
        let result = SkillManifestGenerator.sanitizeFilename("")
        XCTAssertEqual(result, "")
    }

    func testSanitizePreservesNumbers() {
        let result = SkillManifestGenerator.sanitizeFilename("step 1 to step 2")
        XCTAssertEqual(result, "step-1-to-step-2")
    }
}
