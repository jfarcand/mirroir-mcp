// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the text taken from a macOS app's accessibility tree: which nodes are labels, how they merge with pixel readings, how they are listed.
// ABOUTME: The reader is a stub here because the live one talks to another process; the rules come from measurements on Finder, Terminal and Chrome.

import CoreGraphics
import XCTest
import HelperLib
@testable import mirroir_mcp

/// Returns a canned read. The live reader asks another app over Accessibility,
/// which a unit test cannot stage.
final class StubAccessibilityTextReader: AccessibilityTextReading, @unchecked Sendable {
    var result: Result<AccessibilityTextSnapshot, AccessibilityTextUnreadable>
    private(set) var windows: [WindowInfo] = []

    init(_ result: Result<AccessibilityTextSnapshot, AccessibilityTextUnreadable>) {
        self.result = result
    }

    func readText(in window: WindowInfo) -> Result<AccessibilityTextSnapshot, AccessibilityTextUnreadable> {
        windows.append(window)
        return result
    }
}

final class AccessibilityTreeTextTests: XCTestCase {

    private let window = CGSize(width: 1000, height: 800)

    private func node(_ text: String, _ frame: CGRect, role: String = "AXButton",
                      container: Int? = nil) -> AccessibilityTextNode {
        AccessibilityTextNode(text: text, frame: frame, role: role, container: container)
    }

    private func snapshot(_ nodes: [AccessibilityTextNode]) -> AccessibilityTextSnapshot {
        AccessibilityTextSnapshot(nodes: nodes, truncated: false)
    }

    private func pixel(_ text: String, _ x: Double, _ y: Double) -> TapPoint {
        TapPoint(text: text, tapX: x, tapY: y, confidence: 0.9)
    }

    // MARK: - Labels

    func testATapPointIsTheFrameCentreMarkedTree() {
        let points = AccessibilityTreeText.tapPoints(
            from: snapshot([node(" Save ", CGRect(x: 100, y: 20, width: 80, height: 30))]), windowSize: window)
        XCTAssertEqual(points, [TapPoint(text: "Save", tapX: 140, tapY: 35, confidence: 1.0, source: .tree)])
    }

    func testBlankTextEmptyFramesAndOffWindowNodesAreDropped() {
        let points = AccessibilityTreeText.tapPoints(from: snapshot([
            node("  ", CGRect(x: 10, y: 10, width: 50, height: 20)),
            node("Zero", CGRect(x: 10, y: 10, width: 0, height: 20)),
            node("Outside", CGRect(x: 1200, y: 10, width: 50, height: 20)),
            node("Kept", CGRect(x: 10, y: 50, width: 50, height: 20)),
        ]), windowSize: window)
        XCTAssertEqual(points.map(\.text), ["Kept"])
    }

    /// Finder's browser reports "column view" for a frame as large as the
    /// window: the name of a region, drawn nowhere near its centre.
    func testAContainerOfOtherTextIsNotALabel() {
        let points = AccessibilityTreeText.tapPoints(from: snapshot([
            node("column view", CGRect(x: 0, y: 40, width: 900, height: 700), role: "AXBrowser"),
            node("Notes.app", CGRect(x: 36, y: 108, width: 65, height: 17), role: "AXTextField", container: 0),
        ]), windowSize: window)
        XCTAssertEqual(points.map(\.text), ["Notes.app"])
    }

    /// A button and the label inside it are one thing to tap: listed once.
    func testAButtonAndTheLabelInsideItAreListedOnce() {
        let points = AccessibilityTreeText.tapPoints(from: snapshot([
            node("OK", CGRect(x: 100, y: 100, width: 80, height: 30)),
            node("OK", CGRect(x: 120, y: 105, width: 40, height: 20), role: "AXStaticText", container: 0),
        ]), windowSize: window)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.tapX, 140)
    }

    /// Chrome exposes one group, as large as its window, named after the page.
    func testANodeAsLargeAsTheWindowIsTheWindowsOwnLabel() {
        let points = AccessibilityTreeText.tapPoints(
            from: snapshot([node("A page title", CGRect(x: 0, y: 0, width: 1000, height: 800), role: "AXGroup")]),
            windowSize: window)
        XCTAssertEqual(points, [])
    }

    /// Terminal reports its whole scrollback as the value of one text area.
    func testALongOrMultiLineValueIsContentNotALabel() {
        let long = String(repeating: "x", count: AccessibilityTreeText.maxLabelLength + 1)
        let points = AccessibilityTreeText.tapPoints(from: snapshot([
            node(long, CGRect(x: 0, y: 30, width: 600, height: 700), role: "AXTextArea"),
            node("line one\nline two", CGRect(x: 610, y: 30, width: 300, height: 100), role: "AXTextArea"),
            node(String(repeating: "y", count: AccessibilityTreeText.maxLabelLength),
                 CGRect(x: 10, y: 750, width: 500, height: 20)),
        ]), windowSize: window)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.text.first, "y")
    }

    // MARK: - Merge with pixel readings

    func testThePixelCopyOfALabelIsDropped() {
        let merged = AccessibilityTreeText.merge(
            snapshot: snapshot([node("Save", CGRect(x: 100, y: 20, width: 80, height: 30))]),
            pixels: [pixel("Save", 141, 36)], windowSize: window)
        XCTAssertEqual(merged.map(\.source), [.tree])
    }

    /// A misread is still the same text when one reading contains the other.
    func testAPartialPixelReadingOfALabelIsDropped() {
        let merged = AccessibilityTreeText.merge(
            snapshot: snapshot([node("Photo Booth.app", CGRect(x: 36, y: 240, width: 110, height: 17))]),
            pixels: [pixel("Photo Booth", 80, 248)], windowSize: window)
        XCTAssertEqual(merged.map(\.text), ["Photo Booth.app"])
    }

    func testPixelsTheTreeDoesNotReportAreKept() {
        let merged = AccessibilityTreeText.merge(
            snapshot: snapshot([node("Save", CGRect(x: 100, y: 20, width: 80, height: 30))]),
            pixels: [pixel("Recents", 400, 300), pixel("Other", 140, 35)], windowSize: window)
        XCTAssertEqual(merged.map(\.text), ["Save", "Recents", "Other"])
        XCTAssertEqual(merged.map(\.source), [.tree, .pixels, .pixels])
    }

    /// Text inside a region that only has a name of its own keeps its pixel
    /// reading: the region's name is not a label, so it replaces nothing.
    func testPixelsInsideAContainerOrAWindowSizedNodeAreKept() {
        let merged = AccessibilityTreeText.merge(snapshot: snapshot([
            node("Mail - Inbox", CGRect(x: 0, y: 0, width: 1000, height: 800), role: "AXGroup"),
            node(String(repeating: "scrollback ", count: 40), CGRect(x: 0, y: 30, width: 600, height: 700),
                 role: "AXTextArea"),
        ]), pixels: [pixel("Inbox", 300, 200), pixel("scrollback", 100, 100)], windowSize: window)
        XCTAssertEqual(merged.map(\.source), [.pixels, .pixels])
    }

    // MARK: - Decorator

    private func describer(
        _ result: Result<AccessibilityTextSnapshot, AccessibilityTextUnreadable>,
        pixels: [TapPoint]
    ) -> (AccessibilityTreeDescriber, StubDescriber, StubAccessibilityTextReader, StubBridge) {
        let wrapped = StubDescriber()
        wrapped.describeResult = ScreenDescriber.DescribeResult(
            elements: pixels, hints: ["a hint"], screenshotBase64: "abc", ocrTimeMs: 12)
        let bridge = StubBridge()
        bridge.windowInfo = WindowInfo(
            windowID: 7, position: CGPoint(x: 50, y: 60), size: window, pid: 42)
        let reader = StubAccessibilityTextReader(result)
        return (AccessibilityTreeDescriber(wrapping: wrapped, bridge: bridge, reader: reader),
                wrapped, reader, bridge)
    }

    func testTreeTextIsAddedAndEverythingElsePassesThrough() throws {
        let (decorated, wrapped, reader, _) = describer(
            .success(AccessibilityTextSnapshot(
                nodes: [node("Save", CGRect(x: 100, y: 20, width: 80, height: 30))], truncated: true)),
            pixels: [pixel("Save", 140, 35), pixel("Recents", 400, 300)])
        let result = try XCTUnwrap(decorated.describe(settleTimeoutUs: 99))
        XCTAssertEqual(result.elements.map(\.text), ["Save", "Recents"])
        XCTAssertEqual(result.elements.map(\.source), [.tree, .pixels])
        XCTAssertNil(result.treeFailure)
        XCTAssertTrue(result.treeTruncated)
        XCTAssertEqual(result.hints, ["a hint"])
        XCTAssertEqual(result.screenshotBase64, "abc")
        XCTAssertEqual(result.ocrTimeMs, 12)
        XCTAssertEqual(wrapped.lastSettleTimeoutUs, 99)
        XCTAssertEqual(reader.windows.map(\.windowID), [7])
    }

    func testAnUnreadableTreeReturnsThePixelResultWithTheReason() throws {
        let (decorated, _, _, _) = describer(
            .failure(AccessibilityTextUnreadable(reason: "the app did not answer")),
            pixels: [pixel("Save", 140, 35)])
        let result = try XCTUnwrap(decorated.describe(settleTimeoutUs: nil))
        XCTAssertEqual(result.elements.map(\.source), [.pixels])
        XCTAssertEqual(result.treeFailure, "the app did not answer")
    }

    func testWithoutAWindowOrAReadTheWrappedAnswerStands() {
        let (decorated, wrapped, reader, bridge) = describer(
            .success(snapshot([node("Save", CGRect(x: 100, y: 20, width: 80, height: 30))])),
            pixels: [pixel("Save", 140, 35)])
        bridge.windowInfo = nil
        XCTAssertEqual(decorated.describe(settleTimeoutUs: nil)?.elements.map(\.source), [.pixels])
        XCTAssertTrue(reader.windows.isEmpty)
        wrapped.describeResult = nil
        XCTAssertNil(decorated.describe(settleTimeoutUs: nil))
    }

    // MARK: - Listing

    func testOnlyTreeElementsCarryTheMark() {
        let elements = [
            TapPoint(text: "Save", tapX: 140, tapY: 35, confidence: 1, source: .tree),
            pixel("Recents", 400, 300),
        ]
        XCTAssertEqual(DescribeScreenFilter.lines(for: elements, textOnly: false),
                       ["- \"Save\" at (140, 35) [tree]", "- \"Recents\" at (400, 300)"])
        XCTAssertEqual(DescribeScreenFilter.lines(for: elements, textOnly: true),
                       ["- \"Save\" [tree]", "- \"Recents\""])
    }

    /// A screen read from pixels alone, such as every iPhone screen, is
    /// listed exactly as before: no legend, no counts.
    func testAPixelOnlyScreenReadsAsBefore() {
        let elements = [pixel("Recents", 400, 300)]
        XCTAssertEqual(DescribeScreenFilter.header(coordinates: "tap coordinates in points", elements: elements),
                       "Screen elements (tap coordinates in points):")
        XCTAssertEqual(DescribeScreenFilter.sourceCounts(elements, truncated: false), "")
    }

    func testAMixedScreenExplainsTheMarkAndCountsEachSource() {
        let elements = [
            TapPoint(text: "Save", tapX: 140, tapY: 35, confidence: 1, source: .tree),
            pixel("Recents", 400, 300), pixel("Shared", 400, 330),
        ]
        XCTAssertEqual(
            DescribeScreenFilter.header(coordinates: "tap coordinates in points", elements: elements),
            "Screen elements (tap coordinates in points; [tree] = exact text from the macOS "
            + "accessibility tree, unmarked = read from pixels, may misread):")
        XCTAssertEqual(DescribeScreenFilter.sourceCounts(elements, truncated: false),
                       " tree_count=1 pixel_count=2")
        XCTAssertEqual(DescribeScreenFilter.sourceCounts(elements, truncated: true),
                       " tree_count=1 pixel_count=2 tree_truncated=true")
    }

    // MARK: - The source on a tap point

    func testATapPointIsReadFromPixelsUnlessSaidOtherwise() throws {
        let plain = pixel("Recents", 400, 300)
        XCTAssertEqual(plain.source, .pixels)
        let encoded = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("source"),
                       "a pixel reading is saved as it always was")
        XCTAssertEqual(try JSONDecoder().decode(TapPoint.self, from: encoded), plain)

        let exact = TapPoint(text: "Save", tapX: 1, tapY: 2, confidence: 1, source: .tree)
        let roundTrip = try JSONDecoder().decode(TapPoint.self, from: JSONEncoder().encode(exact))
        XCTAssertEqual(roundTrip, exact)
        XCTAssertEqual(roundTrip.source, .tree)
    }

    func testTheSourceSurvivesAScrolledPage() {
        let exact = TapPoint(text: "Save", tapX: 1, tapY: 2, confidence: 1, source: .tree)
        let page = OverlapDeduplicator.merge(
            accumulated: [], newViewport: [exact], cumulativeOffset: 100, viewportOffset: 100,
            windowHeight: 800, strategy: .exact)
        XCTAssertEqual(page.first?.source, .tree)
        XCTAssertEqual(page.first?.pageY, 102)
    }

    // MARK: - Which window

    /// The tabs of a tabbed window share one geometry: the title tells them apart.
    func testAWindowIDIsPickedByTitleAmongWindowsOfOneGeometry() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let list = [
            WindowListEntry(windowID: 1, ownerPID: 9, name: "Recents", bounds: bounds),
            WindowListEntry(windowID: 2, ownerPID: 9, name: "Applications", bounds: bounds),
        ]
        XCTAssertEqual(WindowListHelper.findWindowID(
            pid: 9, position: bounds.origin, size: bounds.size, title: "Applications", in: list), 2)
        XCTAssertEqual(WindowListHelper.findWindowID(
            pid: 9, position: bounds.origin, size: bounds.size, title: "Nowhere", in: list), 1,
            "a title no window carries leaves the first match")
        XCTAssertEqual(WindowListHelper.findWindowID(
            pid: 9, position: bounds.origin, size: bounds.size, in: list), 1)
        XCTAssertNil(WindowListHelper.findWindowID(
            pid: 8, position: bounds.origin, size: bounds.size, title: "Applications", in: list))
    }
}
