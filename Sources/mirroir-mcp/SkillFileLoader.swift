// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Loads a skill file for the CLI runners: a YAML skill from its steps, a SKILL.md from its compiled file.
// ABOUTME: A SKILL.md body is prose for an AI, so its replayable steps are the ones recorded when it was compiled.

import Foundation

/// Why a skill file cannot be loaded for deterministic replay.
enum SkillFileLoaderError: LocalizedError {
    /// A SKILL.md with no `.compiled.json` next to it.
    case notCompiled(path: String)
    /// A SKILL.md whose `.compiled.json` no longer matches it.
    case staleCompiled(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .notCompiled(let path):
            return "\(path) has no compiled file. A SKILL.md is replayed from the steps "
                + "recorded when it ran through an MCP client: run it once with "
                + "get_skill, calling record_step after each step and save_compiled at the end."
        case .staleCompiled(let path, let reason):
            return "\(path): \(reason). Run it again through an MCP client "
                + "(get_skill, record_step, save_compiled) to recompile it."
        }
    }
}

/// Loads skill files into `SkillDefinition`s the CLI runners (`mirroir test`,
/// `mirroir compile`) can execute, choosing the parser by file format.
enum SkillFileLoader {

    /// Load the skill at `filePath`.
    ///
    /// A `.md` skill is a SKILL.md: its header comes from `SkillMdParser` and its
    /// steps from the `.compiled.json` recorded when it was compiled, each rebuilt
    /// from the recorded type and label. A `kind: game` SKILL.md is model-interpreted
    /// and never compiled, so it loads with no steps. Any other file is a YAML skill.
    ///
    /// - Throws: `SkillFileLoaderError` when a SKILL.md has no compiled file, or one
    ///   whose version or source hash no longer matches; file read errors otherwise.
    /// - Parameter substitutingEnv: false keeps `${VAR}` placeholders unresolved, the
    ///   form a compiled label is written in so a secret never lands in a compiled file.
    static func load(filePath: String, substitutingEnv: Bool = true) throws -> SkillDefinition {
        let raw = try String(contentsOfFile: filePath, encoding: .utf8)
        let content = substitutingEnv ? MirroirMCP.substituteEnvVars(in: raw) : raw
        guard filePath.hasSuffix(".md") else {
            return SkillParser.parse(content: content, filePath: filePath)
        }

        let fallbackName = ((filePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let header = SkillMdParser.parseHeader(content: content, fallbackName: fallbackName)
        let kind = SkillParser.headerKind(from: content)
        let targets = SkillParser.parseTargets(from: content)

        let steps: [SkillStep]
        if kind == "game" {
            steps = []
        } else {
            steps = Self.steps(from: try freshCompiled(for: filePath),
                               substitutingEnv: substitutingEnv)
        }

        return SkillDefinition(
            name: header.name,
            description: header.description,
            filePath: filePath,
            steps: steps,
            targets: targets,
            kind: kind
        )
    }

    /// Rebuild the executable steps of a compiled skill, one per compiled step and in
    /// the same order, since replay pairs them by position. A compiled step's label is
    /// the step's replay value, so type and label parse back as `type: label`. A
    /// scroll's direction lives in its hints, which say which way the recorded run went.
    /// A label keeps the skill's `${VAR}` placeholders. They are resolved after parsing,
    /// field by field (the inverse of how save_compiled put them in), so a value holding
    /// quotes or commas stays one value. A target selector resolves as one map.
    static func steps(from compiled: CompiledSkill, substitutingEnv: Bool = true) -> [SkillStep] {
        compiled.steps.map { compiledStep in
            let label = compiledStep.label ?? ""
            let parsed: SkillStep
            if !substitutingEnv {
                parsed = SkillParser.parseStep(key: compiledStep.type, rawValue: label)
            } else if case .switchTarget = SkillParser.parseStep(key: compiledStep.type, rawValue: label) {
                parsed = SkillParser.parseStep(
                    key: compiledStep.type, rawValue: MirroirMCP.substituteEnvVars(in: label))
            } else {
                parsed = SkillParser.parseStep(key: compiledStep.type, rawValue: label)
                    .mappingValues { MirroirMCP.substituteEnvVars(in: $0) }
            }
            let step = parsed
            if case .scrollTo(let label, _, let maxScrolls) = step,
               let direction = compiledStep.hints?.scrollDirection {
                return .scrollTo(label: label, direction: direction, maxScrolls: maxScrolls)
            }
            return step
        }
    }

    /// Whether `filePath` can be replayed by the CLI runners: a YAML skill always, a
    /// SKILL.md when it has a compiled file that still matches it and is not
    /// `kind: game`. Name resolution and discovery skip the others. A step the parser
    /// cannot read does not make a skill unreplayable here: like a YAML skill's, it is
    /// refused by `InvalidStepGate` with its reason rather than silently left out.
    static func isReplayable(filePath: String) -> Bool {
        guard filePath.hasSuffix(".md") else { return true }
        guard let skill = try? load(filePath: filePath) else { return false }
        return skill.kind != "game"
    }

    /// The first step of a loadable SKILL.md that `mirroir test` cannot replay (a tool
    /// with no skill step type, such as `press_back`), as `step N (type): reason`, or
    /// nil. A run that names the skill is refused for it; a run that only picked the
    /// skill up through discovery or a glob skips it with this reason instead, so one
    /// such skill does not stop every other skill in the directory.
    static func unreadableStep(filePath: String) -> String? {
        guard filePath.hasSuffix(".md"), let skill = try? load(filePath: filePath) else {
            return nil
        }
        for (index, step) in skill.steps.enumerated() {
            if let unreadable = InvalidStepGate.unreadable(step) {
                return "step \(index) (\(unreadable.stepType)): \(unreadable.reason)"
            }
        }
        return nil
    }

    /// Whether `filePath` is a SKILL.md with no compiled file at all: not a CLI skill
    /// yet, so in name resolution it neither runs nor hides another skill of its name.
    /// A compiled-but-stale one is a CLI skill whose name stops at its load error.
    static func isNeverCompiledSkillMd(_ filePath: String) -> Bool {
        filePath.hasSuffix(".md")
            && !FileManager.default.fileExists(atPath: CompiledSkillIO.compiledPath(for: filePath))
    }

    /// The copy of a skill the CLI runners run, given its copies in the order MCP
    /// resolution weighs them for the same name (a path weighs .md across directories
    /// first, a basename the nearer directory first): the first one, the file
    /// `get_skill` and `save_compiled` use for that name, when `accept` takes it; else, when `yamlFallback`, the first YAML copy
    /// `accept` takes (copies keep their nearer-directory-first order). Never another
    /// SKILL.md, which would run a different file from the one the AI compiled.
    static func runnerChoice(
        _ copies: [String], accept: (String) -> Bool, yamlFallback: Bool
    ) -> String? {
        guard let first = copies.first else { return nil }
        if accept(first) { return first }
        guard yamlFallback else { return nil }
        return copies.first { $0.hasSuffix(".yaml") && accept($0) }
    }

    /// The compiled skill for a SKILL.md, refusing one that is missing or no
    /// longer matches the source: its steps would replay an older version.
    private static func freshCompiled(for filePath: String) throws -> CompiledSkill {
        guard let compiled = try CompiledSkillIO.load(for: filePath) else {
            throw SkillFileLoaderError.notCompiled(path: filePath)
        }
        if let reason = CompiledSkillIO.sourceStaleness(compiled: compiled, skillPath: filePath) {
            throw SkillFileLoaderError.staleCompiled(path: filePath, reason: reason)
        }
        let negative = CompiledSkillIO.negativeIndices(compiled.steps)
        if !negative.isEmpty {
            throw SkillFileLoaderError.staleCompiled(
                path: filePath,
                reason: "step index \(negative.map(String.init).joined(separator: ", ")) is below 0")
        }
        let missing = CompiledSkillIO.missingIndices(compiled.steps)
        if !missing.isEmpty {
            throw SkillFileLoaderError.staleCompiled(
                path: filePath,
                reason: "no step recorded at index \(CompiledSkillIO.describe(missing))")
        }
        return compiled
    }
}
