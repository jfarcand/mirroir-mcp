// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the scroll_to MCP tool for scrolling until an element becomes visible.
// ABOUTME: The handler parses arguments; ScrollSeeker scrolls, reads the screen and decides when the content has ended.

import CoreGraphics
import Foundation
import HelperLib

extension MirroirMCP {
    static func registerScrollToTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // scroll_to — scroll until an element is visible via OCR
        server.registerTool(MCPToolDefinition(
            name: "scroll_to",
            description: """
                Scroll until a text becomes visible on the mirrored iPhone screen, \
                reading the screen after each scroll. direction says where the \
                content you want is: "down" (the default) shows what is further \
                down the page, "up" what is above, "left" and "right" what is to \
                that side. It is the opposite of the finger's motion; to move the \
                finger, use swipe. Stops when the content stops moving \
                (stop_reason=end_of_content) or the scroll budget is spent \
                (stop_reason=max_scrolls).
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
                        "enum": .array(ScrollDirection.allCases.map { .string($0.rawValue) }),
                        "description": .string("Where the content you want is (default: down)."),
                    ]),
                    "at": .object([
                        "type": .string("array"),
                        "description": .string(
                            "Point [x, y] in window points to scroll at, for a list inside the "
                            + "screen (a carousel, a sheet). Default: the window centre."),
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
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let bridge = ctx.bridge
                let input = ctx.input
                let describer = ctx.ocrDescriber

                guard let label = args["label"]?.asString() else {
                    return .error("Missing required parameter: label (string)")
                }

                let directionName = args["direction"]?.asString() ?? ScrollDirection.down.rawValue
                guard let direction = ScrollDirection(rawValue: directionName.lowercased()) else {
                    return .error("Unknown direction: \(directionName). Use \(ScrollDirection.names).")
                }
                let maxScrolls = args["max_scrolls"]?.asInt() ?? EnvConfig.defaultScrollMaxAttempts

                var anchor: CGPoint?
                if let at = args["at"] {
                    guard case .array(let pair) = at, pair.count == 2,
                          let x = pair[0].asNumber(), let y = pair[1].asNumber(),
                          let window = bridge.getWindowInfo()?.size,
                          (0 ... window.width).contains(x), (0 ... window.height).contains(y) else {
                        let size = bridge.getWindowInfo().map {
                            "\(Int($0.size.width))x\(Int($0.size.height)) "
                        } ?? ""
                        return .error("at must be [x, y] inside the \(size)window")
                    }
                    anchor = CGPoint(x: x, y: y)
                }

                let outcome = ScrollSeeker.seek(
                    label: label, toward: direction, maxScrolls: maxScrolls, anchor: anchor,
                    band: ScrollSeeker.band(for: ctx.profile, orientation: bridge.getOrientation()),
                    bridge: bridge, input: input, describer: describer)
                let reply = outcome.toolReply(label: label)
                return reply.isError ? .error(reply.text) : .text(reply.text)
            }
        ))
    }
}
