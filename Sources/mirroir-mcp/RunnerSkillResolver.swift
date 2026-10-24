// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Resolves a skill name for the CLI runners (`mirroir test`, `mirroir compile`) to the file they can replay.
// ABOUTME: Weighs the same copies as MCP resolution, then says which runs, which cannot, or that the name is ambiguous.

import Foundation

/// What a skill name resolves to for the CLI runners.
enum RunnerSkillResolution: Equatable {
    /// The file to run.
    case run(String)
    /// The file the name means, which cannot run; loading it reports why.
    case unusable(String)
    /// Several different skills share the name.
    case ambiguous([String])
    /// No skill has this name.
    case notFound
}

/// Resolves skill names for the CLI runners over the copies MCP resolution weighs
/// (`MirroirMCP.exactSkillCopies`, `MirroirMCP.basenameSkillGroups`).
///
/// For each skill the runner takes the copy MCP resolution picks, or, when that one
/// cannot run, the nearest YAML copy (`SkillFileLoader.runnerChoice`); a name given with
/// its extension gets no fallback. A skill whose copies are all never-compiled SKILL.md
/// files is not a CLI skill yet and neither runs nor hides another of its name. Any
/// other skill that cannot run is reported, never swapped for a different skill that
/// shares its basename, whose result would be reported as this one's.
enum RunnerSkillResolver {

    static func resolve(
        name: String,
        dirs: [String],
        accept: (String) -> Bool = SkillFileLoader.isReplayable
    ) -> RunnerSkillResolution {
        let yamlFallback = !(name.hasSuffix(".yaml") || name.hasSuffix(".md"))

        let exact = MirroirMCP.exactSkillCopies(name: name, dirs: dirs)
        if let choice = SkillFileLoader.runnerChoice(exact, accept: accept, yamlFallback: yamlFallback) {
            return .run(choice)
        }
        // The file reported is the one MCP resolution picks, never a farther copy.
        if let first = exact.first, !exact.allSatisfy(SkillFileLoader.isNeverCompiledSkillMd) {
            return .unusable(first)
        }

        var runnable: [String] = []
        var blocked: [String] = []
        var counted: [String] = []
        var neverCompiled: [String] = []
        for group in MirroirMCP.basenameSkillGroups(name: name, dirs: dirs, sameExtensionOnly: true) {
            if let choice = SkillFileLoader.runnerChoice(
                group.paths, accept: accept, yamlFallback: yamlFallback) {
                runnable.append(choice)
            } else if let first = group.paths.first,
                      !group.paths.allSatisfy(SkillFileLoader.isNeverCompiledSkillMd) {
                blocked.append(first)
            } else {
                neverCompiled.append(contentsOf: group.paths)
                continue
            }
            counted.append(group.relPath)
        }

        if counted.count > 1 {
            return .ambiguous(counted)
        }
        if let path = runnable.first {
            return .run(path)
        }
        if let path = blocked.first ?? exact.first ?? neverCompiled.first {
            return .unusable(path)
        }
        return .notFound
    }
}
