// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ComponentLoader: loading and merging component definitions.
// ABOUTME: Verifies built-in catalog loading, disk override behavior, and search path ordering.

import XCTest
@testable import mirroir_mcp

final class ComponentLoaderTests: XCTestCase {

    // MARK: - Built-in Catalog

    func testLoadAllReturnsBuiltInDefinitions() {
        let definitions = ComponentLoader.loadAll()

        // Should include all 18 built-in definitions at minimum
        XCTAssertGreaterThanOrEqual(definitions.count, 18,
            "Should load all built-in component definitions")
    }

    func testBuiltInDefinitionsHaveUniqueNames() {
        let definitions = ComponentLoader.loadAll()
        let names = definitions.map { $0.name }
        let uniqueNames = Set(names)

        XCTAssertEqual(names.count, uniqueNames.count,
            "All component names should be unique")
    }

    func testBuiltInCatalogContainsTableRowDisclosure() {
        let definitions = ComponentLoader.loadAll()
        let names = Set(definitions.map { $0.name })

        XCTAssertTrue(names.contains("table-row-disclosure"),
            "Built-in catalog should contain table-row-disclosure")
        XCTAssertTrue(names.contains("navigation-bar"),
            "Built-in catalog should contain navigation-bar")
        XCTAssertTrue(names.contains("tab-bar-item"),
            "Built-in catalog should contain tab-bar-item")
        XCTAssertTrue(names.contains("summary-card"),
            "Built-in catalog should contain summary-card")
    }

    func testTableRowDisclosureDefinition() {
        let definitions = ComponentLoader.loadAll()
        let disclosure = definitions.first { $0.name == "table-row-disclosure" }

        XCTAssertNotNil(disclosure)
        XCTAssertEqual(disclosure?.matchRules.rowHasChevron, true)
        XCTAssertTrue(disclosure?.interaction.clickable ?? false)
        XCTAssertEqual(disclosure?.interaction.clickResult, .pushesScreen)
        XCTAssertEqual(disclosure?.matchRules.zone, .content)
    }

    func testNavigationBarDefinition() {
        let definitions = ComponentLoader.loadAll()
        let navBar = definitions.first { $0.name == "navigation-bar" }

        XCTAssertNotNil(navBar)
        XCTAssertTrue(navBar?.interaction.clickable ?? false)
        XCTAssertEqual(navBar?.interaction.clickResult, .dismisses,
            "Navigation bar back button dismisses the current screen")
        XCTAssertEqual(navBar?.matchRules.zone, .navBar)
    }

    func testToggleRowIsClickable() {
        let definitions = ComponentLoader.loadAll()
        let toggle = definitions.first { $0.name == "toggle-row" }

        XCTAssertNotNil(toggle)
        XCTAssertTrue(toggle?.interaction.clickable ?? false,
            "Toggle rows are interactive UI elements")
        XCTAssertEqual(toggle?.interaction.clickResult, .mutatesInPlace,
            "Toggle rows mutate state in place")
    }

    func testExplanationTextAbsorbsBelow() {
        let definitions = ComponentLoader.loadAll()
        let explanation = definitions.first { $0.name == "explanation-text" }

        XCTAssertNotNil(explanation)
        XCTAssertGreaterThan(explanation?.grouping.absorbsBelowWithinPt ?? 0, 0,
            "Explanation text should absorb nearby elements below")
        XCTAssertEqual(explanation?.grouping.absorbCondition, .infoOrDecorationOnly)
    }

    // MARK: - Search Paths

    func testSearchPathsIncludeLocalAndGlobal() {
        let paths = ComponentLoader.searchPaths()
        XCTAssertGreaterThanOrEqual(paths.count, 2,
            "Should include at least local and global search paths")

        let pathStrings = paths.map { $0.path }
        XCTAssertTrue(pathStrings.contains { $0.contains(".mirroir-mcp/components") },
            "Should include .mirroir-mcp/components in search paths")
    }

    func testSearchPathsIncludeSkillsRepo() {
        let paths = ComponentLoader.searchPaths()
        let pathStrings = paths.map { $0.path }

        XCTAssertTrue(pathStrings.contains { $0.contains("mirroir-skills/components") },
            "Should include mirroir-skills/components in search paths")
    }

    func testSearchPathsIncludeConfigDirSkillsRepo() {
        let paths = ComponentLoader.searchPaths()
        let pathStrings = paths.map { $0.path }

        XCTAssertTrue(pathStrings.contains { $0.contains(".mirroir-mcp/skills/components/ios") },
            "Should include .mirroir-mcp/skills/components/ios for CI environments")
    }

    // MARK: - Catalog Completeness

    func testAllBuiltInComponentsHaveDescriptions() {
        let definitions = ComponentLoader.loadAll()
        for definition in definitions {
            XCTAssertFalse(definition.description.isEmpty,
                "Component '\(definition.name)' should have a description")
        }
    }

    func testModalSheetDefinition() {
        let definitions = ComponentLoader.loadAll()
        let modalSheet = definitions.first { $0.name == "modal-sheet" }

        XCTAssertNotNil(modalSheet)
        XCTAssertTrue(modalSheet?.interaction.clickable ?? false,
            "Modal sheet should be clickable (to dismiss)")
        XCTAssertEqual(modalSheet?.interaction.clickTarget, .firstDismissButton)
        XCTAssertEqual(modalSheet?.interaction.clickResult, .dismisses)
        XCTAssertEqual(modalSheet?.matchRules.hasDismissButton, true)
        XCTAssertFalse(modalSheet?.interaction.backAfterClick ?? true,
            "Modal sheet dismiss should not need back navigation")
    }

    func testBottomNavigationBarNotClickable() {
        let definitions = ComponentLoader.loadAll()
        let bottomNav = definitions.first { $0.name == "bottom-navigation-bar" }

        XCTAssertNotNil(bottomNav,
            "Should load bottom-navigation-bar component")
        XCTAssertFalse(bottomNav?.interaction.clickable ?? true,
            "Bottom navigation bar should not be clickable")
        XCTAssertEqual(bottomNav?.interaction.clickTarget, ClickTargetRule.none)
        XCTAssertEqual(bottomNav?.matchRules.zone, .tabBar,
            "Bottom navigation bar should be in tab_bar zone")
        XCTAssertGreaterThanOrEqual(bottomNav?.matchRules.minElements ?? 0, 2,
            "Bottom navigation bar requires at least 2 elements")
    }

    func testTabBarItemIsClickable() {
        let definitions = ComponentLoader.loadAll()
        let tabBarItem = definitions.first { $0.name == "tab-bar-item" }

        XCTAssertNotNil(tabBarItem)
        XCTAssertTrue(tabBarItem?.interaction.clickable ?? false,
            "Tab bar items are interactive navigation elements")
        XCTAssertEqual(tabBarItem?.interaction.clickResult, .switchesContext,
            "Tab bar items switch context, not push screens")
        XCTAssertEqual(tabBarItem?.interaction.clickTarget, .firstText)
    }

    func testTabBarItemExplorationPolicy() {
        let definitions = ComponentLoader.loadAll()
        let tabBarItem = definitions.first { $0.name == "tab-bar-item" }

        XCTAssertNotNil(tabBarItem)
        XCTAssertTrue(tabBarItem?.exploration.explorable ?? false,
            "Tab bar items should be explorable for app coverage")
        XCTAssertEqual(tabBarItem?.exploration.role, .breadthNavigation,
            "Tab bar items are breadth navigation (top-level)")
        XCTAssertEqual(tabBarItem?.exploration.priority, .high,
            "Tab bar items have high exploration priority")
    }

    func testNonExplorableClickableComponents() {
        let definitions = ComponentLoader.loadAll()
        let nonExplorable = ["navigation-bar", "modal-sheet", "alert-dialog",
                             "toggle-row", "search-bar"]
        for name in nonExplorable {
            let def = definitions.first { $0.name == name }
            XCTAssertNotNil(def, "Should load \(name)")
            XCTAssertTrue(def?.interaction.clickable ?? false,
                "\(name) should be clickable (UI truth)")
            XCTAssertFalse(def?.exploration.explorable ?? true,
                "\(name) should NOT be explorable (exploration policy)")
        }
    }

    func testExplorationDefaultsMatchClickable() {
        let definitions = ComponentLoader.loadAll()
        for definition in definitions {
            if !definition.interaction.clickable {
                XCTAssertFalse(definition.exploration.explorable,
                    "Non-clickable component '\(definition.name)' should default to non-explorable")
            }
        }
    }

    func testAllClickableComponentsHaveTapTargetRule() {
        let definitions = ComponentLoader.loadAll()
        for definition in definitions {
            if definition.interaction.clickable {
                XCTAssertNotEqual(definition.interaction.clickTarget, .none,
                    "Clickable component '\(definition.name)' should have a tap target rule")
            }
        }
    }

    func testTabBarItemHasFirstTextLabelRule() {
        let definitions = ComponentLoader.loadAll()
        let tabBarItem = definitions.first { $0.name == "tab-bar-item" }

        XCTAssertNotNil(tabBarItem)
        XCTAssertEqual(tabBarItem?.interaction.labelRule, .firstText,
            "Tab bar items should use first_text label rule to skip icon artifacts")
    }

    func testNavigationBarHasLongestTextLabelRule() {
        let definitions = ComponentLoader.loadAll()
        let navBar = definitions.first { $0.name == "navigation-bar" }

        XCTAssertNotNil(navBar)
        XCTAssertEqual(navBar?.interaction.labelRule, .longestText,
            "Navigation bar should use longest_text label rule to pick the title")
    }

    func testSummaryCardHasLongestTextLabelRule() {
        let definitions = ComponentLoader.loadAll()
        let card = definitions.first { $0.name == "summary-card" }

        XCTAssertNotNil(card)
        XCTAssertEqual(card?.interaction.labelRule, .longestText,
            "Summary card should use longest_text label rule for metric title")
    }

    func testDefaultLabelRuleIsTapTarget() {
        let definitions = ComponentLoader.loadAll()
        let disclosure = definitions.first { $0.name == "table-row-disclosure" }

        XCTAssertNotNil(disclosure)
        XCTAssertEqual(disclosure?.interaction.labelRule, .tapTarget,
            "Components without explicit label_rule should default to tap_target")
    }
}
