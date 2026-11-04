// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: A simulator board of COLSxROWS equal cells and the screen each named cell leads to.
// ABOUTME: Cells are named by screen position: column letter a.. from the left, row number 1.. from the bottom.

import CoreGraphics
import Foundation

/// A tappable board declared on a simulator screen with `- element grid: CxR`
/// and its `- element cell: <name> → <screen>` transitions.
///
/// A cell is named by where it sits on screen, the way a scene skill's grid
/// control names it: the column letter counts from the LEFT (`a` first), the
/// row number from the BOTTOM (`1` first). On a 3x3 board `a1` is the
/// bottom-left cell and `c3` the top-right one. A cell with no transition does
/// nothing when tapped.
public struct SimulatorGrid: Sendable, Equatable {
    /// Most columns a board may declare: one per letter a..z.
    public static let maxColumns = 26
    /// Most rows a board may declare: row numbers 1..99.
    public static let maxRows = 99

    /// Number of columns, 1...`maxColumns`.
    public let columns: Int
    /// Number of rows, 1...`maxRows`.
    public let rows: Int
    /// Destination screen ID per lowercased cell name. Cells absent here do nothing.
    public let transitions: [String: String]

    /// A board of `columns` x `rows` cells, or nil when either count is out of
    /// range or a transition names a cell the board does not have.
    public init?(columns: Int, rows: Int, transitions: [String: String] = [:]) {
        guard (1...Self.maxColumns).contains(columns),
              (1...Self.maxRows).contains(rows) else { return nil }
        guard transitions.keys.allSatisfy({
            Self.isCell($0, columns: columns, rows: rows)
        }) else { return nil }
        self.columns = columns
        self.rows = rows
        self.transitions = Dictionary(
            transitions.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last })
    }

    /// Parse a `CxR` size (`3x3`, `8X8`) into a board with no transitions.
    public init?(size raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let cols = Int(parts[0]), let rows = Int(parts[1]) else {
            return nil
        }
        self.init(columns: cols, rows: rows)
    }

    /// The same board with `name` leading to `screenID`, or nil when the
    /// board has no such cell.
    public func adding(cell name: String, leadsTo screenID: String) -> SimulatorGrid? {
        var updated = transitions
        updated[name.lowercased()] = screenID
        return SimulatorGrid(columns: columns, rows: rows, transitions: updated)
    }

    /// The screen tapping cell `name` leads to, or nil when it does nothing.
    public func destination(of name: String) -> String? {
        transitions[name.lowercased()]
    }

    /// Whether `name` is a cell of this board (`a1` ... last letter + `rows`).
    public func contains(cell name: String) -> Bool {
        Self.isCell(name, columns: columns, rows: rows)
    }

    private static func isCell(_ name: String, columns: Int, rows: Int) -> Bool {
        guard let position = position(of: name) else { return false }
        return position.column < columns && position.row <= rows
    }

    /// The name of the cell at 0-based `column` (from the left) and 1-based
    /// `row` (from the bottom).
    public static func name(column: Int, row: Int) -> String {
        let letter = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(column)))
        return "\(letter)\(row)"
    }

    /// Split a cell name into its 0-based column (from the left) and 1-based
    /// row (from the bottom), or nil when it is not a letter followed by a
    /// row number in 1...`maxRows`.
    public static func position(of name: String) -> (column: Int, row: Int)? {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let letter = lowered.unicodeScalars.first,
              ("a"..."z").contains(letter) else { return nil }
        let digits = lowered.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.first != "0",
              let row = Int(digits), (1...maxRows).contains(row) else { return nil }
        return (Int(letter.value - UnicodeScalar("a").value), row)
    }

    /// The rect of cell `name` inside `board`, in a top-down (flipped)
    /// coordinate system, or nil when the board has no such cell.
    public func rect(of name: String, in board: CGRect) -> CGRect? {
        guard contains(cell: name), let position = Self.position(of: name) else { return nil }
        let width = board.width / CGFloat(columns)
        let height = board.height / CGFloat(rows)
        return CGRect(
            x: board.minX + CGFloat(position.column) * width,
            y: board.maxY - CGFloat(position.row) * height,
            width: width, height: height)
    }

    /// The cell under `point` on `board` (top-down coordinates), or nil when
    /// the point is off the board.
    public func cell(at point: CGPoint, in board: CGRect) -> String? {
        guard board.contains(point) else { return nil }
        let column = Int((point.x - board.minX) / (board.width / CGFloat(columns)))
        let rowFromTop = Int((point.y - board.minY) / (board.height / CGFloat(rows)))
        let row = rows - min(rowFromTop, rows - 1)
        return Self.name(column: min(column, columns - 1), row: row)
    }
}
