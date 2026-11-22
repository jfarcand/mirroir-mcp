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
// ABOUTME: Reads the text in an image by running this binary's `recognize-text` command in a new process.
// ABOUTME: The recovery for a process whose Vision model was removed from its cache, where every in-process read fails.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a fresh-process read produced no lines.
enum FreshProcessReadError: Error, CustomStringConvertible, Equatable {
    /// This process was not started from the mirroir entry point (a test host).
    case noExecutable
    /// The image could not be written for the child to read.
    case imageNotWritten
    /// The child could not be started.
    case launchFailed(String)
    /// The child ran longer than `FreshProcessTextReader.timeoutSeconds`.
    case timedOut
    /// The child exited with a non-zero status; `message` is its stderr tail.
    case childFailed(status: Int32, message: String)
    /// The child's output was not the JSON `recognize-text` prints.
    case unreadableOutput

    var description: String {
        switch self {
        case .noExecutable: return "no mirroir executable to run"
        case .imageNotWritten: return "the image could not be written for the child process"
        case .launchFailed(let reason): return "the child process could not start: \(reason)"
        case .timedOut: return "the child process took longer than \(Int(FreshProcessTextReader.timeoutSeconds)) s"
        case .childFailed(let status, let message): return "the child process exited \(status): \(message)"
        case .unreadableOutput: return "the child process printed no readable lines"
        }
    }
}

/// Runs `<this binary> recognize-text <png>` and decodes the lines it prints.
enum FreshProcessTextReader {

    /// The binary to run, set by the entry point. Nil in a test host, where the
    /// running executable is not mirroir and must never be launched.
    nonisolated(unsafe) static var executablePath: String?

    /// How long the child may take. A process whose Vision model is not yet in
    /// the cache compiles it first, which took 45-56 s on macOS 27.2.1.
    static let timeoutSeconds: TimeInterval = 120

    /// Interval between checks on the running child.
    private static let pollMicroseconds: UInt32 = 50_000

    /// Read `image` in a new process.
    ///
    /// - Throws: `FreshProcessReadError` when there is no binary to run, the
    ///   child fails or times out, or its output cannot be decoded.
    static func read(_ image: CGImage) throws -> [RecognizedTextLine] {
        guard let executablePath else { throw FreshProcessReadError.noExecutable }
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-ocr-\(UUID().uuidString).png")
        guard writePNG(image, to: imageURL) else { throw FreshProcessReadError.imageNotWritten }
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [RecognizeTextCommand.commandName, imageURL.path]
        // The child captures nothing, so it needs no executable copy of its own.
        var environment = ProcessInfo.processInfo.environment
        environment[ExecutablePathIsolation.isolatedEnvironmentKey] = "1"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let started = Date()
        do {
            try process.run()
        } catch {
            throw FreshProcessReadError.launchFailed("\(error)")
        }
        // Drain stdout while the child runs: a full pipe would block it.
        nonisolated(unsafe) var stdout = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stdout = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let deadline = started.addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            usleep(pollMicroseconds)
        }
        if process.isRunning {
            process.terminate()
            throw FreshProcessReadError.timedOut
        }
        drained.wait()
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FreshProcessReadError.childFailed(status: process.terminationStatus,
                                                    message: String(message.suffix(300)))
        }
        guard let lines = try? JSONDecoder().decode([RecognizedTextLine].self, from: stdout) else {
            throw FreshProcessReadError.unreadableOutput
        }
        DebugLog.persist("OCR", "fresh-process read: \(lines.count) lines in \(elapsedMs)ms")
        return lines
    }

    /// Write `image` as a PNG at `url`; false when ImageIO refuses.
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
