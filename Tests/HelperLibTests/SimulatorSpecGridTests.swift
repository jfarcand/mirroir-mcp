// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the simulator board: `- element grid: CxR` and `- element cell: <name> → <screen>`.
// ABOUTME: Covers size limits, screen-position cell naming (a1 bottom-left), transitions and cell geometry.

import CoreGraphics
import XCTest
@testable import HelperLib

final class SimulatorSpecGridTests: XCTestCase {

    private func screen(_ body: String) -> SimulatorScreen? {
        SimulatorSpecParser.parse(
            sections: ["Simulator Screen g1": body],
            frontMatter: ["app": "Grid Frames"],
            appName: "Grid Frames"
        )?.screens["g1"]
    }

    private func grid(_ body: String) -> SimulatorGrid? {
        for element in screen(body)?.elements ?? [] {
            if case .grid(let grid) = element { return grid }
        }
        return nil
    }

    // MARK: - Sizes

    func testParsesGridSizes() {
        XCTAssertEqual(grid("- element grid: 3x3").map { [$0.columns, $0.rows] }, [3, 3])
        XCTAssertEqual(grid("- element grid: 8X8").map { [$0.columns, $0.rows] }, [8, 8])
        XCTAssertEqual(grid("- element grid: 1x1").map { [$0.columns, $0.rows] }, [1, 1])
        XCTAssertEqual(grid("- element grid: 26x99").map { [$0.columns, $0.rows] }, [26, 99])
        XCTAssertEqual(grid("- element grid: 7x2").map { [$0.columns, $0.rows] }, [7, 2])
    }

    func testRefusesBadGridSizes() {
        for size in ["0x3", "3x0", "27x3", "3x100", "3x", "x3", "3", "abc", "3x3x3", "-3x3"] {
            XCTAssertNil(grid("- element grid: \(size)"), "size \(size) should be refused")
            XCTAssertEqual(screen("- element grid: \(size)")?.elements, [], size)
        }
    }

    func testKeepsOnlyTheFirstGridOfAScreen() {
        let elements = screen("""
            - element grid: 3x3
            - element grid: 8x8
            """)?.elements
        XCTAssertEqual(elements?.count, 1)
        XCTAssertEqual(grid("- element grid: 3x3\n- element grid: 8x8")?.columns, 3)
    }

    // MARK: - Cells and transitions

    func testParsesCellTransitions() {
        let board = grid("""
            - title: Pick a square
            - element grid: 3x3
            - element cell: a1 → g2
            - element cell: C3 -> goal
            """)
        XCTAssertEqual(board?.transitions, ["a1": "g2", "c3": "goal"])
        XCTAssertEqual(board?.destination(of: "a1"), "g2")
        XCTAssertEqual(board?.destination(of: "C3"), "goal")
        XCTAssertNil(board?.destination(of: "b2"), "a cell with no transition does nothing")
    }

    func testCellLinesMayPrecedeTheGrid() {
        let board = grid("""
            - element cell: b2 → lose
            - element grid: 3x3
            """)
        XCTAssertEqual(board?.transitions, ["b2": "lose"])
    }

    func testDropsCellsTheGridDoesNotHave() {
        let board = grid("""
            - element grid: 3x3
            - element cell: d1 → lose
            - element cell: a4 → lose
            - element cell: a0 → lose
            - element cell: 1a → lose
            - element cell: aa1 → lose
            - element cell: a01 → lose
            - element cell: a1 → g2
            """)
        XCTAssertEqual(board?.transitions, ["a1": "g2"])
    }

    func testDropsCellsWithoutDestinationOrGrid() {
        XCTAssertEqual(grid("- element grid: 3x3\n- element cell: a1")?.transitions, [:])
        XCTAssertEqual(screen("- element cell: a1 → g2")?.elements, [])
    }

    func testGridIsNotATextElement() {
        let element = SimulatorElement.grid(SimulatorGrid(columns: 3, rows: 3)!)
        XCTAssertEqual(element.displayText, "")
        XCTAssertNil(element.leadsTo)
    }

    func testRefusesTransitionsOffTheGrid() {
        XCTAssertNil(SimulatorGrid(columns: 3, rows: 3, transitions: ["d4": "x"]))
        XCTAssertNil(SimulatorGrid(columns: 3, rows: 3)?.adding(cell: "c4", leadsTo: "x"))
        XCTAssertNotNil(SimulatorGrid(columns: 3, rows: 3)?.adding(cell: "c3", leadsTo: "x"))
    }

    // MARK: - Naming

    func testCellNamesCountColumnsFromTheLeftAndRowsFromTheBottom() {
        XCTAssertEqual(SimulatorGrid.name(column: 0, row: 1), "a1")
        XCTAssertEqual(SimulatorGrid.name(column: 2, row: 3), "c3")
        XCTAssertEqual(SimulatorGrid.name(column: 25, row: 99), "z99")
        XCTAssertEqual(SimulatorGrid.position(of: "e4").map { [$0.column, $0.row] }, [4, 4])
        XCTAssertNil(SimulatorGrid.position(of: "a100"))
        XCTAssertNil(SimulatorGrid.position(of: "é1"))
        XCTAssertNil(SimulatorGrid.position(of: ""))
    }

    // MARK: - Geometry (top-down coordinates)

    func testCellRectsPutA1BottomLeft() throws {
        let board = try XCTUnwrap(SimulatorGrid(columns: 3, rows: 3))
        let rect = CGRect(x: 55, y: 200, width: 300, height: 300)
        XCTAssertEqual(board.rect(of: "a1", in: rect), CGRect(x: 55, y: 400, width: 100, height: 100))
        XCTAssertEqual(board.rect(of: "c3", in: rect), CGRect(x: 255, y: 200, width: 100, height: 100))
        XCTAssertEqual(board.rect(of: "b2", in: rect), CGRect(x: 155, y: 300, width: 100, height: 100))
        XCTAssertNil(board.rect(of: "d1", in: rect))
    }

    func testCellAtPointInvertsTheCellRects() throws {
        let board = try XCTUnwrap(SimulatorGrid(columns: 8, rows: 8))
        let rect = CGRect(x: 10, y: 20, width: 320, height: 320)
        for column in 0..<8 {
            for row in 1...8 {
                let name = SimulatorGrid.name(column: column, row: row)
                let cell = try XCTUnwrap(board.rect(of: name, in: rect))
                XCTAssertEqual(board.cell(at: CGPoint(x: cell.midX, y: cell.midY), in: rect), name)
            }
        }
        XCTAssertEqual(board.cell(at: CGPoint(x: 10, y: 339.9), in: rect), "a1")
        XCTAssertNil(board.cell(at: CGPoint(x: 9, y: 100), in: rect))
        XCTAssertNil(board.cell(at: CGPoint(x: 100, y: 340), in: rect))
    }
}
