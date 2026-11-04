// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds the kind:game skill a scene: step names, and refuses a run whose scenes cannot play as written.
// ABOUTME: Checked before any step runs, like DestructiveStepGate: a scene refused midway would leave a match half-played.

import Foundation
import HelperLib

/// Why a scene step's skill cannot be played.
enum SceneSkillError: LocalizedError, Equatable {
    case notFound(name: String)
    case ambiguous(name: String, paths: [String])
    case notAGame(path: String)
    case unreadable(path: String)
    case header(path: String, SceneHeaderError)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "no kind:game skill named '\(name)' in \(PermissionPolicy.skillsCheckoutVariable) "
                + "or the skill directories"
        case .ambiguous(let name, let paths):
            return "several skills are named '\(name)': \(paths.joined(separator: ", "))"
        case .notAGame(let path):
            return "\(path) is not a kind:game skill"
        case .unreadable(let path):
            return "\(path) cannot be read"
        case .header(let path, let error):
            return "\(path): \(error.localizedDescription)"
        }
    }
}

/// Resolves a scene step's skill name to its parsed header.
enum SceneSkills {

    /// The scene skill `name` names, searched in the skills checkouts first
    /// (`$MIRROIR_SKILLS`, which `mirroir-run` sets on the spawned `mirroir-mcp test`
    /// whose working directory is its scratch workspace), then the skill directories.
    static func load(
        name: String, dirs: [String] = PermissionPolicy.skillsCheckouts
    ) -> Result<SceneHeader, SceneSkillError> {
        switch RunnerSkillResolver.resolve(name: name, dirs: dirs, accept: isGameSkill) {
        case .run(let path):
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .failure(.unreadable(path: path))
            }
            return SceneHeaderParser.parse(content: content, name: name)
                .mapError { .header(path: path, $0) }
        case .unusable(let path):
            return .failure(.notAGame(path: path))
        case .ambiguous(let paths):
            return .failure(.ambiguous(name: name, paths: paths))
        case .notFound:
            return .failure(.notFound(name: name))
        }
    }

    /// Whether the file at `path` declares `kind: game`.
    static func isGameSkill(_ path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return SkillParser.isGame(content: content)
    }
}

/// Refuses a run whose scene steps cannot play as written.
enum SceneStepGate {

    /// One refused scene step.
    struct Refusal: Equatable {
        let skillName: String
        let stepNumber: Int
        let reason: String
    }

    /// The scene steps of `skills` that cannot play: an unresolvable or invalid
    /// scene skill, a step budget wider than the skill's, a scene timed inside a
    /// `measure`, no vision model to play with, or a move picker that does not
    /// match the skill (missing, unrunnable, or given to a skill that needs none).
    /// `envDecider` is `MIRROIR_SCENE_DECIDER`, used when a step names none.
    static func refusals(
        skills: [SkillDefinition], visionAvailable: Bool,
        envDecider: String? = EnvConfig.sceneDecider,
        load: (String) -> Result<SceneHeader, SceneSkillError> = { SceneSkills.load(name: $0) },
        runnable: (CommandSceneDecider) -> Bool = { $0.isRunnable() }
    ) -> [Refusal] {
        var refusals: [Refusal] = []
        for skill in skills {
            for (index, step) in skill.steps.enumerated() {
                let number = index + 1
                if case .measure(_, .scene, _, _) = step {
                    refusals.append(Refusal(
                        skillName: skill.name, stepNumber: number,
                        reason: "a scene cannot be timed by measure; its report carries its own time"))
                    continue
                }
                guard case .scene(let name, let budget, let stepDecider) = step else { continue }
                if !visionAvailable {
                    refusals.append(Refusal(
                        skillName: skill.name, stepNumber: number,
                        reason: "no vision model is configured to play the scene"))
                }
                switch load(name) {
                case .failure(let error):
                    refusals.append(Refusal(
                        skillName: skill.name, stepNumber: number,
                        reason: error.localizedDescription))
                case .success(let header):
                    let wider = budget.fieldsExceeding(header.budget)
                    if !wider.isEmpty {
                        refusals.append(Refusal(
                            skillName: skill.name, stepNumber: number,
                            reason: "the step budget's \(wider.joined(separator: ", ")) exceed "
                                + "the skill's; a step may only narrow it"))
                    }
                    if let reason = deciderProblem(
                        header: header, command: stepDecider ?? envDecider, runnable: runnable) {
                        refusals.append(Refusal(skillName: skill.name, stepNumber: number, reason: reason))
                    }
                }
            }
        }
        return refusals
    }

    /// Why the move picker `command` does not fit `header`, or nil when it does.
    static func deciderProblem(
        header: SceneHeader, command: String?, runnable: (CommandSceneDecider) -> Bool
    ) -> String? {
        switch (header.needsDecider, command) {
        case (false, nil):
            return nil
        case (false, .some):
            return "the skill chooses its own actions (no `decider: required`); "
                + "drop the step's decider and \(EnvConfig.sceneDeciderVariable)"
        case (true, nil):
            return "the skill needs a move picker: name one with the step's `decider:` "
                + "or \(EnvConfig.sceneDeciderVariable)"
        case (true, .some(let command)):
            guard let decider = CommandSceneDecider(command: command), runnable(decider) else {
                return "the move picker '\(command)' is not a runnable program"
            }
            return nil
        }
    }

    /// Refuse the run when any scene step cannot play. Returns the exit code to
    /// return, or nil to proceed. A dry run plays nothing, so it is not refused.
    static func refuse(skills: [SkillDefinition], dryRun: Bool, visionAvailable: Bool) -> Int32? {
        guard !dryRun else { return nil }
        let found = refusals(skills: skills, visionAvailable: visionAvailable)
        guard !found.isEmpty else { return nil }
        fputs("Refusing to run: \(found.count) scene step(s) cannot play.\n\n", stderr)
        for refusal in found {
            fputs("  \(refusal.skillName) step \(refusal.stepNumber): scene: \(refusal.reason)\n", stderr)
        }
        return 1
    }
}
