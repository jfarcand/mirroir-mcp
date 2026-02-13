// ABOUTME: Registers screen-related MCP tools: screenshot, describe_screen, start/stop recording.
// ABOUTME: Each tool maps MCP JSON-RPC calls to the capture, recorder, and describer subsystems.

import Foundation
import HelperLib

extension IPhoneMirroirMCP {
    static func registerScreenTools(
        server: MCPServer,
        bridge: MirroringBridge,
        capture: ScreenCapture,
        recorder: ScreenRecorder,
        describer: ScreenDescriber
    ) {
        // screenshot — capture the mirroring window
        server.registerTool(MCPToolDefinition(
            name: "screenshot",
            description: """
                Capture a screenshot of the iPhone Mirroring window. \
                Returns the current screen content as a PNG image. \
                Use this to see what is displayed on the mirrored iPhone.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                guard bridge.findProcess() != nil else {
                    return .error("iPhone Mirroring app is not running")
                }

                let state = bridge.getState()
                if state == .paused {
                    _ = bridge.pressResume()
                    usleep(2_000_000) // Wait 2s for connection to resume
                }

                guard let base64 = capture.captureBase64() else {
                    return .error(
                        "Failed to capture screenshot. Is iPhone Mirroring window visible?")
                }

                return .image(base64)
            }
        ))

        // describe_screen — OCR-based screen element detection with tap coordinates
        server.registerTool(MCPToolDefinition(
            name: "describe_screen",
            description: """
                Analyze the iPhone screen using OCR and return all visible text elements \
                with their exact tap coordinates. Use this instead of visually estimating \
                positions from screenshots. Returns both a structured text list of elements \
                and the screenshot image. Coordinates are in the same point system as the \
                tap tool (0,0 = top-left of mirroring window).
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                guard bridge.findProcess() != nil else {
                    return .error("iPhone Mirroring app is not running")
                }
                let state = bridge.getState()
                if state == .paused {
                    _ = bridge.pressResume()
                    usleep(2_000_000)
                }
                guard let result = describer.describe() else {
                    return .error(
                        "Failed to capture/analyze screen. Is iPhone Mirroring window visible?")
                }

                var lines = ["Screen elements (tap coordinates in points):"]
                for el in result.elements.sorted(by: { $0.tapY < $1.tapY }) {
                    lines.append("- \"\(el.text)\" at (\(Int(el.tapX)), \(Int(el.tapY)))")
                }
                if result.elements.isEmpty {
                    lines.append("(no text detected)")
                }
                let description = lines.joined(separator: "\n")

                return MCPToolResult(
                    content: [
                        .text(description),
                        .image(result.screenshotBase64, mimeType: "image/png"),
                    ],
                    isError: false
                )
            }
        ))

        // start_recording — begin video recording of the mirroring window
        server.registerTool(MCPToolDefinition(
            name: "start_recording",
            description: """
                Start recording a video of the mirrored iPhone screen. \
                Records the iPhone Mirroring window as a .mov file. \
                Use stop_recording to end the recording and get the file path. \
                Requires Screen Recording permission in System Preferences.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "output_path": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional file path for the recording (default: temp directory)"),
                    ])
                ]),
            ],
            handler: { args in
                let outputPath = args["output_path"]?.asString()

                if let error = recorder.startRecording(outputPath: outputPath) {
                    return .error(error)
                }
                return .text("Recording started")
            }
        ))

        // stop_recording — stop video recording and return the file path
        server.registerTool(MCPToolDefinition(
            name: "stop_recording",
            description: """
                Stop the current video recording and return the file path. \
                Must be called after start_recording. Returns the path to \
                the recorded .mov file.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
            ],
            handler: { _ in
                let result = recorder.stopRecording()
                if let error = result.error {
                    return .error(error)
                }
                guard let path = result.filePath else {
                    return .error("Recording stopped but no file was produced")
                }
                return .text("Recording saved to: \(path)")
            }
        ))
    }
}
