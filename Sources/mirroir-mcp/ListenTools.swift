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
                sound iPhone Mirroring plays for up to `seconds`, stopping early \
                when nothing plays from the start (a muted video) or once the sound \
                has ended, then transcribes it on \
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
