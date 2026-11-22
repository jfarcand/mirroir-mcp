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
// ABOUTME: CLI command that reads the text in one image file with Vision and prints the lines as JSON.
// ABOUTME: A process whose own Vision reads keep failing runs it to read a frame in a fresh process.

import CoreGraphics
import Foundation
import ImageIO

/// Reads the text in an image file.
///
/// Usage: `mirroir-mcp recognize-text <image>`
enum RecognizeTextCommand {

    /// The word after `mirroir-mcp`.
    static let commandName = "recognize-text"

    static var usage: String {
        """
            Usage: mirroir-mcp \(commandName) <image>

            Reads the text in <image> (PNG or JPEG) with Apple Vision, using the OCR
            settings in settings.json, and prints one JSON array of lines: text,
            normalized bounding box (origin bottom-left) and confidence. mirroir
            runs it itself when its own text recognition stops working.
            """
    }

    /// The image path from a command line.
    ///
    /// - Throws: `CLIArgumentError` for no path, an option, or a second argument.
    static func parseArguments(_ args: [String]) throws -> String {
        guard let path = args.first else {
            throw CLIArgumentError.missingArgument("an image path", command: commandName)
        }
        if path.hasPrefix("-") { throw CLIArgumentError.unknownOption(path, command: commandName) }
        guard args.count == 1 else {
            throw CLIArgumentError.unexpectedArgument(args[1], command: commandName)
        }
        return path
    }

    /// Read the image and print its lines. Returns 0, or 1 when the image
    /// cannot be loaded or Vision fails.
    static func run(arguments: [String]) -> Int32 {
        let path: String
        do {
            path = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fputs("Error: cannot read an image at \(path)\n", stderr)
            return 1
        }
        do {
            let lines = try AppleVisionTextRecognizer().inProcessLines(in: image)
            let data = try JSONEncoder().encode(lines)
            FileHandle.standardOutput.write(data)
            return 0
        } catch {
            fputs("Error: \(error)\n", stderr)
            return 1
        }
    }
}
