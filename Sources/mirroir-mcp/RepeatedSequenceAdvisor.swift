// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Notices an agent repeating the same sequence of input calls and offers it as one run_steps call.
// ABOUTME: Session accumulator over tools/call; advice in a tool reply reaches the agent when it can use it.

import Foundation
import HelperLib

/// Agents repeat what has worked one call at a time, even with a batching tool
/// on offer: measured on the iPhone, none of them chose run_steps for three
/// searches in a row. So the offer comes at the moment it applies: when the
/// last input calls have the same shape as the ones before them, the reply
/// names the steps to pass. Calls that only read the screen do not break a
/// sequence, because agents check between actions; a failed call or an input
/// tool with no step form starts over. Each shape is offered once.
final class RepeatedSequenceAdvisor: @unchecked Sendable {

    /// Sequence lengths worth batching: a single call repeated is a retry or a
    /// scroll, and past this length a repeat is more likely chance than habit.
    static let sequenceLengths = 2 ... 6

    private struct Call {
        let tool: String
        let step: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var offered: Set<[String]> = []

    /// Record one finished tools/call. Returns the advice when this call
    /// completes a sequence's second run.
    func observe(tool: String, arguments: [String: JSONValue], failed: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if PermissionPolicy.readonlyTools.contains(tool) { return nil }
        guard !failed, let step = Self.step(tool: tool, arguments: arguments) else {
            calls.removeAll()
            return nil
        }
        calls.append(Call(tool: tool, step: step))
        calls = Array(calls.suffix(Self.sequenceLengths.upperBound * 2))
        guard let repeated = Self.repeatedRun(in: calls),
              offered.insert(Self.cycle(of: repeated.map(\.tool))).inserted else {
            return nil
        }
        calls.removeAll()
        return Self.advice(for: repeated.map(\.step))
    }

    /// The last calls when they have the same tools, in order, as those right
    /// before them, and more than one tool among them. The shortest such run wins.
    private static func repeatedRun(in calls: [Call]) -> [Call]? {
        for length in sequenceLengths where calls.count >= length * 2 {
            let last = Array(calls.suffix(length))
            let before = calls.dropLast(length).suffix(length)
            guard last.map(\.tool) == before.map(\.tool), Set(last.map(\.tool)).count > 1 else { continue }
            return last
        }
        return nil
    }

    /// One form for every rotation of a sequence: a run that keeps repeating
    /// reads as tap-type-key, then type-key-tap, and it is still one sequence.
    private static func cycle(of tools: [String]) -> [String] {
        tools.indices
            .map { Array(tools[$0...] + tools[..<$0]) }
            .min { $0.joined(separator: " ") < $1.joined(separator: " ") } ?? tools
    }

    private static func advice(for steps: [String]) -> String {
        let list = steps.map { "\"\($0)\"" }.joined(separator: ", ")
        return "You have now run this sequence twice. To run it again in one call, use run_steps "
            + "with steps like [\(list)], changing the values."
    }

    /// The call in run_steps' grammar, or nil for a tool that has no step form.
    private static func step(tool: String, arguments: [String: JSONValue]) -> String? {
        let text = { (key: String) in arguments[key]?.asString() ?? "…" }
        switch tool {
        case "tap":
            if let text = arguments["text"]?.asString() { return "tap: \(text)" }
            guard let x = arguments["x"]?.asNumber(), let y = arguments["y"]?.asNumber() else { return nil }
            return "tap: \(TapStepPoint.format(x: x, y: y))"
        case "type_text":
            return "type: \(text("text"))"
        case "press_key":
            guard case .array(let modifiers)? = arguments["modifiers"], !modifiers.isEmpty else {
                return "press_key: \(text("key"))"
            }
            let names = modifiers.compactMap { $0.asString() }.map { "\"\($0)\"" }.joined(separator: ", ")
            return "press_key: \(text("key")) modifiers: [\(names)]"
        case "launch_app": return "launch: \(text("name"))"
        case "scroll_to": return "scroll_to: \(text("label"))"
        case "open_url": return "open_url: \(text("url"))"
        case "press_home": return "home"
        default: return nil
        }
    }
}
