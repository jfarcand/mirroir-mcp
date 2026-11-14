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
// ABOUTME: Injects APP.md tab-bar navigation targets into exploration plans.
// ABOUTME: Text-matches labeled bars; geometrically synthesizes anchors for icon-only bars.

import CoreGraphics
import Foundation
import HelperLib

/// Resolves APP.md-declared tab bars into high-priority breadth-navigation plan
/// targets. Two strategies: case-insensitive text matching for labeled bars, and
/// geometric anchor synthesis for icon-only bars (Instagram/TikTok) where the tabs
/// carry no OCR text. Pure transformation: all static methods, no stored state.
enum TabTargetInjector {

    /// Inject tab targets at the front of an exploration plan. Shared by the
    /// per-viewport plan path (`buildScreenPlan`) and the component-calibration
    /// path (`calibrateWithComponents`) so tab-driven navigation works regardless
    /// of which planning path an app takes. Returns the plan unchanged when no
    /// tabs are declared or none resolve on the current screen.
    static func inject(
        into plan: [RankedElement],
        classifiedPoints: [TapPoint],
        icons: [IconDetector.DetectedIcon],
        visitedElements: Set<String>,
        tabs: [String],
        tabLayout: TabLayout?,
        windowSize: CGSize
    ) -> [RankedElement] {
        guard !tabs.isEmpty else { return plan }
        // Include detected unlabeled icons so the tab-zone evidence check and the
        // text-match strategy both see icon-only bars (Instagram/TikTok), where
        // the tabs carry no OCR text and never appear among `classified` elements.
        let iconPoints = icons.map {
            TapPoint(text: "", tapX: $0.tapX, tapY: $0.tapY, confidence: 1.0)
        }
        let allPoints = classifiedPoints + iconPoints
        let tabTargets = findTargets(
            tabNames: tabs, elements: allPoints, visitedElements: visitedElements,
            tabLayout: tabLayout, windowSize: windowSize)
        guard !tabTargets.isEmpty else { return plan }
        DebugLog.log("bfs", "tab-driven: injected \(tabTargets.count) tab targets " +
            "from APP.md: \(tabTargets.map { $0.displayLabel })")
        return tabTargets + plan
    }

    /// Find tab targets matching `tabNames`.
    ///
    /// Strategy 1: case-insensitive substring text match (labeled tab bars).
    /// Strategy 2: geometric synthesis for unmatched tabs (icon-only tab bars).
    /// The layout hint (`TabLayout.orientation`/`.edge`) decides which window edge
    /// to sample and which axis the bar runs along; nil defaults to bottom/horizontal.
    static func findTargets(
        tabNames: [String], elements: [TapPoint], visitedElements: Set<String>,
        tabLayout: TabLayout?, windowSize: CGSize
    ) -> [RankedElement] {
        var results: [RankedElement] = []
        var matchedTabs: Set<String> = []
        let score = ScreenPlanner.breadthRoleWeight + ScreenPlanner.highPriorityWeight

        // Strategy 1: text matching
        for tabName in tabNames {
            guard let match = elements.first(where: { el in
                matchesTabName(tabName, element: el)
                    && !visitedElements.contains(el.text)
                    && !visitedElements.contains(tabName)
            }) else { continue }

            results.append(RankedElement(
                point: match, score: score,
                reason: "tab-driven(\(tabName))",
                displayLabel: tabName, isBreadthNavigation: true
            ))
            matchedTabs.insert(tabName)
        }

        // Strategy 2: geometric synthesis for unmatched tabs (icon-only tab bars).
        // OCR carries no text for icon-only bars and per-icon detection is noisy
        // (misses edge tabs, adds blobs), so ordinal-mapping detections mis-assigns
        // tabs. Instead, when the tab-bar band shows evidence of a bar, synthesize
        // N evenly-spaced anchor points from the known tab count and bar geometry —
        // independent of which individual icons were detected.
        let unmatchedTabs = tabNames.filter { !matchedTabs.contains($0) }
        if !unmatchedTabs.isEmpty {
            let layout = tabLayout ?? TabLayout(orientation: .horizontal, edge: .bottom)
            let zoneElements = elementsInTabZone(
                elements: elements, layout: layout, windowSize: windowSize)
            // Presence gate: require evidence of a tab bar (configurable, baseline
            // 1) before synthesizing, so a bare detail screen whose bottom band
            // happens to hold a stray element does not get phantom tab anchors.
            if zoneElements.count >= EnvConfig.tabSynthesisMinZoneEvidence {
                let anchors = synthesizeAnchors(
                    tabCount: tabNames.count, layout: layout,
                    zoneElements: zoneElements, windowSize: windowSize)
                for (index, tabName) in tabNames.enumerated() {
                    guard !matchedTabs.contains(tabName),
                          index < anchors.count,
                          !visitedElements.contains(tabName) else { continue }
                    results.append(RankedElement(
                        point: anchors[index], score: score,
                        reason: "tab-synth(\(tabName)@\(index),\(layout.orientation.rawValue))",
                        displayLabel: tabName, isBreadthNavigation: true
                    ))
                }
            }
        }

        return results
    }

    /// Resolve the tap point that returns the explorer to the app's root tab.
    /// Convention: the first APP.md-declared tab is the tab root; tapping it
    /// returns home from any tab screen.
    ///
    /// Strategy 1 text-matches the first declared tab against the screen's
    /// tab-zone elements only (labeled bars, same matching rules as
    /// `findTargets`). Screen content routinely contains tab-name substrings
    /// (nav titles, feed captions) and OCR order is top-to-bottom, so an
    /// unconstrained match would tap mid-screen content instead of the bar.
    /// Strategy 2 synthesizes anchor index 0 from the bar geometry (icon-only
    /// bars). Returns nil when no tabs are declared or the tab-bar band shows
    /// no evidence of a bar.
    static func returnToRootTarget(
        tabs: [String], tabLayout: TabLayout?, elements: [TapPoint],
        icons: [IconDetector.DetectedIcon], windowSize: CGSize
    ) -> TapPoint? {
        guard let rootTab = tabs.first else { return nil }
        let iconPoints = icons.map {
            TapPoint(text: "", tapX: $0.tapX, tapY: $0.tapY, confidence: 1.0)
        }
        let allPoints = elements + iconPoints
        let layout = tabLayout ?? TabLayout(orientation: .horizontal, edge: .bottom)
        let zoneElements = elementsInTabZone(
            elements: allPoints, layout: layout, windowSize: windowSize)

        // Strategy 1: text matching against the first declared tab, restricted
        // to the tab-bar zone so content matches cannot shadow the bar label.
        if let match = zoneElements.first(where: { matchesTabName(rootTab, element: $0) }) {
            return match
        }

        // Strategy 2: synthesized anchor index 0 (icon-only tab bars). Unlike
        // the injection-path gate (`findTargets`, where a tapped anchor is
        // validated by post-tap OCR), this tap is a blind recovery action with
        // no verification of the target — so it demands the same evidence level
        // that constitutes a tab-bar detection (`tabBarMinBandPoints`); the env
        // knob can only raise that floor, never lower it.
        let minEvidence = max(
            EnvConfig.tabSynthesisMinZoneEvidence,
            NavigationHintDetector.tabBarMinBandPoints
        )
        guard zoneElements.count >= minEvidence else { return nil }
        return synthesizeAnchors(
            tabCount: tabs.count, layout: layout,
            zoneElements: zoneElements, windowSize: windowSize
        ).first
    }

    /// Case-insensitive substring match between a declared tab name and an
    /// OCR element's text.
    /// Skip text-less elements (icon-only tab points carry text ""):
    /// `tabLower.contains("")` is always true, which would spuriously
    /// match every tab to the first icon and starve Strategy 2.
    private static func matchesTabName(_ tabName: String, element: TapPoint) -> Bool {
        let tabLower = tabName.lowercased()
        let elLower = element.text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !elLower.isEmpty else { return false }
        return elLower == tabLower || elLower.contains(tabLower) || tabLower.contains(elLower)
    }

    /// Synthesize evenly-spaced tab anchor points for an icon-only tab bar.
    /// iOS tab bars space their items evenly across the bar's main axis at a fixed
    /// cross-axis position. The cross-axis position is read from the median of the
    /// detected band elements (icons); the main-axis positions come from the known
    /// tab count, so the result is independent of noisy per-icon detection.
    /// Returns `tabCount` anchors in tab order.
    private static func synthesizeAnchors(
        tabCount: Int, layout: TabLayout, zoneElements: [TapPoint], windowSize: CGSize
    ) -> [TapPoint] {
        guard tabCount > 0 else { return [] }
        let width = Double(windowSize.width)
        let height = Double(windowSize.height)
        let band: Double = 0.12
        // The tab bar's cross-axis position is read from the detected icons — the
        // text-less band points. Text content can also fall in the band (the
        // component path supplies full-page classified text), so prefer text-less
        // points and only fall back to all band points, then to a geometric edge.
        let iconBand = zoneElements.filter { $0.text.isEmpty }
        let crossAxisSource = iconBand.isEmpty ? zoneElements : iconBand

        switch layout.orientation {
        case .horizontal:
            // Items run left→right; cross-axis (Y) is the bar's vertical center.
            let barY = median(crossAxisSource.map(\.tapY))
                ?? (layout.edge == .top ? height * (band / 2) : height * (1 - band / 2))
            return (0..<tabCount).map { index in
                let x = (Double(index) + 0.5) * width / Double(tabCount)
                return TapPoint(text: "", tapX: x, tapY: barY, confidence: 1.0)
            }
        case .vertical:
            // Items run top→bottom; cross-axis (X) is the rail's horizontal center.
            let barX = median(crossAxisSource.map(\.tapX))
                ?? (layout.edge == .left ? width * (band / 2) : width * (1 - band / 2))
            return (0..<tabCount).map { index in
                let y = (Double(index) + 0.5) * height / Double(tabCount)
                return TapPoint(text: "", tapX: barX, tapY: y, confidence: 1.0)
            }
        }
    }

    /// Filter OCR elements to those inside the declared tab-bar zone.
    /// Zone widths are 12% of the relevant axis — consistent with the existing
    /// bottom-edge convention used for iPhone portrait tab bars.
    private static func elementsInTabZone(
        elements: [TapPoint], layout: TabLayout, windowSize: CGSize
    ) -> [TapPoint] {
        let band: Double = 0.12
        switch layout.edge {
        case .bottom:
            let minY = windowSize.height * (1 - band)
            return elements.filter { $0.tapY >= minY }
        case .top:
            let maxY = windowSize.height * band
            return elements.filter { $0.tapY <= maxY }
        case .right:
            let minX = windowSize.width * (1 - band)
            return elements.filter { $0.tapX >= minX }
        case .left:
            let maxX = windowSize.width * band
            return elements.filter { $0.tapX <= maxX }
        }
    }

    /// Median of a value set (lower-middle element for even counts). Nil when empty.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
