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
// ABOUTME: Collects the steps of passing run_steps calls that share a task label, and writes them as a SKILL.md draft.
// ABOUTME: Session accumulator held per server, bounded in tasks and steps; the draft goes back in the reply, never to disk.

import Foundation

/// The passing `run_steps` calls of one session, grouped by their `task`
/// label, so a task done over several calls comes back as one skill draft.
final class TaskDraft: @unchecked Sendable {

    /// Tasks kept at once; the least recently used one is dropped past it.
    static let maxTasks = 20
    /// Steps kept for one task; a run that would pass it is not added.
    static let maxStepsPerTask = 200
    /// The longest task label.
    static let maxTaskLength = 120

    /// What recording a run did.
    enum Outcome {
        /// The run's steps were added; the task now holds `steps` over `runs` runs.
        case added(steps: [SkillStep], runs: Int)
        /// The run would take the task past `maxStepsPerTask`, so it was not added.
        case full(steps: [SkillStep], runs: Int)
    }

    private struct Entry {
        var steps: [SkillStep]
        var runs: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Task labels, least recently used first.
    private var order: [String] = []

    /// Why `task` cannot label a run, or nil when it can.
    static func refusal(of task: String) -> String? {
        if task.isEmpty { return "task must not be empty" }
        if task.count > maxTaskLength { return "task must be at most \(maxTaskLength) characters" }
        if task.contains(where: \.isNewline) || task.contains("\"") {
            return "task must be one line without double quotes"
        }
        return nil
    }

    /// Add the steps of a passing run to `task`.
    func record(task: String, steps: [SkillStep]) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[task] ?? Entry(steps: [], runs: 0)
        order.removeAll { $0 == task }
        order.append(task)
        guard entry.steps.count + steps.count <= Self.maxStepsPerTask else {
            entries[task] = entry
            return .full(steps: entry.steps, runs: entry.runs)
        }
        entry.steps += steps
        entry.runs += 1
        entries[task] = entry
        while order.count > Self.maxTasks {
            entries.removeValue(forKey: order.removeFirst())
        }
        return .added(steps: entry.steps, runs: entry.runs)
    }

    /// The steps `task` holds, in run order; empty when it holds none.
    func steps(of task: String) -> [SkillStep] {
        lock.lock()
        defer { lock.unlock() }
        return entries[task]?.steps ?? []
    }

    /// What the reply of a run labelled `task` adds: the draft of every
    /// passing run of the task so far, or why this run was not added.
    func note(task: String, report: InlineStepRunner.Report, steps: [SkillStep]) -> String {
        guard report.results.allSatisfy({ $0.status == .passed }) else {
            return "This run was not added to the task \"\(task)\": only a run whose every step passed is."
        }
        switch record(task: task, steps: steps) {
        case .added(let all, let runs):
            return "SKILL.md draft for the task \"\(task)\" (\(runs) run(s), \(all.count) step(s)). "
                + "Save it under ~/.mirroir-mcp/skills/ to keep it:\n\n" + Self.markdown(task: task, steps: all)
        case .full(let all, let runs):
            return "This run was not added to the task \"\(task)\": it already holds \(all.count) step(s) "
                + "over \(runs) run(s), and a task holds at most \(Self.maxStepsPerTask)."
        }
    }

    // MARK: - The draft

    /// A SKILL.md for `steps`, named after `task`: front matter, the task as
    /// its description, and the steps as numbered lines, the way
    /// `mirroir migrate` writes them.
    static func markdown(task: String, steps: [SkillStep]) -> String {
        var apps: [String] = []
        for step in steps {
            if case .launch(let app) = step, !apps.contains(app) { apps.append(app) }
        }
        var lines = ["---", "version: \(SkillMdParser.currentVersion)", "name: \"\(task)\""]
        if !apps.isEmpty { lines.append("app: \(apps.joined(separator: ", "))") }
        lines += ["---", "", task, "", "## Steps", ""]
        let raw = steps.map { RawStep.simple(key: $0.typeKey, value: rawValue(of: $0)) }
        lines += MigrateStepFormatter.convertSteps(raw, startNumber: 1, indent: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The value `MigrateStepFormatter` reads for `step`: its plain value, or
    /// the structured value it replays with.
    private static func rawValue(of step: SkillStep) -> String {
        step.hasStructuredReplayValue ? (step.replayValue ?? "") : (step.plainValue ?? "")
    }
}
