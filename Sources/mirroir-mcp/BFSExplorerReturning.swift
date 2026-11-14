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
// ABOUTME: BFSExplorer `.returning` phase — edge-type-aware backtracking toward root.
// ABOUTME: Extracted from BFSBacktrackVerifier.swift to stay under the 500-line limit.

import Foundation
import HelperLib

extension BFSExplorer {

    // MARK: - Phase: Returning

    /// Tap back one level toward root. Each step reduces depth by one.
    func stepReturning(
        depthRemaining: Int,
        describer: ScreenDescribing,
        input: InputProviding
    ) -> ExploreStepResult {
        // Get current screen elements for back button detection
        let elements: [TapPoint]
        if let result = ExplorerUtilities.dismissAlertIfPresent(
            describer: describer, input: input
        ) {
            elements = result.elements
        } else {
            elements = []
        }

        // Use edge-type-aware backtracking: check what kind of edge
        // brought us to this screen and reverse accordingly.
        let currentFP = graph.currentFingerprint
        let incomingEdge = graph.incomingEdge(to: currentFP)
        var handled = false

        if let edge = incomingEdge {
            switch edge.edgeType {
            case .modal:
                if let dismiss = EdgeClassifier.findDismissTarget(
                    elements: elements, screenHeight: windowSize.height
                ) {
                    _ = input.tap(x: dismiss.tapX, y: dismiss.tapY)
                    usleep(EnvConfig.stepSettlingDelayMs * 1000)
                    handled = true
                }
            case .tab:
                // Tap the app's root tab (first APP.md-declared tab) resolved
                // against the source screen's elements + icons — icon-only
                // bars resolve via geometric anchor synthesis.
                if let sourceNode = graph.node(for: edge.fromFingerprint) {
                    if BFSTabReturn.tapRootTab(
                        appDescription: session.currentAppDescription,
                        elements: sourceNode.elements, icons: sourceNode.icons,
                        windowSize: windowSize, input: input
                    ) {
                        handled = true
                    } else {
                        // For tabs, find the source screen's tab element
                        let tabBarZone = windowSize.height * EdgeClassifier.tabBarZoneFraction
                        if let tabElement = sourceNode.elements.first(where: { $0.tapY >= tabBarZone }) {
                            _ = input.tap(x: tabElement.tapX, y: tabElement.tapY)
                            usleep(EnvConfig.stepSettlingDelayMs * 1000)
                            handled = true
                        }
                    }
                }
            case .toggle:
                // Toggle doesn't need backtrack action, just proceed
                handled = true
            case .external, .dead:
                _ = input.pressKey(keyName: "h", modifiers: ["command", "shift"])
                usleep(EnvConfig.stepSettlingDelayMs * 1000)
                handled = true
            case .push, .same:
                break
            }
        }

        if !handled {
            backtracker.tapBack(
                elements: elements, input: input, windowSize: windowSize,
            fallback: currentLayoutZones.backButtonFallback
            )
        }

        let remaining = depthRemaining - 1
        if remaining > 0 {
            frontierManager.phase = .returning(depthRemaining: remaining)
        } else {
            frontierManager.phase = .atRoot
            graph.setCurrentFingerprint(graph.rootFingerprint)
        }

        return .continue(
            description: "Returning to root (\(remaining) level\(remaining == 1 ? "" : "s") remaining)"
        )
    }
}
