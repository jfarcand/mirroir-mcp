// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the component-calibration plan path: APP.md tab injection with
// ABOUTME: global-visited exclusion and Q-boost wiring from persisted edge values.

import CoreGraphics
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

/// Stub classifier that wraps every classified element into its own component
/// of a fixed definition. Lets calibration-path tests drive
/// `calibrateWithComponents` without real component matching.
private final class RowStubClassifier: ComponentClassifying, @unchecked Sendable {
    let definition: ComponentDefinition

    init(definition: ComponentDefinition) {
        self.definition = definition
    }

    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]? {
        classified
            .filter { !$0.point.text.isEmpty }
            .map { el in
                ScreenComponent(
                    kind: definition.name, definition: definition, elements: [el],
                    tapTarget: el.point, hasChevron: false,
                    topY: el.point.tapY - 20, bottomY: el.point.tapY + 20
                )
            }
    }
}

final class BFSExplorerCalibrationPlanTests: XCTestCase {

    private let instagramTabs = ["Accueil", "Recherche", "Reels", "Boutique", "Profil"]

    private let bandIcons: [IconDetector.DetectedIcon] = [
        IconDetector.DetectedIcon(tapX: 142, tapY: 845, estimatedSize: 24),
        IconDetector.DetectedIcon(tapX: 206, tapY: 844, estimatedSize: 30),
        IconDetector.DetectedIcon(tapX: 343, tapY: 846, estimatedSize: 27),
    ]

    private func makeAppDescription(tabs: [String]) -> AppDescription {
        AppDescription(
            appName: "TestApp", schemaVersion: 1, locale: "fr_CA", archetype: nil, playable: nil,
            resetBeforeExplore: false, obstacleMode: .auto, context: "test",
            obstacles: [], skipElements: [], credentials: [:], hints: [],
            tabs: tabs, tabLayout: TabLayout(orientation: .horizontal, edge: .bottom),
            deepTabs: [], simulator: nil
        )
    }

    private func makeRowDefinition() -> ComponentDefinition {
        ComponentDefinition(
            name: "table-row", platform: "ios",
            description: "Navigation row.",
            visualPattern: ["Label"],
            matchRules: ComponentMatchRules(
                rowHasChevron: false, chevronMode: nil,
                minElements: 1, maxElements: 4,
                maxRowHeightPt: 60, hasNumericValue: nil,
                hasLongText: nil, hasDismissButton: nil,
                zone: .content, minConfidence: nil,
                excludeNumericOnly: nil, textPattern: nil
            ),
            interaction: ComponentInteraction(
                clickable: true, clickTarget: .firstText,
                clickResult: .pushesScreen, backAfterClick: true,
                labelRule: .firstText
            ),
            exploration: ComponentExploration(
                explorable: true, role: .depthNavigation, priority: .normal
            ),
            grouping: ComponentGrouping(
                absorbsSameRow: false, absorbsBelowWithinPt: 0,
                absorbCondition: .any, splitMode: .none
            )
        )
    }

    func testCalibrationPathSkipsGloballyVisitedTabsAndAppliesQBoost() {
        // The component-calibration path bypasses buildScreenPlan, so its own
        // injection site must exclude globally-visited tabs and its stored plan
        // must reflect persisted Q-values.
        let session = ExplorationSession()
        session.start(appName: "TestApp", goal: "test")
        session.setAppDescription(makeAppDescription(tabs: instagramTabs))
        let rootElements = [
            TapPoint(text: "Réglages", tapX: 205, tapY: 300, confidence: 0.95),
            TapPoint(text: "Contacts", tapX: 205, tapY: 400, confidence: 0.95),
        ]
        session.capture(
            elements: rootElements, hints: [], icons: [],
            actionType: nil, arrivedVia: nil, screenshotBase64: "img0"
        )
        let graph = session.currentGraph
        let rootFP = graph.rootFingerprint

        // Persisted knowledge: "Réglages" was a dead tap (q=0) and the
        // "Accueil" tab has already been explored this session.
        _ = graph.recordTransition(
            elements: makeExplorerElements(["Autre écran", "Contenu"]), icons: [],
            hints: [], screenshot: "img1", actionType: "tap",
            elementText: "Réglages", displayLabel: "Réglages",
            screenType: .settings, edgeType: .push
        )
        (graph as? NavigationGraph)?.updateQValue(
            fromFingerprint: rootFP, displayLabel: "Réglages", result: .duplicate)
        graph.setCurrentFingerprint(rootFP)
        graph.markGloballyVisited(label: "Accueil")

        let rowDef = makeRowDefinition()
        let budget = ExplorationBudget(
            maxDepth: 6, maxScreens: 30, maxTimeSeconds: 300,
            maxActionsPerScreen: 5, scrollLimit: 0,
            calibrationScrollLimit: 0, skipPatterns: []
        )
        let explorer = BFSExplorer(
            session: session, budget: budget,
            componentDefinitions: [rowDef],
            classifier: RowStubClassifier(definition: rowDef)
        )
        explorer.markStarted()

        let describer = MockExplorerDescriber(screens: [
            ScreenDescriber.DescribeResult(elements: rootElements, screenshotBase64: "img0")
        ])
        let result = explorer.calibrateScreen(
            fingerprint: rootFP, describer: describer, input: MockExplorerInput(),
            icons: bandIcons
        )

        guard case .ok = result else {
            XCTFail("Calibration should pass, got \(result)")
            return
        }
        let plan = graph.screenPlan(for: rootFP) ?? []
        let labels = plan.map { $0.displayLabel }
        XCTAssertFalse(labels.contains("Accueil"),
            "Globally-visited tab must not be re-injected at the calibration site")
        XCTAssertEqual(Array(labels.prefix(4)), ["Recherche", "Reels", "Boutique", "Profil"],
            "Remaining tabs stay at the plan front in declared order")
        XCTAssertEqual(Array(labels.suffix(2)), ["Contacts", "Réglages"],
            "Q-boost must demote the dead-tap row (q=0) below the fresh row")
    }
}
