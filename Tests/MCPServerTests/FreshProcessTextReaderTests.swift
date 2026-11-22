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
// ABOUTME: Tests the fresh-process OCR recovery: the fallback order, the child's JSON, and its command line.
// ABOUTME: The readers are closures here; the real stuck-process recovery is measured on a device (carnet#90).

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import mirroir_mcp

final class FreshProcessTextReaderTests: XCTestCase {

    private struct Stuck: Error, Equatable {}
    private struct ChildFailed: Error {}

    private let line = RecognizedTextLine(text: "Calendar", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.03),
                                          confidence: 1)

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - Fallback order

    func testAWorkingProcessNeverStartsAChild() throws {
        let lines = try AppleVisionTextRecognizer.read(
            try image(), inProcess: { _ in [self.line] },
            freshProcess: { _ in XCTFail("no child when the process reads"); return [] })
        XCTAssertEqual(lines, [line])
    }

    /// carnet#90: a process whose Vision model left the cache fails every read;
    /// a fresh process reads the same frame.
    func testAStuckProcessReadsThroughAFreshOne() throws {
        let lines = try AppleVisionTextRecognizer.read(
            try image(), inProcess: { _ in throw Stuck() }, freshProcess: { _ in [self.line] })
        XCTAssertEqual(lines, [line])
    }

    func testWhenBothFailTheInProcessErrorIsReported() throws {
        XCTAssertThrowsError(try AppleVisionTextRecognizer.read(
            try image(), inProcess: { _ in throw Stuck() }, freshProcess: { _ in throw ChildFailed() })) {
            XCTAssertEqual($0 as? Stuck, Stuck())
        }
    }

    // MARK: - The child

    func testATestHostNeverLaunchesItself() throws {
        XCTAssertNil(FreshProcessTextReader.executablePath, "only the mirroir entry point sets it")
        XCTAssertThrowsError(try FreshProcessTextReader.read(try image())) {
            XCTAssertEqual($0 as? FreshProcessReadError, .noExecutable)
        }
    }

    func testLinesSurviveTheTripThroughJSON() throws {
        let data = try JSONEncoder().encode([line])
        XCTAssertEqual(try JSONDecoder().decode([RecognizedTextLine].self, from: data), [line])
    }

    func testTheFrameIsWrittenAsAReadablePNG() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mirroir-ocr-test-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FreshProcessTextReader.writePNG(try image(), to: url))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 4)
    }

    // MARK: - Command line

    func testTheCommandTakesOneImagePath() throws {
        XCTAssertEqual(try RecognizeTextCommand.parseArguments(["/tmp/frame.png"]), "/tmp/frame.png")
        XCTAssertThrowsError(try RecognizeTextCommand.parseArguments([]))
        XCTAssertThrowsError(try RecognizeTextCommand.parseArguments(["--fast"]))
        XCTAssertThrowsError(try RecognizeTextCommand.parseArguments(["a.png", "b.png"]))
    }

    func testTheCommandIsRouted() {
        guard case .subcommand(let command, let arguments) = CLIDispatch.route(["recognize-text", "frame.png"]) else {
            return XCTFail("recognize-text is a subcommand")
        }
        XCTAssertEqual(command.name, RecognizeTextCommand.commandName)
        XCTAssertEqual(arguments, ["frame.png"])
    }
}
