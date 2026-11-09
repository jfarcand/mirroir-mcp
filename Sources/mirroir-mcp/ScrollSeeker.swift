// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Scrolls until a label is on screen, and tells the end of the content from a scroll that simply has not arrived yet.
// ABOUTME: One loop for the scroll_to tool and the scroll_to step, with the swipe geometry both share with swipe.

import CoreGraphics
import Foundation
import HelperLib

/// Where the content to reveal lies. The finger moves the opposite way:
/// `down` shows what is further down the page, with the finger moving up.
///
/// `scroll_to` is named by what the caller wants to see. `swipe` is the only
/// verb named by the finger's motion.
enum ScrollDirection: String, CaseIterable, Sendable {
    case down, up, left, right

    /// The direction `swipe` takes to reveal content on this side.
    var fingerDirection: String {
        switch self {
        case .down: return "up"
        case .up: return "down"
        case .right: return "left"
        case .left: return "right"
        }
    }

    /// The directions a caller can name, as an error message lists them.
    static var names: String { allCases.map(\.rawValue).joined(separator: "/") }
}

/// Why a seek stopped without finding its label.
enum ScrollStopReason: String, Sendable {
    /// The content stopped moving: the scrolls reached its end.
    case endOfContent = "end_of_content"
    /// The scroll budget ran out while the content was still moving.
    case maxScrolls = "max_scrolls"
}

/// How a seek ended.
enum ScrollSeekOutcome: Equatable, Sendable {
    /// The label was on screen before any scroll.
    case alreadyVisible
    /// The label came into view after `scrolls` scrolls.
    case found(scrolls: Int)
    /// The label never came into view.
    case stopped(ScrollStopReason, scrolls: Int)
    /// The seek could not run: no window, a failed swipe or a failed read.
    case failed(String)
}

/// Where a swipe starts and ends, in window points.
struct SwipeEndpoints: Equatable, Sendable {
    let fromX: Double
    let fromY: Double
    let toX: Double
    let toY: Double
}

/// Scrolls toward a label, reading the screen after each scroll.
///
/// The end of the content is declared from what scrolls: the band between the
/// status bar and the bottom safe zone. A clock that ticks over in the status
/// bar is not movement, and a list that has not moved once is not yet proof
/// of its end, so the band must stand where it stood on `confirmations` of
/// the last few reads. The band is compared by its text and by its pixels:
/// pictures that move under a label that stays put are movement. On a screen
/// that animates while at rest, pixels say nothing, and the text alone decides.
enum ScrollSeeker {

    /// Scroll until `label` is visible, or the content ends, or `maxScrolls` is spent.
    ///
    /// - Parameters:
    ///   - direction: where the content with `label` lies.
    ///   - anchor: the point to scroll at, for a list inside the screen; nil is the window's centre.
    ///   - band: the fractions of the window height that hold scrolling content.
    ///   - settleUs: how long each read waits for the screen to stop changing.
    ///   - confirmations: earlier reads the current one must agree with to declare the end of the content.
    static func seek(
        label: String, toward direction: ScrollDirection, maxScrolls: Int, anchor: CGPoint?,
        band: ClosedRange<Double>, bridge: any WindowBridging, input: any InputProviding,
        describer: any ScreenDescribing,
        settleUs: UInt32 = EnvConfig.frameSettleTimeoutUs,
        confirmations: Int = EnvConfig.scrollEndConfirmations
    ) -> ScrollSeekOutcome {
        let first = describer.describe(settleTimeoutUs: settleUs)
        if let first, ElementMatcher.isVisible(label: label, in: first.elements) {
            return .alreadyVisible
        }
        guard let window = bridge.getWindowInfo()?.size else {
            return .failed("Could not get window info for scroll")
        }
        guard let swipe = endpoints(
            fingerDirection: direction.fingerDirection, window: window, around: anchor) else {
            return .failed("No swipe reveals content to the \(direction.rawValue)")
        }

        guard maxScrolls > 0 else { return .stopped(.maxScrolls, scrolls: 0) }

        // The reads so far, newest first, as far back as a read is compared.
        var earlier = first.map { [Reading($0, windowHeight: window.height, band: band)] } ?? []
        // Whether the band holds still between swipes, so that pixels which
        // differ after a swipe mean the content moved. Unknown until the
        // first time the text stays the same while the pixels change.
        var holdsStillAtRest: Bool?
        for scroll in 1 ... maxScrolls {
            if let error = input.swipe(fromX: swipe.fromX, fromY: swipe.fromY,
                                       toX: swipe.toX, toY: swipe.toY,
                                       durationMs: EnvConfig.defaultSwipeDurationMs) {
                return .failed("Swipe failed: \(error)")
            }
            guard let result = describer.describe(settleTimeoutUs: settleUs) else {
                return .failed("Could not read the screen after scroll \(scroll)")
            }
            if ElementMatcher.isVisible(label: label, in: result.elements) {
                return .found(scrolls: scroll)
            }
            let reading = Reading(result, windowHeight: window.height, band: band)
            // Content that scrolls never comes back to where it stood. Content
            // at its end does, though not on every read: pushed past its end
            // it can still be pulled when it is read. So a read is weighed
            // against the last few, and the end is the content standing where
            // it stood on `confirmations` of them.
            let comparisons = earlier.map { reading.compared(to: $0, band: band) }
            var agreeing = comparisons.filter { $0 == .same }.count
            let textOnly = comparisons.filter { $0 == .sameTextOtherPixels }.count
            if textOnly > 0, agreeing < confirmations {
                if holdsStillAtRest == nil {
                    // Read once more with no swipe in between: if the pixels
                    // change by themselves, they cannot tell a scroll from rest.
                    guard let rest = describer.describe(settleTimeoutUs: settleUs) else {
                        return .failed("Could not read the screen after scroll \(scroll)")
                    }
                    holdsStillAtRest = Reading(rest, windowHeight: window.height, band: band)
                        .hasSamePixels(as: reading, band: band)
                }
                if holdsStillAtRest == false { agreeing += textOnly }
            }
            DebugLog.log("scroll", "scroll \(scroll): \(reading.texts.count) text(s) in the band; against the "
                + "\(earlier.count) read(s) before it: "
                + earlier.map { reading.describeChange(from: $0, band: band) }.joined(separator: " | ")
                + "; agrees with \(agreeing)")
            if agreeing >= confirmations { return .stopped(.endOfContent, scrolls: scroll) }
            earlier = Array(([reading] + earlier).prefix(max(confirmations, EnvConfig.scrollRevisitDepth)))
        }
        return .stopped(.maxScrolls, scrolls: maxScrolls)
    }

    /// The swipe for a finger moving `fingerDirection`: `swipeDistanceFraction`
    /// of the window height long, centred on `anchor` (the window's centre
    /// when nil) and shifted to stay inside the window. Nil for an unknown direction.
    static func endpoints(fingerDirection: String, window: CGSize, around anchor: CGPoint?) -> SwipeEndpoints? {
        let centre = anchor ?? CGPoint(x: window.width / 2, y: window.height / 2)
        let half = window.height * EnvConfig.swipeDistanceFraction / 2
        let vertical = span(centre: centre.y, half: half, limit: window.height)
        let horizontal = span(centre: centre.x, half: half, limit: window.width)
        switch fingerDirection.lowercased() {
        case "up":
            return SwipeEndpoints(fromX: centre.x, fromY: vertical.high, toX: centre.x, toY: vertical.low)
        case "down":
            return SwipeEndpoints(fromX: centre.x, fromY: vertical.low, toX: centre.x, toY: vertical.high)
        case "left":
            return SwipeEndpoints(fromX: horizontal.high, fromY: centre.y, toX: horizontal.low, toY: centre.y)
        case "right":
            return SwipeEndpoints(fromX: horizontal.low, fromY: centre.y, toX: horizontal.high, toY: centre.y)
        default:
            return nil
        }
    }

    /// `centre` ± `half`, shifted to fit in 0...`limit` and cut to it when longer.
    private static func span(centre: Double, half: Double, limit: Double) -> (low: Double, high: Double) {
        var low = centre - half
        var high = centre + half
        if low < 0 { high -= low; low = 0 }
        if high > limit { low -= high - limit; high = limit }
        return (max(0, low), high)
    }

    /// The fractions of the window height that hold scrolling content on a
    /// target: below its status bar, above its bottom safe zone.
    static func band(for profile: TargetProfile, orientation: DeviceOrientation?) -> ClosedRange<Double> {
        let zones = profile.layoutZones(orientation)
        let top = zones.statusBarZoneFraction
        return top ... max(top, zones.safeZone.maxTapYFraction)
    }

    /// The texts inside the band that two reads can be compared on, each with
    /// where it sits. Detector icons are left out: several come and go between
    /// two reads of a screen that has not moved.
    static func contentTexts(_ elements: [TapPoint], windowHeight: Double, band: ClosedRange<Double>) -> [TapPoint] {
        let rows = (band.lowerBound * windowHeight) ... (band.upperBound * windowHeight)
        return elements.filter { rows.contains($0.tapY) && $0.text != CoreMLElementDetector.iconLabel }
    }

    /// The share of the texts of two reads that sit in the same place in both,
    /// out of the larger read: 1 when nothing moved, near 0 after a scroll.
    /// Two reads with no text at all share everything. Texts are matched on
    /// their letters and digits (`comparable`): the symbols between them are
    /// what OCR reads differently from one frame to the next.
    static func shareInPlace(_ lhs: [TapPoint], _ rhs: [TapPoint], tolerance: Double) -> Double {
        let larger = max(lhs.count, rhs.count)
        guard larger > 0 else { return 1 }
        var unmatched = rhs.map { (text: comparable($0.text), x: $0.tapX, y: $0.tapY) }
        var inPlace = 0
        for element in lhs {
            let text = comparable(element.text)
            guard let index = unmatched.firstIndex(where: {
                $0.text == text && abs($0.x - element.tapX) <= tolerance && abs($0.y - element.tapY) <= tolerance
            }) else { continue }
            unmatched.remove(at: index)
            inPlace += 1
        }
        return Double(inPlace) / Double(larger)
    }

    /// A text reduced to what two reads of it agree on: its letters and
    /// digits, without case or accents. "1 8° \ 3°" and "1 8° ₺ 3°" are the
    /// same text; a text of symbols alone compares as empty.
    static func comparable(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter(comparableCharacters.contains))
    }

    /// Letters and digits, without the ordinal marks "º" and "ª": Unicode
    /// counts them as letters, and they are how OCR reads a degree sign.
    private static let comparableCharacters =
        CharacterSet.alphanumerics.subtracting(CharacterSet(charactersIn: "ºª"))

    /// What one read of the screen says about the scrolling content.
    private struct Reading {
        let texts: [TapPoint]
        let frame: Data?

        init(_ result: ScreenDescriber.DescribeResult, windowHeight: Double, band: ClosedRange<Double>) {
            texts = ScrollSeeker.contentTexts(result.elements, windowHeight: windowHeight, band: band)
            // A read that carries no image has no frame to compare.
            let image = Data(base64Encoded: result.screenshotBase64)
            frame = image?.isEmpty == false ? image : nil
        }

        /// How this read differs from the one before it.
        enum Comparison {
            /// The text in place and the same pixels in the band.
            case same
            /// Text that moved, or a band with no text whose pixels changed.
            case moved
            /// The text stayed and the pixels changed: pictures scrolling under
            /// a fixed label, or a screen that animates while at rest.
            case sameTextOtherPixels
        }

        /// The text is in place when enough of it sits where it sat: not all
        /// of it, because two reads of a screen at rest never agree on every
        /// text. Frames that cannot be compared decide nothing: a band with
        /// text is judged by its text, and a band without any is never the
        /// same, so a seek on it ends on its budget, not on a guess.
        func compared(to other: Reading, band: ClosedRange<Double>) -> Comparison {
            let share = ScrollSeeker.shareInPlace(
                texts, other.texts, tolerance: EnvConfig.scrollUnchangedPositionTolerance)
            guard share >= EnvConfig.scrollUnchangedTextShare else { return .moved }
            let noText = texts.isEmpty && other.texts.isEmpty
            guard let frame, let otherFrame = other.frame else { return noText ? .moved : .same }
            if FrameFingerprint.sameRows(frame, otherFrame, band: band) { return .same }
            return noText ? .moved : .sameTextOtherPixels
        }

        /// What `compared(to:)` weighed, for the debug log.
        func describeChange(from other: Reading, band: ClosedRange<Double>) -> String {
            let share = ScrollSeeker.shareInPlace(
                texts, other.texts, tolerance: EnvConfig.scrollUnchangedPositionTolerance)
            let pixels = hasSamePixels(as: other, band: band) ? "same" : "other"
            return "\(Int((share * 100).rounded()))% of the text in place, \(pixels) pixels"
        }

        /// Whether both reads show the same pixels in the band.
        func hasSamePixels(as other: Reading, band: ClosedRange<Double>) -> Bool {
            guard let frame, let otherFrame = other.frame else { return false }
            return FrameFingerprint.sameRows(frame, otherFrame, band: band)
        }
    }
}

extension ScrollSeekOutcome {

    /// The scroll_to tool's reply for `label`, and whether it is an error.
    func toolReply(label: String) -> (text: String, isError: Bool) {
        switch self {
        case .alreadyVisible:
            return ("'\(label)' is already visible on screen", false)
        case .found(let scrolls):
            return ("Found '\(label)' after \(scrolls) scroll(s)", false)
        case .stopped(.endOfContent, let scrolls):
            return ("'\(label)' not found: the content stopped moving after \(scrolls) scroll(s) "
                + "(stop_reason=\(ScrollStopReason.endOfContent.rawValue))", true)
        case .stopped(.maxScrolls, let scrolls):
            return ("'\(label)' not found after \(scrolls) scroll(s) "
                + "(stop_reason=\(ScrollStopReason.maxScrolls.rawValue))", true)
        case .failed(let message):
            return (message, true)
        }
    }

    /// The scroll_to step's result message, and whether the step passed. The
    /// "found after N scroll(s)" wording is read back by `compile` for the scroll count.
    var stepResult: (message: String, passed: Bool) {
        switch self {
        case .alreadyVisible:
            return ("already visible", true)
        case .found(let scrolls):
            return ("found after \(scrolls) scroll(s)", true)
        case .stopped(.endOfContent, let scrolls):
            return ("Content stopped moving after \(scrolls) scroll(s) "
                + "(\(ScrollStopReason.endOfContent.rawValue))", false)
        case .stopped(.maxScrolls, let scrolls):
            return ("Not found after \(scrolls) scroll(s) (\(ScrollStopReason.maxScrolls.rawValue))", false)
        case .failed(let message):
            return (message, false)
        }
    }
}
