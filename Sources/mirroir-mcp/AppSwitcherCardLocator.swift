// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Locates a specific app's card in iPhone Mirroring's App Switcher by matching its preview text against the foreground app's OCR.
// ABOUTME: Eliminates the brittleness of hard-coded `appSwitcherCardXFraction` whose correct value depends on how many apps are in the switcher.

import Foundation
import HelperLib

/// AppSwitcherCardLocator — given OCR text from an app's foreground state and
/// OCR text from the App Switcher view, find the X coordinate of the card
/// whose preview shows that app.
///
/// iPhone Mirroring's App Switcher renders each running app as a scaled-down
/// preview. Text that appears in the foreground app also appears in the
/// preview (smaller, sometimes partially clipped). By intersecting the
/// foreground text set with the App Switcher OCR and clustering the matches
/// by X bucket, the cluster with the most matches identifies the card
/// belonging to the just-launched app — regardless of where iPhone Mirroring
/// chooses to position it within the carousel.
enum AppSwitcherCardLocator {

    /// Minimum text length to use for matching. Single characters and short
    /// fragments produce too many false matches.
    static let minTextLength: Int = 3

    /// Fraction of the window width below which a card is treated as the
    /// far-left clipped/peeking sliver. The just-launched app is the current
    /// foreground app — its card is centered or to the right in the switcher,
    /// never the leftmost (oldest) card. That left sliver is where OCR is
    /// unreliable and common localized words (tab labels like "Accueil") create
    /// false matches; dragging it quits the WRONG app. Matches there are dropped.
    static let leftEdgeFraction: Double = 0.20

    /// Max X gap (points) between consecutive matches that still belong to the
    /// same card. Each running app is one card; matches within a card-width
    /// cluster together.
    static let clusterGapPt: Double = 90.0

    /// The winning card cluster must out-score the runner-up by at least this
    /// factor. A near-tie means we cannot tell two cards apart, so we fail
    /// closed (return nil) rather than drag a guess and quit the wrong app.
    static let ambiguityMargin: Double = 1.5

    /// Minimum total matched text length for the winning cluster. A genuine
    /// card preview shares many lines with the foreground capture (or at least
    /// one long distinctive token); one or two short common tokens (a stray
    /// French word on a neighboring card) can otherwise form a single-cluster
    /// "unambiguous" hit — which made the post-dismiss verification report a
    /// long-gone card as still present.
    static let minClusterScore: Int = 10

    /// Locate the X coordinate of the just-launched app's card in App Switcher
    /// OCR by matching against the app's foreground OCR text. Returns nil — so
    /// the caller fails closed and never drags — when no card can be located
    /// *unambiguously*.
    ///
    /// - Parameters:
    ///   - appElements: OCR text captured while the app was the foreground app.
    ///   - switcherElements: OCR text captured after opening App Switcher.
    ///   - windowWidth: Mirroring window width (points), for the left-edge guard.
    /// - Returns: The median X of the winning card cluster, or nil when the
    ///   match is absent or ambiguous.
    static func locateCardX(
        appElements: [TapPoint],
        switcherElements: [TapPoint],
        windowWidth: Double
    ) -> Double? {
        let appTexts = Set(
            appElements
                .map { normalize($0.text) }
                .filter { $0.count >= minTextLength }
        )
        guard !appTexts.isEmpty else { return nil }

        // Candidate matches: switcher tokens present in the foreground app,
        // excluding the far-left clipped sliver.
        let leftEdge = windowWidth * leftEdgeFraction
        let matches = switcherElements.filter { el in
            let key = normalize(el.text)
            return el.tapX >= leftEdge && key.count >= minTextLength && appTexts.contains(key)
        }
        guard !matches.isEmpty else { return nil }

        // Cluster by X proximity — one cluster per app card.
        let sorted = matches.sorted { $0.tapX < $1.tapX }
        var clusters: [[TapPoint]] = []
        for match in sorted {
            if let lastX = clusters.last?.last?.tapX, match.tapX - lastX <= clusterGapPt {
                clusters[clusters.count - 1].append(match)
            } else {
                clusters.append([match])
            }
        }

        // Score each cluster by total matched text length (distinctiveness),
        // so a card showing several common short words cannot out-vote the real
        // card's distinctive content. Highest score wins.
        let scored = clusters
            .map { cluster -> (score: Int, xs: [Double]) in
                let score = cluster.reduce(0) { $0 + normalize($1.text).count }
                return (score, cluster.map { $0.tapX }.sorted())
            }
            .sorted { $0.score > $1.score }

        guard let best = scored.first, best.score >= minClusterScore else { return nil }
        // Fail closed on a near-tie between two cards.
        if scored.count >= 2 {
            let runnerUp = scored[1].score
            if runnerUp > 0, Double(best.score) < Double(runnerUp) * ambiguityMargin {
                return nil
            }
        }
        return best.xs[best.xs.count / 2]
    }

    /// Window-height fraction bounding the switcher's app-name label band.
    /// iOS renders each card's app name above the card (~y=140-150 on a 898pt
    /// window); labels never appear below ~20% of the window.
    static let labelBandMaxYFraction: Double = 0.20

    /// Whether the switcher OCR shows `appName` in the card label band.
    /// The label is the switcher's own rendering of the app's display name —
    /// a far stronger card-presence signal than content-fingerprint matching,
    /// which stray token overlap can fool. Truncated labels ("Insta…") are
    /// matched by prefix (≥4 chars) against the app name.
    static func labelBandContains(
        appName: String, switcherElements: [TapPoint], windowHeight: Double
    ) -> Bool {
        let name = normalize(appName)
        guard name.count >= 2 else { return false }
        let maxY = windowHeight * labelBandMaxYFraction
        return switcherElements.contains { el in
            guard el.tapY <= maxY else { return false }
            return labelNames(normalize(el.text), name)
        }
    }

    /// X of `appName`'s card from the switcher's own label above it, or nil
    /// when the label is absent, sits in the clipped left sliver, or matches
    /// more than one element. Each label is drawn over the left part of its
    /// own card, so its center X lands on that card even when the card's
    /// preview is clipped by the right edge and its text no longer matches the
    /// foreground capture.
    static func locateCardXByLabel(
        appName: String, switcherElements: [TapPoint], windowSize: CGSize
    ) -> Double? {
        let name = normalize(appName)
        guard name.count >= 2 else { return nil }
        let maxY = Double(windowSize.height) * labelBandMaxYFraction
        let leftEdge = Double(windowSize.width) * leftEdgeFraction
        let labels = switcherElements.filter { el in
            guard el.tapY <= maxY, el.tapX >= leftEdge else { return false }
            return labelNames(normalize(el.text), name)
        }
        guard labels.count == 1, let label = labels.first else { return nil }
        return label.tapX
    }

    /// Locate `appName`'s card. The switcher's own label, matched exactly once,
    /// is the stronger signal: it names the app and survives a preview clipped
    /// by the window edge, where too few lines match the foreground capture.
    /// The content fingerprint locates the card when no single label reads.
    static func locateCard(
        appName: String,
        appElements: [TapPoint],
        switcherElements: [TapPoint],
        windowSize: CGSize
    ) -> Double? {
        if let byLabel = locateCardXByLabel(
            appName: appName, switcherElements: switcherElements, windowSize: windowSize) {
            return byLabel
        }
        return locateCardX(
            appElements: appElements, switcherElements: switcherElements,
            windowWidth: Double(windowSize.width))
    }

    /// Whether a normalized switcher label names the normalized app `name`:
    /// the whole name, or the OCR of a clipped edge-card label — a ≥4-char
    /// prefix of the name that ends mid-word ("insta" of "instagram"). A prefix
    /// ending where a word of the name ends is a whole name of its own: the
    /// "brawl stars" card is another app than "brawl stars victoire", and
    /// taking it for that app's label quits the wrong app or reports a
    /// dismissed card as still present.
    private static func labelNames(_ label: String, _ name: String) -> Bool {
        if label == name { return true }
        guard label.count >= 4, name.hasPrefix(label) else { return false }
        return name[name.index(name.startIndex, offsetBy: label.count)] != " "
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespaces)
    }
}
