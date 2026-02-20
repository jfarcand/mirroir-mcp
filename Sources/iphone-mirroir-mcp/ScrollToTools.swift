// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the scroll_to MCP tool for scrolling until an element becomes visible.
// ABOUTME: Combines swipe and OCR describe to find elements that are off-screen.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerScrollToTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // scroll_to — scroll until an element is visible via OCR
        server.registerTool(MCPToolDefinition(
            name: "scroll_to",
            description: """
                Scroll in a direction until a target text element becomes visible \
                on the mirrored iPhone screen. Uses OCR to detect the element after \
                each scroll. Stops early if the screen content stops changing \
                (scroll exhaustion). Direction "up" means swipe up (scroll content down).
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "label": .object([
                        "type": .string("string"),
                        "description": .string("Text to find on screen via OCR"),
                    ]),
                    "direction": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("up"), .string("down"),
                            .string("left"), .string("right"),
                        ]),
                        "description": .string(
                            "Scroll direction (default: up). 'up' = swipe up = scroll content down."),
                    ]),
                    "max_scrolls": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum number of scroll attempts before giving up (default: 10)"),
                    ]),
                ]),
                "required": .array([.string("label")]),
            ],
            handler: { args in
                let ctx = registry.resolve(args["target"]?.asString())
                guard let ctx else { return .error("Unknown target '\(args["target"]?.asString() ?? "")'") }
                let bridge = ctx.bridge
                let input = ctx.input
                let describer = ctx.describer

                guard let label = args["label"]?.asString() else {
                    return .error("Missing required parameter: label (string)")
                }

                let direction = args["direction"]?.asString() ?? "up"
                let maxScrolls = args["max_scrolls"]?.asInt() ?? EnvConfig.defaultScrollMaxAttempts

                // Check if already visible
                if let describeResult = describer.describe(skipOCR: false),
                   ElementMatcher.isVisible(label: label, in: describeResult.elements) {
                    return .text("'\(label)' is already visible on screen")
                }

                guard let windowInfo = bridge.getWindowInfo() else {
                    return .error("Could not get window info for scroll")
                }

                let centerX = Double(windowInfo.size.width) / 2.0
                let centerY = Double(windowInfo.size.height) / 2.0
                let swipeDistance = Double(windowInfo.size.height) * EnvConfig.swipeDistanceFraction

                var previousTexts: [String] = []

                for attempt in 0..<maxScrolls {
                    let fromX: Double, fromY: Double, toX: Double, toY: Double
                    switch direction.lowercased() {
                    case "up":
                        fromX = centerX; fromY = centerY + swipeDistance / 2
                        toX = centerX; toY = centerY - swipeDistance / 2
                    case "down":
                        fromX = centerX; fromY = centerY - swipeDistance / 2
                        toX = centerX; toY = centerY + swipeDistance / 2
                    case "left":
                        fromX = centerX + swipeDistance / 2; fromY = centerY
                        toX = centerX - swipeDistance / 2; toY = centerY
                    case "right":
                        fromX = centerX - swipeDistance / 2; fromY = centerY
                        toX = centerX + swipeDistance / 2; toY = centerY
                    default:
                        return .error("Unknown direction: \(direction). Use up/down/left/right.")
                    }

                    if let error = input.swipe(fromX: fromX, fromY: fromY,
                                                toX: toX, toY: toY, durationMs: EnvConfig.defaultSwipeDurationMs) {
                        return .error("Swipe failed: \(error)")
                    }

                    usleep(EnvConfig.toolSettlingDelayUs)

                    if let describeResult = describer.describe(skipOCR: false) {
                        if ElementMatcher.isVisible(label: label, in: describeResult.elements) {
                            return .text("Found '\(label)' after \(attempt + 1) scroll(s)")
                        }

                        // Scroll exhaustion detection
                        let currentTexts = describeResult.elements.map { $0.text }.sorted()
                        if currentTexts == previousTexts {
                            return .error(
                                "'\(label)' not found — scroll exhausted after \(attempt + 1) scroll(s)")
                        }
                        previousTexts = currentTexts
                    }
                }

                return .error("'\(label)' not found after \(maxScrolls) scroll(s)")
            }
        ))
    }
}
