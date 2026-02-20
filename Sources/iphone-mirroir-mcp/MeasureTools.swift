// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the measure MCP tool for timing screen transitions.
// ABOUTME: Executes an action then polls OCR until a target label appears, reporting duration.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerMeasureTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // measure — time how long it takes for a label to appear after an action
        server.registerTool(MCPToolDefinition(
            name: "measure",
            description: """
                Measure the time between performing an action and a target element \
                appearing on screen. Executes the action (tap, launch, etc.), then \
                polls OCR until the target label is visible. Reports the measured \
                duration and optionally fails if it exceeds a maximum threshold.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Action to perform: 'tap:Label', 'launch:AppName', or 'press_key:return'"),
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("Text label to wait for after the action"),
                    ]),
                    "max_seconds": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Maximum allowed seconds (fails if exceeded). Optional."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Name for this measurement (for reporting). Optional."),
                    ]),
                ]),
                "required": .array([.string("action"), .string("until")]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                let bridge = ctx.bridge
                let input = ctx.input
                let describer = ctx.describer

                guard let actionStr = args["action"]?.asString() else {
                    return .error("Missing required parameter: action (string)")
                }
                guard let until = args["until"]?.asString() else {
                    return .error("Missing required parameter: until (string)")
                }

                let maxSeconds = args["max_seconds"]?.asNumber()
                let name = args["name"]?.asString() ?? "measure"

                // Parse and execute the action
                let actionError = executeAction(actionStr, bridge: bridge,
                                                 input: input, describer: describer)
                if let error = actionError {
                    return .error("Action failed: \(error)")
                }

                // Start measuring
                let measureStart = CFAbsoluteTimeGetCurrent()
                let timeout = maxSeconds ?? EnvConfig.defaultMeasureTimeoutSeconds
                let pollIntervalUs: useconds_t = EnvConfig.measurePollIntervalUs

                let maxPolls = Int(timeout * 2)
                for _ in 0..<maxPolls {
                    if let describeResult = describer.describe(skipOCR: false),
                       ElementMatcher.isVisible(label: until, in: describeResult.elements) {
                        let measured = CFAbsoluteTimeGetCurrent() - measureStart
                        if let max = maxSeconds, measured > max {
                            return .error(
                                "\(name): \(String(format: "%.3f", measured))s " +
                                "exceeded \(String(format: "%.1f", max))s max")
                        }
                        return .text(
                            "\(name): \(String(format: "%.3f", measured))s")
                    }
                    usleep(pollIntervalUs)
                }

                let measured = CFAbsoluteTimeGetCurrent() - measureStart
                return .error(
                    "\(name): timed out after \(String(format: "%.1f", measured))s " +
                    "waiting for '\(until)'")
            }
        ))
    }

    /// Parse an action string like "tap:Label" or "launch:AppName" and execute it.
    private static func executeAction(
        _ actionStr: String,
        bridge: any WindowBridging,
        input: any InputProviding,
        describer: any ScreenDescribing
    ) -> String? {
        guard let colonIdx = actionStr.firstIndex(of: ":") else {
            return "Invalid action format: '\(actionStr)'. Use 'tap:Label' or 'launch:AppName'."
        }

        let actionType = String(actionStr[actionStr.startIndex..<colonIdx])
            .trimmingCharacters(in: .whitespaces)
        let actionValue = String(actionStr[actionStr.index(after: colonIdx)...])
            .trimmingCharacters(in: .whitespaces)

        switch actionType {
        case "tap":
            guard let describeResult = describer.describe(skipOCR: false) else {
                return "Failed to capture screen for OCR"
            }
            guard let match = ElementMatcher.findMatch(label: actionValue,
                                                         in: describeResult.elements) else {
                return "Element '\(actionValue)' not found on screen"
            }
            return input.tap(x: match.element.tapX, y: match.element.tapY)

        case "launch":
            return input.launchApp(name: actionValue)

        case "press_key":
            let result = input.pressKey(keyName: actionValue, modifiers: [])
            return result.success ? nil : (result.error ?? "Failed to press key")

        default:
            return "Unknown action type: '\(actionType)'. Use tap, launch, or press_key."
        }
    }
}
