// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decides whether a Markdown or YAML file in a skills directory is a skill.
// ABOUTME: A skill names its name and app; documents, APP.md files and pattern data do not.

import Foundation

/// Tells a skill apart from the other files a skills directory holds (READMEs,
/// `APP.md` app descriptions, element and screen patterns, archetype stubs).
/// The rule is the skill format's own required fields (docs/skills-marketplace.md):
/// a SKILL.md opens with front matter naming `name` and `app`; a YAML skill names
/// `name` and `app` and holds at least one step.
enum SkillFileClassifier {
    /// Who a skill is: the same name and app in two files is one skill in two formats.
    struct Identity: Hashable {
        let name: String
        let app: String
    }

    /// Front-matter delimiter a SKILL.md opens with.
    static let frontMatterDelimiter = "---"

    /// The skill's identity, or nil when `content` is not a skill.
    static func identity(content: String, isMarkdown: Bool) -> Identity? {
        isMarkdown ? markdownIdentity(content: content) : yamlIdentity(content: content)
    }

    /// A SKILL.md's first non-blank line opens its front matter, which names both
    /// `name` and `app`. A `---` rule further down a document is not front matter.
    private static func markdownIdentity(content: String) -> Identity? {
        let firstLine = content.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard firstLine?.trimmingCharacters(in: .whitespaces) == frontMatterDelimiter else {
            return nil
        }
        return named(in: SkillMdParser.extractFrontMatter(content: content))
    }

    /// Top-level key that opens a YAML skill's step list.
    static let yamlStepsKey = "steps:"

    /// A YAML skill names `name` and `app` in its header, the lines before its
    /// step list, and lists at least one step; a scenario or a config file in the
    /// same tree names no app. A `name:` inside a step is not the skill's.
    private static func yamlIdentity(content: String) -> Identity? {
        guard !SkillParser.parseSteps(from: content).isEmpty else { return nil }
        let header = content.components(separatedBy: .newlines)
            .prefix { !$0.hasPrefix(yamlStepsKey) }
            .joined(separator: "\n")
        return named(in: header)
    }

    private static func named(in header: String) -> Identity? {
        guard let name = SkillMdParser.extractStringValue(from: header, key: "name"),
              let app = SkillMdParser.extractStringValue(from: header, key: "app") else {
            return nil
        }
        return Identity(name: name, app: app)
    }
}
