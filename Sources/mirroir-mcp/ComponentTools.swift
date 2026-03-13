// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the calibrate_component MCP tool for validating component definition files.
// ABOUTME: Thin handler that parses args, reads the definition file, and delegates to ComponentTester.

import Foundation
import HelperLib

extension MirroirMCP {
    static func registerComponentTools(
        server: MCPServer,
        registry: TargetRegistry
    ) {
        // calibrate_component — validate a component definition against the live screen
        server.registerTool(MCPToolDefinition(
            name: "calibrate_component",
            description: """
                Test a component definition (.md file) against the current iPhone screen. \
                OCRs the screen, runs component detection with the given definition, \
                and returns a full diagnostic report showing what matched, what didn't, \
                and why. Use this to validate and debug component definitions without \
                running a full exploration.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "component_path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Path to a .md component definition file"),
                    ]),
                    "target": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Target name for multi-target setups (optional)"),
                    ]),
                    "scroll": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Scroll through the full page to collect all elements (default: false)"),
                    ]),
                ]),
                "required": .array([.string("component_path")]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let bridge = ctx.bridge
                let input = ctx.input
                let describer = ctx.describer

                // Parse component_path argument
                guard let componentPath = args["component_path"]?.asString(),
                      !componentPath.isEmpty else {
                    return .error("component_path is required")
                }

                let scrollEnabled = args["scroll"]?.asBool() ?? false

                // Validate file extension and resolve symlinks to prevent path traversal
                let fileURL = URL(fileURLWithPath: componentPath)
                    .standardized.resolvingSymlinksInPath()
                guard fileURL.pathExtension == "md" else {
                    return .error("component_path must be a .md file")
                }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    return .error("Cannot read file: \(componentPath)")
                }

                let stem = fileURL.deletingPathExtension().lastPathComponent
                guard let definition = ComponentSkillParser.parseValidated(
                    content: content, fallbackName: stem
                ) else {
                    return .error("Component '\(stem)' has invalid keys — check DebugLog for details")
                }

                // Verify target is running
                guard bridge.findProcess() != nil else {
                    return .error("Target '\(ctx.name)' is not running")
                }

                // Resume if paused
                let state = bridge.getState()
                if state == .paused {
                    if let menuBridge = bridge as? (any MenuActionCapable) {
                        _ = menuBridge.pressResume()
                        usleep(EnvConfig.resumeFromPausedUs)
                    }
                }

                // Collect OCR elements: single viewport or full-page scroll
                let elements: [TapPoint]
                let screenshotBase64: String

                if scrollEnabled {
                    guard let scrollResult = describer.describeFullPage(
                        input: input, bridge: bridge
                    ) else {
                        return .error(
                            "Failed to capture/analyze screen. Is the '\(ctx.name)' window visible?")
                    }
                    elements = scrollResult.elements
                    screenshotBase64 = scrollResult.screenshotBase64
                } else {
                    guard let result = describer.describe() else {
                        return .error(
                            "Failed to capture/analyze screen. Is the '\(ctx.name)' window visible?")
                    }
                    elements = result.elements
                    screenshotBase64 = result.screenshotBase64
                }

                // Get screen height for zone calculation
                let screenHeight = bridge.getWindowInfo()?.size.height ?? 0

                // Load all definitions for comparison
                let allDefinitions = ComponentLoader.loadAll()

                // Generate diagnostic report
                let report = ComponentTester.diagnose(
                    definition: definition,
                    elements: elements,
                    screenHeight: screenHeight,
                    allDefinitions: allDefinitions
                )

                return MCPToolResult(
                    content: [
                        .text(report),
                        .image(screenshotBase64, mimeType: "image/png"),
                    ],
                    isError: false
                )
            }
        ))
    }
}
