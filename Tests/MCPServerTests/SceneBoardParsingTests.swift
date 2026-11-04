// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests how a board scene is read: grid controls and cell names, predicate lists, image width, decider.
// ABOUTME: Also the actions a reply may name: cells on a grid, none (wait), and the reading a move picker gets.

import HelperLib
import XCTest
@testable import mirroir_mcp

final class SceneBoardParsingTests: XCTestCase {

    static func skill(
        frontMatter: String = "", controls: String = "- board: grid 8x8 from 0.019,0.350 to 0.981,0.795"
    ) -> String {
        """
        ---
        version: 1
        name: Chess
        kind: game
        surface: scene
        controls: [board]
        budget: { max_frames: 100, max_tokens: 400000, max_seconds: 1200 }
        success: { visible: "Vous avez gagné" }
        \(frontMatter)
        ---

        ## Objective

        Read the board into a FEN.

        ## Controls

        \(controls)
        """
    }

    private func parse(_ content: String) -> Result<SceneHeader, SceneHeaderError> {
        SceneHeaderParser.parse(content: content, name: "chess")
    }

    // MARK: - Grid control

    func testAGridControlParsesItsSizeAndCorners() throws {
        let header = try parse(Self.skill()).get()
        XCTAssertEqual(header.controls, [SceneControl(
            name: "board", gesture: .grid(cols: 8, rows: 8, x0: 0.019, y0: 0.350, x1: 0.981, y1: 0.795))])
        XCTAssertEqual(header.controls.first?.kind, "grid")
    }

    func testCellsAreNamedFromTheBottomLeftOfTheScreen() throws {
        let board = SceneGesture.grid(cols: 8, rows: 8, x0: 0, y0: 0, x1: 0.8, y1: 0.8)
        let a1 = try XCTUnwrap(board.cellCenter("a1"))
        XCTAssertEqual(a1.x, 0.05, accuracy: 1e-9, "column a is the leftmost")
        XCTAssertEqual(a1.y, 0.75, accuracy: 1e-9, "row 1 is the bottom")
        let h8 = try XCTUnwrap(board.cellCenter("h8"))
        XCTAssertEqual(h8.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(h8.y, 0.05, accuracy: 1e-9)
        XCTAssertNil(board.cellCenter("i1"), "past the last column")
        XCTAssertNil(board.cellCenter("a9"), "past the last row")
        XCTAssertNil(board.cellCenter("a0"))
        XCTAssertNil(board.cellCenter("A1"), "columns are lowercase letters")
        XCTAssertNil(board.cellCenter("a01"), "no padded rows")
        XCTAssertNil(SceneGesture.tap(x: 0.5, y: 0.5).cellCenter("a1"), "only a grid has cells")
    }

    func testABadGridIsRefused() {
        let bad = [
            "- board: grid 0x8 from 0.1,0.1 to 0.9,0.9",
            "- board: grid 27x8 from 0.1,0.1 to 0.9,0.9",
            "- board: grid 8 from 0.1,0.1 to 0.9,0.9",
            "- board: grid 8x8 from 0.9,0.9 to 0.1,0.1",
            "- board: grid 8x8 from 0.1,0.1 to 1.2,0.9",
            "- board: grid 8x8 from 0.1,0.1",
        ]
        for line in bad {
            guard case .failure(.controls) = parse(Self.skill(controls: line)) else {
                return XCTFail("accepted: \(line)")
            }
        }
    }

    func testNoneCannotBeDeclaredAsAControl() {
        let content = Self.skill(controls: "- none: tap at 0.5,0.5").replacingOccurrences(
            of: "controls: [board]", with: "controls: [none]")
        guard case .failure(.controls(let reason)) = parse(content) else { return XCTFail("none accepted") }
        XCTAssertTrue(reason.contains("reserved"), reason)
    }

    // MARK: - Header fields

    func testAPredicateListIsMetByAnyOfItsTexts() throws {
        let header = try parse(Self.skill(
            frontMatter: #"fail: { visible: ["Vous avez perdu", "Jouer contre des bots"] }"#)).get()
        XCTAssertEqual(header.fail, [.visible("Vous avez perdu"), .visible("Jouer contre des bots")])
        let frame = [TapPoint(text: "Jouer contre des bots", tapX: 1, tapY: 1, confidence: 1)]
        XCTAssertTrue(SceneHeader.anyMet(header.fail, by: frame))
        XCTAssertFalse(SceneHeader.anyMet(header.success, by: frame))
    }

    func testABadPredicateListIsRefused() {
        for raw in [#"fail: { visible: [] }"#, #"fail: { visible: ["a", "b" }"#, #"fail: { seen: "a" }"#] {
            guard case .failure(.predicate) = parse(Self.skill(frontMatter: raw)) else {
                return XCTFail("accepted: \(raw)")
            }
        }
    }

    func testImageWidthAndDeciderAreRead() throws {
        let header = try parse(Self.skill(frontMatter: "image_width: 800\ndecider: required")).get()
        XCTAssertEqual(header.imageWidth, 800)
        XCTAssertTrue(header.needsDecider)
        let plain = try parse(Self.skill()).get()
        XCTAssertNil(plain.imageWidth)
        XCTAssertFalse(plain.needsDecider)
    }

    func testABadImageWidthOrDeciderIsRefused() {
        guard case .failure(.imageWidth) = parse(Self.skill(frontMatter: "image_width: 4000")) else {
            return XCTFail("a 4000px frame accepted")
        }
        guard case .failure(.decider) = parse(Self.skill(frontMatter: "decider: stockfish")) else {
            return XCTFail("a skill named its own program")
        }
    }

    // MARK: - Actions

    private let controls = [
        SceneControl(name: "board", gesture: .grid(cols: 8, rows: 8, x0: 0, y0: 0, x1: 1, y1: 1)),
        SceneControl(name: "fire", gesture: .tap(x: 0.5, y: 0.5)),
    ]

    func testAGridReplyNamesItsCellsInOrder() {
        let action = ScenePrompt.parseAction(
            #"{"control": "board", "cells": ["e2", "e4"], "rationale": "open"}"#, controls: controls)
        XCTAssertEqual(action?.control?.name, "board")
        XCTAssertEqual(action?.cells, ["e2", "e4"])
    }

    func testAGridReplyNeedsValidCellsAndATapTakesNone() {
        let rejected = [
            #"{"control": "board", "rationale": "x"}"#,
            #"{"control": "board", "cells": ["e2", "z9"], "rationale": "x"}"#,
            #"{"control": "board", "cells": ["a1", "a2", "a3", "a4", "a5"], "rationale": "x"}"#,
            #"{"control": "fire", "cells": ["a1"], "rationale": "x"}"#,
            #"{"control": "none", "cells": ["a1"], "rationale": "x"}"#,
        ]
        for reply in rejected {
            XCTAssertNil(ScenePrompt.parseAction(reply, controls: controls), reply)
        }
    }

    func testTheTemplatesEmptyKeysMeanUnused() {
        let action = ScenePrompt.parseAction(
            #"{"control": "fire", "direction": "", "cells": [], "rationale": "x"}"#, controls: controls)
        XCTAssertEqual(action?.control?.name, "fire")
    }

    func testNoneIsAWait() {
        let action = ScenePrompt.parseAction(#"{"control": "none", "rationale": "thinking"}"#, controls: controls)
        XCTAssertEqual(action?.isWait, true)
        XCTAssertEqual(action?.controlName, "none")
    }

    func testAMovePickersAnswerNeedsNoRationale() {
        XCTAssertNil(ScenePrompt.parseAction(#"{"control": "board", "cells": ["a1"]}"#, controls: controls))
        XCTAssertEqual(ScenePrompt.parseAction(
            #"{"control": "board", "cells": ["a1"]}"#, controls: controls, rationaleRequired: false)?.cells,
            ["a1"])
    }

    func testAReadingReplyIsExactlyAReadingAndARationale() {
        XCTAssertEqual(ScenePrompt.parseReading(#"{"reading": "8/8 w", "rationale": "board"}"#), "8/8 w")
        XCTAssertNil(ScenePrompt.parseReading(#"{"reading": "", "rationale": "board"}"#))
        XCTAssertNil(ScenePrompt.parseReading(#"{"control": "board", "cells": ["a1"], "rationale": "x"}"#))
    }

    /// Seen on device: the model reasons row by row, then answers. The reading is
    /// right, so the reasoning before the object must not cost the frame.
    func testReasoningBeforeTheAnswerIsSkipped() {
        let reasoned = "Row 8: rnbqkbnr.\nRow 7: pppppppp.\n\n{\"reading\": \"8/8 w\", \"rationale\": \"x\"}"
        XCTAssertEqual(ScenePrompt.parseReading(reasoned), "8/8 w")
        let fenced = "I read the board.\n```json\n{\"reading\": \"8/8 w\", \"rationale\": \"x\"}\n```"
        XCTAssertEqual(ScenePrompt.parseReading(fenced), "8/8 w")
        let braces = "A {curly} aside first.\n{\"control\": \"fire\", \"rationale\": \"x\"}"
        XCTAssertEqual(ScenePrompt.parseAction(braces, controls: controls)?.control?.name, "fire")
    }

    func testTextAfterTheAnswerIsStillRejected() {
        XCTAssertNil(ScenePrompt.parseReading(#"{"reading": "8/8 w", "rationale": "x"} then more"#))
        XCTAssertNil(ScenePrompt.parseReading("Row 8: rnbqkbnr, no answer"))
    }

    func testTheReadingPromptAsksForTheReadingAndNoAction() throws {
        let header = try parse(Self.skill(frontMatter: "decider: required")).get()
        let prompt = ScenePrompt.systemPrompt(for: header)
        XCTAssertTrue(prompt.contains("Read the board into a FEN."))
        XCTAssertTrue(prompt.contains(#""reading""#))
        XCTAssertFalse(prompt.contains(#""control""#))
        let playing = ScenePrompt.systemPrompt(for: try parse(Self.skill()).get())
        XCTAssertTrue(playing.contains("8x8 board"), playing)
        XCTAssertTrue(playing.contains("- none:"), playing)
        XCTAssertTrue(playing.contains(#"exactly one of these names: "board", "none""#),
                      "seen on device: the model answered the kind \"grid\" until the names were listed")
    }

    // MARK: - Step line

    func testAStepNamesItsDecider() {
        let step = SkillParser.parseScene(
            #"{ skill: chess, max_frames: 5, max_tokens: 1000, max_seconds: 60, decider: "/opt/sf.sh --depth 12" }"#)
        guard case .scene(let skill, _, let decider) = step else { return XCTFail("\(step)") }
        XCTAssertEqual(skill, "chess")
        XCTAssertEqual(decider, "/opt/sf.sh --depth 12")
        guard case .invalid = SkillParser.parseScene(
            #"{ skill: chess, max_frames: 5, max_tokens: 1000, max_seconds: 60, decider: "" }"#) else {
            return XCTFail("a blank decider accepted")
        }
    }
}
