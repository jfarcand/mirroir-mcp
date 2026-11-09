// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the tap MCP tool: by visible text, by window point, or by a point read off a screenshot.
// ABOUTME: The handler parses arguments; text taps go to InlineStepRunner and image points are converted by ScreenshotGeometry.

import CoreGraphics
import Foundation
import HelperLib

extension MirroirMCP {

    static func registerTapTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        server.registerTool(MCPToolDefinition(
            name: "tap",
            description: """
                Tap on the mirrored iPhone screen, either on visible text or at a \
                position. With `text`, the text is found by OCR and tapped; when \
                it is not on screen, the reply lists the text that is. With `x` \
                and `y`, the point is relative to the iPhone Mirroring window \
                (0,0 is the top-left of the mirrored content); take coordinates \
                from describe_screen, which reports each element's tap point. \
                For something only a screenshot shows, give its position in that \
                image as `x` and `y` with `image_size`: the point is converted to \
                window points for you.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "x": .object([
                        "type": .string("number"),
                        "description": .string(
                            "X coordinate relative to the mirroring window (0 = left edge)"),
                    ]),
                    "y": .object([
                        "type": .string("number"),
                        "description": .string(
                            "Y coordinate relative to the mirroring window (0 = top edge)"),
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Visible text to tap, matched by OCR (exact, then case- and "
                            + "accent-insensitive, then substring). Use instead of x and y."),
                    ]),
                    "image_size": .object([
                        "type": .string("array"),
                        "description": .string(
                            "Give this when x and y were read off a screenshot: [width, height] "
                            + "of that image as you see it. x and y are then converted to window points."),
                    ]),
                    "image_region": .object([
                        "type": .string("array"),
                        "description": .string(
                            "With image_size: the region [x, y, width, height] in window points "
                            + "that screenshot was taken with. Omit for a full-frame screenshot."),
                    ]),
                    "cursor_mode": cursorModeSchema,
                ]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let input = ctx.input

                if let text = args["text"]?.asString() {
                    guard args["image_size"] == nil, args["image_region"] == nil else {
                        return .error("image_size needs x and y: it converts a point, not text")
                    }
                    let executor = InlineStepRunner.executor(for: ctx, registry: registry)
                    let report = InlineStepRunner.run([.tap(label: text)], executor: executor)
                    return report.failed ? .error(report.text) : .text(report.text)
                }
                guard let x = args["x"]?.asNumber(), let y = args["y"]?.asNumber() else {
                    return .error("Missing parameters: give text (string), or x and y (numbers)")
                }

                let cursorMode: CursorMode?
                switch parseCursorMode(args) {
                case .ok(let mode): cursorMode = mode
                case .invalid(let msg): return .error(msg)
                }

                let point: CGPoint
                let origin: String
                switch tapPoint(x: x, y: y, args: args, windowSize: ctx.bridge.getWindowInfo()?.size) {
                case .success(let resolved):
                    point = resolved.point
                    origin = resolved.origin
                case .failure(let refusal):
                    return .error(refusal.message)
                }

                if let error = input.tap(x: point.x, y: point.y, cursorMode: cursorMode) {
                    return .error(error)
                }
                return .text("Tapped at (\(ScreenshotGeometry.whole(point.x)), "
                    + "\(ScreenshotGeometry.whole(point.y)))\(origin)")
            }
        ))
    }

    /// Why image arguments do not name a point.
    struct TapPointRefusal: Error, Equatable {
        let message: String
    }

    /// The window point to tap: `x`, `y` as given, or converted from an image
    /// point when `image_size` is present. `origin` is appended to the reply
    /// so the caller sees the conversion that was made.
    static func tapPoint(
        x: Double, y: Double, args: [String: JSONValue], windowSize: CGSize?
    ) -> Result<(point: CGPoint, origin: String), TapPointRefusal> {
        guard let imageSizeArgument = args["image_size"] else {
            guard args["image_region"] == nil else {
                return .failure(TapPointRefusal(message: "image_region needs image_size"))
            }
            return .success((CGPoint(x: x, y: y), ""))
        }
        guard let size = numbers(imageSizeArgument, count: 2), size[0] > 0, size[1] > 0 else {
            return .failure(TapPointRefusal(
                message: "image_size must be [width, height], both greater than 0"))
        }
        let shown: CGRect
        if let regionArgument = args["image_region"] {
            guard let r = numbers(regionArgument, count: 4), r[2] > 0, r[3] > 0 else {
                return .failure(TapPointRefusal(
                    message: "image_region must be [x, y, width, height] in window points"))
            }
            shown = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        } else {
            guard let windowSize else {
                return .failure(TapPointRefusal(
                    message: "The target window was not found, so the image point cannot be placed"))
            }
            shown = CGRect(origin: .zero, size: windowSize)
        }
        let imageSize = CGSize(width: size[0], height: size[1])
        let point = ScreenshotGeometry.windowPoint(
            imagePoint: CGPoint(x: x, y: y), imageSize: imageSize, shownRect: shown)
        let whole = ScreenshotGeometry.whole
        return .success((point, " (from image point (\(whole(x)), \(whole(y))) in a "
            + "\(whole(size[0]))x\(whole(size[1])) image)"))
    }

    /// The numbers of a JSON array of exactly `count` numbers, or nil.
    private static func numbers(_ value: JSONValue, count: Int) -> [Double]? {
        guard case .array(let items) = value, items.count == count else { return nil }
        let numbers = items.compactMap { $0.asNumber() }
        return numbers.count == count ? numbers : nil
    }
}
