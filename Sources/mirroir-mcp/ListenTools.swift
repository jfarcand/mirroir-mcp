// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Registers the listen MCP tool: hear what the target plays (a reel, a voice message) as text.
// ABOUTME: The handler parses arguments; AudioListener records the app's audio and transcribes it on the Mac.

import Foundation
import HelperLib

extension MirroirMCP {

    /// Register `listen`. `capturer` and `transcriber` are ScreenCaptureKit and
    /// SpeechAnalyzer in the server, stand-ins in tests.
    static func registerListenTools(
        server: MCPServer,
        registry: TargetRegistry,
        capturer: any AppAudioCapturing = ScreenCaptureKitAudio(),
        transcriber: any SpeechTranscribing = OnDeviceTranscriber()
    ) {
        server.registerTool(MCPToolDefinition(
            name: "listen",
            description: """
                Hear what the phone is playing right now, as text: a reel's or \
                video's narration, a voice message, a spoken recipe. Records the \
                sound iPhone Mirroring plays for `seconds`, then transcribes it on \
                this Mac; the audio never leaves it and is deleted after. Start the \
                video or message first, and pass `language` as the iPhone's language \
                when it is not the Mac's ("fr-CA", "en-US"). Words only: it does not \
                say who spoke, and sung lyrics come out approximate. Needs macOS 26.
                """,
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "seconds": .object([
                        "type": .string("number"),
                        "description": .string("How long to listen, \(Int(AudioListener.minSeconds)) to "
                            + "\(Int(AudioListener.maxSeconds)) (default \(Int(AudioListener.defaultSeconds)))."),
                    ]),
                    "language": .object([
                        "type": .string("string"),
                        "description": .string("Language spoken, as a BCP-47 tag such as \"fr-CA\". "
                            + "Default: the Mac's language."),
                    ]),
                ]),
            ],
            handler: { args in
                let (ctx, err) = registry.resolveForTool(args)
                guard let ctx else { return err! }
                let outcome = AudioListener.listen(
                    bridge: ctx.bridge,
                    seconds: AudioListener.clampedSeconds(args["seconds"]?.asNumber()),
                    language: args["language"]?.asString(),
                    capturer: capturer, transcriber: transcriber)
                return outcome.isError ? .error(outcome.text) : .text(outcome.text)
            }
        ))
    }
}
