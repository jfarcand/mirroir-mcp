// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Integration tests that load all real skill files and validate parsing globally.
// ABOUTME: Covers step type coverage, header extraction, env var patterns, and shared skill-file helpers.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SkillFileTests: XCTestCase {

    private static var projectRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TestRunnerTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // project root
            .path
    }

    private static var skillsDir: String {
        projectRoot + "/.mirroir-mcp/skills"
    }

    // MARK: - Global validation

    func testAllSkillFilesParse() throws {
        let stems = skillStems()
        XCTAssertFalse(stems.isEmpty, "No skill files found in \(Self.skillsDir)")

        for stem in stems {
            let skill = try parseSkill(stem)
            XCTAssertFalse(skill.name.isEmpty, "\(stem): empty name")
            // YAML files have parsed steps; .md files have empty steps (natural language)
            if skill.filePath.hasSuffix(".yaml") {
                XCTAssertFalse(skill.steps.isEmpty, "\(stem): no steps")
            } else {
                XCTAssertFalse(skill.description.isEmpty, "\(stem): empty description")
            }
        }
    }

    func testSkillCount() {
        let stems = skillStems()
        XCTAssertEqual(stems.count, 26, "Expected 26 skills, got \(stems.count): \(stems)")
    }

    func testNoUnexpectedUnknownSteps() throws {
        let knownAIOnlyTypes: Set<String> = [
            "remember", "condition", "repeat", "verify", "summarize",
        ]
        let expectedUnknownTypes: Set<String> = []

        let files = yamlFilesSkippingLegacy()
        for file in files {
            let fullPath = Self.skillsDir + "/" + file
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            let skill = SkillParser.parse(content: content, filePath: fullPath)
            for step in skill.steps {
                if case .skipped(let stepType, let reason) = step {
                    let allowed = knownAIOnlyTypes.contains(stepType)
                        || expectedUnknownTypes.contains(stepType)
                    XCTAssertTrue(allowed,
                        "\(file): unexpected unknown step '\(stepType)' (\(reason))")
                }
            }
        }
    }

    // MARK: - Step type coverage across all skills

    func testAllExecutableStepTypesCovered() throws {
        let files = yamlFilesSkippingLegacy()
        var seenTypes: Set<String> = []

        for file in files {
            let fullPath = Self.skillsDir + "/" + file
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            let skill = SkillParser.parse(content: content, filePath: fullPath)
            for step in skill.steps {
                seenTypes.insert(stepKind(step))
            }
        }

        // When no YAML files exist (CI with .md-only), skip step-type coverage
        guard !files.isEmpty else { return }

        // Step types that appear in at least one real skill
        let expectedInSkills: Set<String> = [
            "launch", "tap", "type", "press_key", "swipe",
            "wait_for", "assert_visible", "assert_not_visible",
            "screenshot", "home", "shake", "scroll_to",
            "remember", "condition", "repeat", "long_press",
        ]
        for expected in expectedInSkills {
            XCTAssertTrue(seenTypes.contains(expected),
                "Step type '\(expected)' not found in any skill")
        }

        // These types are only tested synthetically (SkillParserTests),
        // not used in any shipped skill yet:
        // open_url, scroll_to, reset_app, set_network, measure
    }

    // MARK: - Header extraction from real files

    func testAllFilesHaveValidHeaders() throws {
        let stems = skillStems()

        for stem in stems {
            let path = try resolveSkillPath(stem)
            let info = MirroirMCP.extractSkillHeader(
                from: path, source: "local")
            XCTAssertFalse(info.name.isEmpty, "\(stem): empty header name")
        }
    }

    func testAllSkillsHaveDescriptions() throws {
        let stems = skillStems()

        for stem in stems {
            let path = try resolveSkillPath(stem)
            let info = MirroirMCP.extractSkillHeader(
                from: path, source: "local")
            XCTAssertFalse(info.description.isEmpty,
                "\(stem): description parsed as empty")
            XCTAssertFalse(info.description.contains("\n"),
                "\(stem): description should be a single line")
        }
    }

    // MARK: - Env var pattern validation

    func testEnvVarPatternsAreWellFormed() throws {
        let envVarPattern = try NSRegularExpression(pattern: "\\$\\{([^}]+)\\}")
        let stems = skillStems()

        for stem in stems {
            let path = try resolveSkillPath(stem)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let range = NSRange(content.startIndex..., in: content)
            let matches = envVarPattern.matches(in: content, range: range)

            for match in matches {
                let varRange = Range(match.range(at: 1), in: content)!
                let varExpr = String(content[varRange])

                // Format: VAR_NAME or VAR_NAME:-default
                let parts = varExpr.split(separator: ":", maxSplits: 1)
                let varName = String(parts[0])
                XCTAssertTrue(
                    varName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" },
                    "\(stem): env var '\(varName)' contains invalid characters")
                XCTAssertTrue(varName == varName.uppercased(),
                    "\(stem): env var '\(varName)' should be UPPER_SNAKE_CASE")
            }
        }
    }

    func testEnvVarSubstitutionOnRealContent() throws {
        let path = try resolveSkillPath("apps/slack/send-message")
        let content = try String(contentsOfFile: path, encoding: .utf8)

        // Set env vars and verify substitution
        setenv("RECIPIENT", "Alice", 1)
        setenv("MESSAGE", "Hi there!", 1)
        defer {
            unsetenv("RECIPIENT")
            unsetenv("MESSAGE")
        }

        let substituted = MirroirMCP.substituteEnvVars(in: content)
        XCTAssertTrue(substituted.contains("Alice"),
            "RECIPIENT not substituted")
        XCTAssertTrue(substituted.contains("Hi there!"),
            "MESSAGE not substituted")
        XCTAssertFalse(substituted.contains("${RECIPIENT}"),
            "RECIPIENT placeholder still present after substitution")
    }

    func testEnvVarDefaultsApplied() throws {
        let path = try resolveSkillPath("apps/clock/set-alarm")
        let content = try String(contentsOfFile: path, encoding: .utf8)

        // Do NOT set ALARM_LABEL — should fall back to default
        unsetenv("ALARM_LABEL")

        let substituted = MirroirMCP.substituteEnvVars(in: content)
        XCTAssertTrue(substituted.contains("Wake Up"),
            "Default 'Wake Up' not applied when ALARM_LABEL is unset")
    }

    // MARK: - Helpers

    /// Resolve a stem to the first existing file, trying the new `skills/` prefix
    /// first and falling back to the legacy layout.
    private static func resolveStemPath(_ stem: String, extension ext: String) -> String? {
        let candidates = [
            Self.skillsDir + "/skills/" + stem + "." + ext,
            Self.skillsDir + "/" + stem + "." + ext,
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Parse a skill by stem (no extension). Tries .yaml first for full parsing
    /// with steps, then falls back to .md for header-only parsing.
    func parseSkill(_ stem: String) throws -> SkillDefinition {
        if let yamlPath = Self.resolveStemPath(stem, extension: "yaml") {
            let content = try String(contentsOfFile: yamlPath, encoding: .utf8)
            return SkillParser.parse(content: content, filePath: yamlPath)
        }
        guard let mdPath = Self.resolveStemPath(stem, extension: "md") else {
            throw NSError(
                domain: "SkillFileTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Skill not found: \(stem)"])
        }
        let content = try String(contentsOfFile: mdPath, encoding: .utf8)
        let fallbackName = (stem as NSString).lastPathComponent
        let header = SkillMdParser.parseHeader(content: content, fallbackName: fallbackName)
        return SkillDefinition(
            name: header.name,
            description: header.description,
            filePath: mdPath,
            steps: [],
            targets: []
        )
    }

    /// Resolve a skill stem to its actual file path (.yaml preferred, then .md).
    private func resolveSkillPath(_ stem: String) throws -> String {
        if let yamlPath = Self.resolveStemPath(stem, extension: "yaml") { return yamlPath }
        if let mdPath = Self.resolveStemPath(stem, extension: "md") { return mdPath }
        throw NSError(
            domain: "SkillFileTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No .yaml or .md file found for '\(stem)'"])
    }

    /// Return unique skill stems from the skills directory, filtering out legacy/,
    /// dotfile directories (.claude/, .github/), and root-level non-skill .md files.
    /// When both .yaml and .md exist for the same stem, only one entry is returned.
    private func skillStems() -> [String] {
        let allFiles = MirroirMCP.findSkillFiles(in: Self.skillsDir)
        var seenStems = Set<String>()
        var stems: [String] = []

        for relPath in allFiles {
            // Skip legacy directory
            if relPath.hasPrefix("legacy/") { continue }
            // Skip component definitions (loaded by ComponentLoader, not the skill runner)
            if relPath.hasPrefix("components/") { continue }
            // Skip patterns/ (element patterns, recipes, APP.md files — not skills)
            if relPath.hasPrefix("patterns/") { continue }
            // Skip archetypes/ (framework archetype metadata — archetype.md,
            // SKILL.md, and web scenarios consumed by the runner's .mirroir/
            // pipeline, not standalone iPhone skills).
            if relPath.hasPrefix("archetypes/") { continue }
            // Skip APP.md files (they're app patterns, not skills)
            if (relPath as NSString).lastPathComponent.uppercased() == "APP.MD" { continue }
            // Skip dotfile directories (.claude/, .github/)
            let pathComponents = relPath.components(separatedBy: "/")
            if pathComponents.contains(where: { $0.hasPrefix(".") }) { continue }
            // Skip root-level .md files (README.md, CLA.md, etc.)
            if pathComponents.count == 1 && relPath.hasSuffix(".md") { continue }

            let stem = MirroirMCP.skillStem(relPath)
            if seenStems.contains(stem) { continue }
            seenStems.insert(stem)
            stems.append(stem)
        }

        return stems.sorted()
    }

    /// Return .yaml skill files for tests that require parsed steps, excluding
    /// legacy/ and archetypes/ (the latter are framework scenarios driven by the
    /// runner's .mirroir/ pipeline, not standalone iPhone skills).
    private func yamlFilesSkippingLegacy() -> [String] {
        MirroirMCP.findYAMLFiles(in: Self.skillsDir).filter {
            !$0.hasPrefix("legacy/") && !$0.hasPrefix("archetypes/")
        }
    }

    /// Map a SkillStep to its string kind for comparison.
    private func stepKind(_ step: SkillStep) -> String {
        switch step {
        case .launch: return "launch"
        case .tap: return "tap"
        case .type: return "type"
        case .pressKey: return "press_key"
        case .swipe: return "swipe"
        case .waitFor: return "wait_for"
        case .assertVisible: return "assert_visible"
        case .assertNotVisible: return "assert_not_visible"
        case .screenshot: return "screenshot"
        case .home: return "home"
        case .openURL: return "open_url"
        case .shake: return "shake"
        case .scrollTo: return "scroll_to"
        case .resetApp: return "reset_app"
        case .setNetwork: return "set_network"
        case .measure: return "measure"
        case .longPress: return "long_press"
        case .drag: return "drag"
        case .switchTarget: return "target"
        case .skipped(let type, _): return type
        case .invalid(let type, _): return type
        }
    }

    func assertContains(
        _ skill: SkillDefinition, _ kind: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let found = skill.steps.contains { stepKind($0) == kind }
        XCTAssertTrue(found,
            "'\(skill.name)' missing expected step type '\(kind)'",
            file: file, line: line)
    }

    func assertStepKinds(
        _ steps: [SkillStep], _ expected: [String],
        file: String, testFile: StaticString = #filePath, testLine: UInt = #line
    ) {
        XCTAssertEqual(steps.count, expected.count,
            "\(file): step count mismatch", file: testFile, line: testLine)

        for (i, (step, kind)) in zip(steps, expected).enumerated() {
            XCTAssertEqual(stepKind(step), kind,
                "\(file) step \(i): expected '\(kind)' but got '\(stepKind(step))'",
                file: testFile, line: testLine)
        }
    }
}
