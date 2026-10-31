// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Builds and writes the compiled skill a passing `mirroir-mcp test --compiled-out` run records.
// ABOUTME: Each step that ran becomes a passthrough step carrying the screen it left, for mirroir-run's drift check.

import Foundation

/// The compiled skill `mirroir-mcp test --compiled-out <path> --compiled-source <file>`
/// writes after its one skill passes: the reference mirroir-run compares later
/// runs' screens against. The source hash is the `--compiled-source` file's — the
/// scenario mirroir-run rendered the skill from — not the rendered skill's.
enum CompiledRunRecord {

    /// The compiled skill for a run of `skill` that produced `result` and left `screens`.
    ///
    /// Every step that passed becomes a passthrough step — the label and type
    /// `mirroir-mcp compile` would record — carrying the settled screen it left
    /// as `arrivalFingerprint`; the start screen is `screenFingerprint`.
    static func compiledSkill(
        skill: SkillDefinition,
        result: ConsoleReporter.SkillResult,
        screens: StepScreens,
        sourceSHA256: String,
        device: DeviceInfo,
        compiledAt: Date
    ) -> CompiledSkill {
        let labelSteps = CompileCommand.labelSteps(for: skill)
        var steps: [CompiledStep] = []
        for (index, stepResult) in result.stepResults.enumerated()
        where stepResult.status == .passed && index < skill.steps.count {
            steps.append(CompiledStep(
                index: index,
                type: skill.steps[index].typeKey,
                label: CompileCommand.compiledLabel(labelSteps[index]),
                hints: .passthrough(arrival: screens.afterStep[index])))
        }
        return CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(
                sha256: sourceSHA256,
                compiledAt: ISO8601DateFormatter().string(from: compiledAt)),
            device: device,
            steps: steps,
            screenFingerprint: screens.start)
    }

    /// Write the compiled skill of a passing run to `outputPath`, hashing `sourcePath`.
    ///
    /// - Throws: `CompiledRunRecordError.runFailed` for a run that did not pass
    ///   (nothing is written), `.noWindow` when the run's window was not read,
    ///   `.startScreenUnread` / `.stepScreenUnread` when a screen the reference
    ///   must hold was not read — a reference with a hole would leave that
    ///   screen uncompared on every later run — or the error reading the
    ///   source or writing the file.
    static func write(
        skill: SkillDefinition,
        result: ConsoleReporter.SkillResult,
        screens: StepScreens,
        device: DeviceInfo?,
        sourcePath: String,
        outputPath: String,
        compiledAt: Date = Date()
    ) throws {
        guard result.passed else { throw CompiledRunRecordError.runFailed(skill: skill.name) }
        guard let device else { throw CompiledRunRecordError.noWindow }
        guard screens.start != nil else { throw CompiledRunRecordError.startScreenUnread }
        for (index, stepResult) in result.stepResults.enumerated()
        where stepResult.status == .passed && screens.afterStep[index] == nil {
            throw CompiledRunRecordError.stepScreenUnread(index: index)
        }
        let compiled = compiledSkill(
            skill: skill, result: result, screens: screens,
            sourceSHA256: try CompiledSkillIO.sha256(of: sourcePath),
            device: device, compiledAt: compiledAt)
        try CompiledSkillIO.save(compiled, toPath: outputPath)
    }
}

/// Why `--compiled-out` wrote no compiled skill.
enum CompiledRunRecordError: LocalizedError, Equatable {
    case runFailed(skill: String)
    case noWindow
    case startScreenUnread
    case stepScreenUnread(index: Int)

    var errorDescription: String? {
        switch self {
        case .runFailed(let skill):
            return "\(skill) did not pass, so no compiled skill was recorded"
        case .noWindow:
            return "the iPhone Mirroring window could not be read, so the compiled skill "
                + "has no device to record"
        case .startScreenUnread:
            return "the screen before step 0 could not be read, so the compiled skill "
                + "would have no start screen to compare later runs against"
        case .stepScreenUnread(let index):
            return "the screen step \(index) left could not be read, so the compiled skill "
                + "would have no screen to compare that step against"
        }
    }
}
