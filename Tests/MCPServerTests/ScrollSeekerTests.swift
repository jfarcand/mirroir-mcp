// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the scroll seeker: when it declares the end of the content, what it ignores, and where it swipes.
// ABOUTME: Covers the band-of-rows pixel comparison it uses for content with no text.

import CoreGraphics
import ImageIO
import XCTest
import HelperLib
@testable import mirroir_mcp

/// A 20x100 PNG, grey, with coloured stripes at the given fractions of its
/// height. Fractions are symmetric about the middle in these tests, so the
/// drawing origin (bottom-left) and the row order (top first) agree.
private func stripedPNG(_ stripes: [ClosedRange<Double>]) -> Data? {
    let width = 20, height = 100
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    for stripe in stripes {
        context.fill(CGRect(x: 0, y: stripe.lowerBound * Double(height), width: Double(width),
                            height: (stripe.upperBound - stripe.lowerBound) * Double(height)))
    }
    let data = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(
              data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

final class ScrollSeekerTests: XCTestCase {

    /// The iPhone's portrait content band.
    private let band: ClosedRange<Double> = 0.10 ... 0.95
    private var bridge: StubBridge!
    private var input: StubInput!
    private var describer: StubDescriber!

    override func setUp() {
        super.setUp()
        bridge = StubBridge()
        input = StubInput()
        describer = StubDescriber()
    }

    /// A read with `texts` in the content band and `status` in the status bar.
    private func read(_ texts: [String], status: String? = nil, frame: Data? = nil) -> ScreenDescriber.DescribeResult {
        var elements = texts.map { TapPoint(text: $0, tapX: 100, tapY: 400, confidence: 0.95) }
        if let status { elements.append(TapPoint(text: status, tapX: 60, tapY: 60, confidence: 0.95)) }
        return ScreenDescriber.DescribeResult(
            elements: elements, screenshotBase64: frame?.base64EncodedString() ?? "")
    }

    private func seek(
        _ label: String = "Target", direction: ScrollDirection = .down, maxScrolls: Int = 10,
        confirmations: Int = 2
    ) -> ScrollSeekOutcome {
        ScrollSeeker.seek(
            label: label, toward: direction, maxScrolls: maxScrolls, anchor: nil,
            band: band, bridge: bridge, input: input, describer: describer,
            settleUs: 123, confirmations: confirmations)
    }

    // MARK: - Finding

    func testALabelAlreadyOnScreenNeedsNoScroll() {
        describer.describeResults = [read(["A", "Target"])]
        XCTAssertEqual(seek(), .alreadyVisible)
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    func testOneUnchangedReadIsNotTheEnd() {
        describer.describeResults = [read(["A"]), read(["A"]), read(["A", "Target"])]
        XCTAssertEqual(seek(), .found(scrolls: 2))
        XCTAssertEqual(input.swipeCalls.count, 2)
    }

    // MARK: - Pictures under a label that stays put

    /// A photo grid under a pinned "Select" button: the text never changes, the
    /// pictures do. That is movement, not the end.
    func testPicturesMovingUnderFixedTextAreMovement() throws {
        let top = try XCTUnwrap(stripedPNG([0.2 ... 0.3, 0.7 ... 0.8]))
        let middle = try XCTUnwrap(stripedPNG([0.3 ... 0.4, 0.6 ... 0.7]))
        let bottom = try XCTUnwrap(stripedPNG([0.4 ... 0.45, 0.55 ... 0.6]))
        describer.describeResults = [
            read(["Select"], frame: top),
            read(["Select"], frame: middle),     // after scroll 1: same text, other pixels
            read(["Select"], frame: middle),     // the check at rest: nothing moved by itself
            read(["Select"], frame: bottom),     // after scroll 2: still moving, no second check
            read(["Select", "Target"], frame: bottom),
        ]
        XCTAssertEqual(seek(), .found(scrolls: 3))
        XCTAssertEqual(describer.describeCallCount, 5, "the screen is checked at rest once, not per scroll")
    }

    func testPicturesThatStopUnderFixedTextAreTheEnd() throws {
        let top = try XCTUnwrap(stripedPNG([0.2 ... 0.3, 0.7 ... 0.8]))
        let end = try XCTUnwrap(stripedPNG([0.4 ... 0.45, 0.55 ... 0.6]))
        describer.describeResults = [
            read(["Select"], frame: top), read(["Select"], frame: end), read(["Select"], frame: end),
            read(["Select"], frame: end), read(["Select"], frame: end),
        ]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 3))
    }

    /// A screen whose background animates while nothing is touched: pixels say
    /// nothing there, so the text decides, as it does without frames.
    func testAScreenThatAnimatesAtRestIsJudgedByItsText() throws {
        let frames = try [[0.2 ... 0.3], [0.3 ... 0.4], [0.4 ... 0.5], [0.5 ... 0.6], [0.6 ... 0.7]]
            .map { try XCTUnwrap(stripedPNG($0 + [1 - $0[0].upperBound ... 1 - $0[0].lowerBound])) }
        describer.describeResults = [
            read(["Montréal 4°"], frame: frames[0]),
            read(["Montréal 4°"], frame: frames[1]),   // after scroll 1
            read(["Montréal 4°"], frame: frames[2]),   // at rest, and it changed anyway
            read(["Montréal 4°"], frame: frames[3]),   // after scroll 2
        ]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 2))
    }

    func testNoScrollBudgetMeansNoSwipe() {
        describer.describeResults = [read(["A"])]
        for budget in [0, -3] {
            XCTAssertEqual(seek(maxScrolls: budget), .stopped(.maxScrolls, scrolls: 0))
        }
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    // MARK: - The end of the content

    func testTwoUnchangedReadsDeclareTheEnd() {
        describer.describeResults = [read(["A"]), read(["B"]), read(["B"]), read(["B"])]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 3))
    }

    func testTheFirstScrollIsComparedWithThePreScrollRead() {
        describer.describeResults = [read(["A"]), read(["A"]), read(["A"])]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 2))
        XCTAssertEqual(input.swipeCalls.count, 2)
    }

    /// The clock ticking over in the status bar is not the content moving.
    func testAStatusBarClockChangeIsNotMovement() {
        describer.describeResults = [
            read(["A"], status: "9:41"), read(["A"], status: "9:42"), read(["A"], status: "9:43"),
        ]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 2))
    }

    func testContentThatKeepsMovingEndsOnTheBudget() {
        describer.describeResults = (0 ... 4).map { read(["Page \($0)"]) }
        XCTAssertEqual(seek(maxScrolls: 3), .stopped(.maxScrolls, scrolls: 3))
        XCTAssertEqual(input.swipeCalls.count, 3)
    }

    func testTheNumberOfConfirmationsIsHonoured() {
        describer.describeResults = [read(["A"])]
        XCTAssertEqual(seek(confirmations: 4), .stopped(.endOfContent, scrolls: 4))
        XCTAssertEqual(TimingConstants.scrollEndConfirmations, 2)
        XCTAssertEqual(EnvConfig.scrollEndConfirmations, TimingConstants.scrollEndConfirmations)
    }

    // MARK: - Content with no text

    /// An image grid has no text: it has not ended just because two reads are both empty.
    func testTextLessFramesThatMovedAreNotTheEnd() throws {
        let a = try XCTUnwrap(stripedPNG([0.40 ... 0.60]))
        let b = try XCTUnwrap(stripedPNG([0.30 ... 0.70]))
        describer.describeResults = [read([], frame: a), read([], frame: b), read([], frame: a)]
        XCTAssertEqual(seek(maxScrolls: 2), .stopped(.maxScrolls, scrolls: 2))
    }

    func testTextLessIdenticalFramesDeclareTheEnd() throws {
        let frame = try XCTUnwrap(stripedPNG([0.40 ... 0.60]))
        describer.describeResults = [read([], frame: frame)]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 2))
    }

    func testTextLessFramesDifferingOnlyOutsideTheBandAreTheEnd() throws {
        let plain = try XCTUnwrap(stripedPNG([]))
        let edges = try XCTUnwrap(stripedPNG([0.0 ... 0.04, 0.96 ... 1.0]))
        describer.describeResults = [read([], frame: plain), read([], frame: edges), read([], frame: plain)]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 2))
    }

    /// Frames that cannot be compared are never taken for the same.
    func testTextLessFramesThatCannotBeComparedEndOnTheBudget() {
        describer.describeResults = [read([])]
        XCTAssertEqual(seek(maxScrolls: 3), .stopped(.maxScrolls, scrolls: 3))
    }

    // MARK: - Reading and failing

    func testReadsAskForASettledFrame() {
        describer.describeResults = [read(["Target"])]
        _ = seek()
        XCTAssertEqual(describer.lastSettleTimeoutUs, 123)
    }

    func testAFailedReadAfterAScrollFails() {
        describer.describeResults = [read(["A"]), nil]
        XCTAssertEqual(seek(), .failed("Could not read the screen after scroll 1"))
    }

    func testASwipeErrorIsReturned() {
        describer.describeResults = [read(["A"])]
        input.swipeResult = "blocked"
        XCTAssertEqual(seek(), .failed("Swipe failed: blocked"))
    }

    // MARK: - Direction

    /// The direction names the content wanted; the finger goes the other way.
    func testEachDirectionMovesTheFingerTheOppositeWay() {
        XCTAssertEqual(ScrollDirection.down.fingerDirection, "up")
        XCTAssertEqual(ScrollDirection.up.fingerDirection, "down")
        XCTAssertEqual(ScrollDirection.right.fingerDirection, "left")
        XCTAssertEqual(ScrollDirection.left.fingerDirection, "right")
        XCTAssertEqual(ScrollDirection.allCases.map(\.rawValue), ["down", "up", "left", "right"])
        XCTAssertEqual(ScrollDirection.names, "down/up/left/right")
    }

    func testSeekingDownSwipesTheFingerUp() {
        describer.describeResults = [read(["A"]), read(["A", "Target"])]
        XCTAssertEqual(seek(direction: .down), .found(scrolls: 1))
        let swipe = input.swipeCalls[0]
        XCTAssertGreaterThan(swipe.fromY, swipe.toY, "the finger moves up, so the content below comes in")
    }

    func testSeekingUpAndSidewaysSwipesTheOtherWay() {
        for (direction, check) in [
            (ScrollDirection.up, { (s: SwipeCall) in s.fromY < s.toY }),
            (.right, { (s: SwipeCall) in s.fromX > s.toX }),
            (.left, { (s: SwipeCall) in s.fromX < s.toX }),
        ] {
            input.swipeCalls = []
            describer = StubDescriber()
            describer.describeResults = [read(["A"]), read(["A", "Target"])]
            XCTAssertEqual(seek(direction: direction), .found(scrolls: 1))
            XCTAssertTrue(check(input.swipeCalls[0]), direction.rawValue)
        }
    }

    func testWithoutAWindowTheSeekFails() {
        describer.describeResults = [read(["A"])]
        bridge.windowInfo = nil
        XCTAssertEqual(seek(), .failed("Could not get window info for scroll"))
    }

    // MARK: - Geometry

    private let window = CGSize(width: 410, height: 898)

    func testFingerUpStartsLowAndEndsHigh() throws {
        let swipe = try XCTUnwrap(ScrollSeeker.endpoints(fingerDirection: "up", window: window, around: nil))
        XCTAssertEqual(swipe.fromX, 205)
        XCTAssertEqual(swipe.toX, 205)
        XCTAssertGreaterThan(swipe.fromY, swipe.toY)
        XCTAssertEqual((swipe.fromY + swipe.toY) / 2, 449, accuracy: 0.001)
        XCTAssertEqual(swipe.fromY - swipe.toY, 898 * EnvConfig.swipeDistanceFraction, accuracy: 0.001)
    }

    func testEachFingerDirection() throws {
        let down = try XCTUnwrap(ScrollSeeker.endpoints(fingerDirection: "down", window: window, around: nil))
        XCTAssertLessThan(down.fromY, down.toY)
        let left = try XCTUnwrap(ScrollSeeker.endpoints(fingerDirection: "LEFT", window: window, around: nil))
        XCTAssertGreaterThan(left.fromX, left.toX)
        XCTAssertEqual(left.fromY, 449)
        let right = try XCTUnwrap(ScrollSeeker.endpoints(fingerDirection: "right", window: window, around: nil))
        XCTAssertLessThan(right.fromX, right.toX)
        XCTAssertNil(ScrollSeeker.endpoints(fingerDirection: "sideways", window: window, around: nil))
    }

    func testAnAnchorCentresTheSwipe() throws {
        let anchor = CGPoint(x: 100, y: 500)
        let swipe = try XCTUnwrap(ScrollSeeker.endpoints(fingerDirection: "up", window: window, around: anchor))
        XCTAssertEqual(swipe.fromX, 100)
        XCTAssertEqual((swipe.fromY + swipe.toY) / 2, 500, accuracy: 0.001)
    }

    func testAnAnchorNearAnEdgeKeepsTheSwipeInsideTheWindow() throws {
        let length = 898 * EnvConfig.swipeDistanceFraction
        for anchor in [CGPoint(x: 5, y: 10), CGPoint(x: 405, y: 890)] {
            for direction in ["up", "down", "left", "right"] {
                let swipe = try XCTUnwrap(ScrollSeeker.endpoints(
                    fingerDirection: direction, window: window, around: anchor))
                for x in [swipe.fromX, swipe.toX] { XCTAssertTrue((0 ... 410).contains(x), "\(direction) x \(x)") }
                for y in [swipe.fromY, swipe.toY] { XCTAssertTrue((0 ... 898).contains(y), "\(direction) y \(y)") }
            }
            let vertical = try XCTUnwrap(ScrollSeeker.endpoints(fingerDirection: "up", window: window, around: anchor))
            XCTAssertEqual(abs(vertical.fromY - vertical.toY), length, accuracy: 0.001, "the length is kept")
        }
    }

    func testTheBandLeavesOutTheStatusBarAndTheBottomSafeZone() {
        let portrait = ScrollSeeker.band(for: IPhoneMirroringTarget.profile, orientation: .portrait)
        let zones = IPhoneMirroringTarget.profile.layoutZones(.portrait)
        XCTAssertEqual(portrait.lowerBound, zones.statusBarZoneFraction)
        XCTAssertEqual(portrait.upperBound, zones.safeZone.maxTapYFraction)
        XCTAssertFalse(portrait.contains(0.02))
        XCTAssertTrue(portrait.contains(0.5))
        XCTAssertFalse(portrait.contains(0.99))
    }

    func testContentTextsKeepsOnlyTheBandAndDropsDetectorIcons() {
        let elements = [
            TapPoint(text: "9:41", tapX: 60, tapY: 60, confidence: 1),
            TapPoint(text: "Zebra", tapX: 100, tapY: 300, confidence: 1),
            TapPoint(text: "icon", tapX: 300, tapY: 300, confidence: 1),
            TapPoint(text: "Apple", tapX: 100, tapY: 500, confidence: 1),
            TapPoint(text: "Home", tapX: 200, tapY: 880, confidence: 1),
        ]
        XCTAssertEqual(ScrollSeeker.contentTexts(elements, windowHeight: 898, band: band).map(\.text),
                       ["Zebra", "Apple"])
    }

    // MARK: - A screen at rest never reads the same twice

    /// Twenty rows of text, as OCR lists them on one read.
    private func rows(_ count: Int = 20, shiftedBy dy: Double = 0, prefix: String = "Row") -> [TapPoint] {
        (0..<count).map { TapPoint(text: "\(prefix) \($0)", tapX: 100, tapY: 150 + Double($0) * 35 + dy, confidence: 0.9) }
    }

    private func read(elements: [TapPoint]) -> ScreenDescriber.DescribeResult {
        ScreenDescriber.DescribeResult(elements: elements, screenshotBase64: "")
    }

    /// What the iPhone XR gave in Weather at rest on 2026-11-09: a text read
    /// differently ("7°" as "7º"), a stray character, icons that come and go,
    /// and every position off by a point.
    func testReadsOfAScreenAtRestCountAsUnchanged() {
        var first = rows()
        first[3] = TapPoint(text: "7° | Température ressentie : 0°", tapX: 100, tapY: 255, confidence: 0.9)
        var second = rows(shiftedBy: 1.5)
        second[3] = TapPoint(text: "7º | Température ressentie : 0°", tapX: 101, tapY: 256, confidence: 0.9)
        second.append(TapPoint(text: "1", tapX: 169, tapY: 700, confidence: 0.4))
        second.append(TapPoint(text: "icon", tapX: 173, tapY: 706, confidence: 0.6))
        let moving = rows(shiftedBy: -300)
        describer.describeResults = [
            read(elements: moving), read(elements: first), read(elements: second), read(elements: first),
        ]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 3))
    }

    /// What the iPhone XR did at the bottom of Weather on 2026-11-09: pushed
    /// past its end, the page is still pulled up on every second read, by a
    /// different amount each time, and at rest on the reads between.
    func testContentThatSpringsBackAndForthAtItsEndIsTheEnd() {
        let atRest = rows()
        describer.describeResults = [
            read(elements: atRest),                     // before any scroll
            read(elements: rows(shiftedBy: -74)),       // scroll 1: pulled past the end
            read(elements: rows(shiftedBy: 1)),         // scroll 2: at rest, as before the scrolls
            read(elements: rows(shiftedBy: -40)),       // scroll 3: pulled, by another amount
            read(elements: atRest),                     // scroll 4: at rest, as on two earlier reads
            read(elements: rows(shiftedBy: -500)),
        ]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 4))
    }

    /// One read that agrees with an earlier one is not the end: here the
    /// content is seen where it stood once, then goes on.
    func testOneReturnToAnEarlierPlaceIsNotTheEnd() {
        describer.describeResults = [
            read(elements: rows()), read(elements: rows(shiftedBy: -74)), read(elements: rows()),
            read(elements: rows(shiftedBy: -200)), read(elements: rows(shiftedBy: -400)),
            read(elements: rows(shiftedBy: -600)),
        ]
        XCTAssertEqual(seek(maxScrolls: 5), .stopped(.maxScrolls, scrolls: 5))
    }

    /// A list that keeps advancing never returns to a place it showed.
    func testContentThatKeepsAdvancingNeverLooksRevisited() {
        describer.describeResults = (0..<9).map { read(elements: rows(shiftedBy: Double($0) * -90)) }
        XCTAssertEqual(seek(maxScrolls: 8), .stopped(.maxScrolls, scrolls: 8))
    }

    /// A scroll under a pinned header: the header stays, the list does not.
    func testAScrollUnderAPinnedHeaderIsMovement() {
        let header = [
            TapPoint(text: "Prévost", tapX: 215, tapY: 110, confidence: 0.9),
            TapPoint(text: "7° | Nuageux", tapX: 215, tapY: 130, confidence: 0.9),
        ]
        describer.describeResults = (0..<5).map { read(elements: header + rows(shiftedBy: Double($0) * -120)) }
        XCTAssertEqual(seek(maxScrolls: 4), .stopped(.maxScrolls, scrolls: 4))
    }

    /// Rows that all read the same still moved when none sits where one sat.
    func testIdenticalRowsThatShiftAreMovement() {
        func list(_ dy: Double) -> [TapPoint] {
            (0..<12).map { TapPoint(text: "1 document numérisé", tapX: 176, tapY: 150 + Double($0) * 60 + dy, confidence: 0.9) }
        }
        describer.describeResults = [read(elements: list(0)), read(elements: list(-25)), read(elements: list(-50)),
                                     read(elements: list(-75))]
        XCTAssertEqual(seek(maxScrolls: 3), .stopped(.maxScrolls, scrolls: 3))
    }

    /// The same city row read on four frames of the iPhone XR, 2026-11-09.
    func testSymbolsOCRReadsDifferentlyDoNotMakeATextDifferent() {
        XCTAssertEqual(ScrollSeeker.comparable("1 8° \\ 3°"), ScrollSeeker.comparable("1 8° ₺ 3°"))
        XCTAssertEqual(ScrollSeeker.comparable("7º | Température ressentie : 0°"),
                       ScrollSeeker.comparable("7° | Température ressentie : 0°"))
        XCTAssertEqual(ScrollSeeker.comparable("® PRESSION"), ScrollSeeker.comparable("PRESSION"))
        XCTAssertNotEqual(ScrollSeeker.comparable("Montréal"), ScrollSeeker.comparable("Québec"))
        XCTAssertEqual(ScrollSeeker.comparable("•"), "")

        let first = [TapPoint(text: "1 8° \\ 3°", tapX: 82, tapY: 255, confidence: 0.9),
                     TapPoint(text: "Montréal", tapX: 80, tapY: 400, confidence: 0.9)]
        let second = [TapPoint(text: "1 8° ₺ 3°", tapX: 83, tapY: 256, confidence: 0.9),
                      TapPoint(text: "MONTREAL", tapX: 80, tapY: 401, confidence: 0.9)]
        XCTAssertEqual(ScrollSeeker.shareInPlace(first, second, tolerance: 4), 1)
    }

    /// The city list of Weather at its end, as measured: every second read is
    /// the same place, and a quarter of its text is read differently each time.
    func testAListWhoseTextIsReadDifferentlyEachTimeStillEnds() {
        func cities(_ dy: Double, misread: Set<Int>) -> [TapPoint] {
            (0..<20).map {
                TapPoint(text: misread.contains($0) ? "X\($0)?" : "City \($0)", tapX: 80,
                         tapY: 150 + Double($0) * 35 + dy, confidence: 0.9)
            }
        }
        describer.describeResults = [
            read(elements: cities(200, misread: [])),
            read(elements: cities(-70, misread: [1, 5])),            // scroll 1: pulled past the end
            read(elements: cities(0, misread: [2, 6, 9, 13, 17])),   // scroll 2: the end, at rest
            read(elements: cities(-55, misread: [3])),               // scroll 3: pulled
            read(elements: cities(0, misread: [0, 4, 8, 12])),       // scroll 4: at rest, 55% shared with scroll 2
            read(elements: cities(-62, misread: [7])),               // scroll 5: pulled
            read(elements: cities(1, misread: [10, 14])),            // scroll 6: at rest again
        ]
        XCTAssertEqual(seek(), .stopped(.endOfContent, scrolls: 6))
    }

    func testShareInPlace() {
        let tolerance = 4.0
        XCTAssertEqual(ScrollSeeker.shareInPlace([], [], tolerance: tolerance), 1)
        XCTAssertEqual(ScrollSeeker.shareInPlace(rows(), [], tolerance: tolerance), 0)
        XCTAssertEqual(ScrollSeeker.shareInPlace(rows(), rows(shiftedBy: 3), tolerance: tolerance), 1)
        XCTAssertEqual(ScrollSeeker.shareInPlace(rows(), rows(shiftedBy: 6), tolerance: tolerance), 0)
        XCTAssertEqual(ScrollSeeker.shareInPlace(rows(10), rows(20), tolerance: tolerance), 0.5,
                       "out of the larger read, so text that appeared counts as change")
    }

    // MARK: - Wording

    func testToolReplies() {
        XCTAssertEqual(ScrollSeekOutcome.alreadyVisible.toolReply(label: "X").text, "'X' is already visible on screen")
        XCTAssertEqual(ScrollSeekOutcome.found(scrolls: 2).toolReply(label: "X").text, "Found 'X' after 2 scroll(s)")
        let end = ScrollSeekOutcome.stopped(.endOfContent, scrolls: 4).toolReply(label: "X")
        XCTAssertEqual(end.text, "'X' not found: the content stopped moving after 4 scroll(s) (stop_reason=end_of_content)")
        XCTAssertTrue(end.isError)
        XCTAssertEqual(ScrollSeekOutcome.stopped(.maxScrolls, scrolls: 10).toolReply(label: "X").text,
                       "'X' not found after 10 scroll(s) (stop_reason=max_scrolls)")
        XCTAssertFalse(ScrollSeekOutcome.found(scrolls: 1).toolReply(label: "X").isError)
    }

    /// `compile` reads the scroll count back out of "found after N scroll(s)".
    func testStepResultsKeepTheScrollCountWording() {
        XCTAssertEqual(ScrollSeekOutcome.found(scrolls: 2).stepResult.message, "found after 2 scroll(s)")
        XCTAssertTrue(ScrollSeekOutcome.found(scrolls: 2).stepResult.passed)
        XCTAssertEqual(ScrollSeekOutcome.alreadyVisible.stepResult.message, "already visible")
        XCTAssertEqual(ScrollSeekOutcome.stopped(.endOfContent, scrolls: 3).stepResult.message,
                       "Content stopped moving after 3 scroll(s) (end_of_content)")
        XCTAssertFalse(ScrollSeekOutcome.stopped(.maxScrolls, scrolls: 3).stepResult.passed)
    }
}

final class FrameRowsTests: XCTestCase {

    private let band: ClosedRange<Double> = 0.10 ... 0.95

    func testSameRowsIgnoresAChangeOutsideTheBand() throws {
        let plain = try XCTUnwrap(stripedPNG([]))
        let edges = try XCTUnwrap(stripedPNG([0.0 ... 0.04, 0.96 ... 1.0]))
        XCTAssertTrue(FrameFingerprint.sameRows(plain, edges, band: band))
        XCTAssertFalse(FrameFingerprint.sameContent(plain, edges), "the whole frames do differ")
    }

    func testSameRowsSeesAChangeInsideTheBand() throws {
        let plain = try XCTUnwrap(stripedPNG([]))
        let middle = try XCTUnwrap(stripedPNG([0.45 ... 0.55]))
        XCTAssertFalse(FrameFingerprint.sameRows(plain, middle, band: band))
    }

    func testSameRowsIsFalseForFramesThatCannotBeCompared() throws {
        let plain = try XCTUnwrap(stripedPNG([]))
        XCTAssertFalse(FrameFingerprint.sameRows(plain, Data([1, 2, 3]), band: band))
        XCTAssertFalse(FrameFingerprint.sameRows(Data(), Data(), band: band))
    }
}
