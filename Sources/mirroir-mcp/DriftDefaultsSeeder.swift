// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Seeds a consumer's .mirroir/drift-defaults.yaml from the mirroir-skills checkout's copy.
// ABOUTME: Never overwrites an existing file and never invents thresholds: no skills copy is an error.

import Foundation
import HelperLib

/// The global drift-threshold layer `mirroir-run` requires to exist (it
/// refuses a run that finds no `drift-defaults.yaml`). An emitted `.mirroir/`
/// tree carries its own copy, taken byte for byte from the mirroir-skills
/// checkout, so the consumer repo replays without depending on where the
/// runner happens to be invoked from. The thresholds live only in that skills
/// file; this type copies it and holds no values of its own.
enum DriftDefaultsSeeder {

    /// The file name at every layer of the runner's search, and in the skills repo.
    static let fileName = "drift-defaults.yaml"

    /// What seeding the tree will do, decided before anything is written.
    enum Plan: Equatable {
        /// The tree already has its own layer; it is kept as is.
        case keep(target: URL)
        /// The tree has no layer; `source` is copied to `target`.
        case copy(source: URL, target: URL)
    }

    /// Candidate skills-repo copies, in the order the rest of mirroir-mcp
    /// resolves the skills checkout: the project-local then global skill
    /// directories, then a `mirroir-skills` sibling of the working directory.
    static func candidatePaths() -> [String] {
        let cwd = FileManager.default.currentDirectoryPath
        return (PermissionPolicy.skillDirs + [cwd + "/../mirroir-skills"])
            .map { $0 + "/" + fileName }
    }

    /// Decide how `mirroirRoot` gets its layer: keep an existing file, or copy
    /// the first candidate that exists.
    ///
    /// - Throws: `MirroirAppTreeEmitter.EmitError.driftDefaultsMissing` naming
    ///   every candidate when the tree has no layer and no candidate exists.
    static func plan(mirroirRoot: URL, candidates: [String]) throws -> Plan {
        let fm = FileManager.default
        let target = mirroirRoot.appendingPathComponent(fileName)
        if fm.fileExists(atPath: target.path) {
            return .keep(target: target)
        }
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            throw MirroirAppTreeEmitter.EmitError.driftDefaultsMissing(searched: candidates)
        }
        return .copy(source: URL(fileURLWithPath: source), target: target)
    }

    /// Carry out `plan` and describe what happened, for the emit's result text.
    ///
    /// - Throws: a file-system error when the copy cannot be read or written.
    static func apply(_ plan: Plan) throws -> String {
        switch plan {
        case .keep(let target):
            return "kept existing \(target.lastPathComponent)"
        case .copy(let source, let target):
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: source).write(to: target, options: .withoutOverwriting)
            return "created \(target.lastPathComponent) from \(source.path)"
        }
    }
}
