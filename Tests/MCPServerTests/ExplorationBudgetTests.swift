// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for ExplorationBudget: limit enforcement and element skip patterns.
// ABOUTME: Verifies depth, screen count, time limits, and dangerous action filtering.

import XCTest
@testable import mirroir_mcp

final class ExplorationBudgetTests: XCTestCase {

    // MARK: - Default Budget

    func testDefaultBudgetValues() {
        let budget = ExplorationBudget.default

        XCTAssertEqual(budget.maxDepth, 6)
        XCTAssertEqual(budget.maxScreens, 30)
        XCTAssertEqual(budget.maxTimeSeconds, 300)
        XCTAssertEqual(budget.maxActionsPerScreen, 5)
        XCTAssertEqual(budget.scrollLimit, 3)
        XCTAssertEqual(budget.calibrationScrollLimit, 15)
        XCTAssertFalse(budget.skipPatterns.isEmpty, "Default budget includes built-in safety skip patterns")
    }

    // MARK: - isExhausted

    func testNotExhaustedWithinLimits() {
        let budget = ExplorationBudget.default

        XCTAssertFalse(budget.isExhausted(depth: 3, screenCount: 10, elapsedSeconds: 60))
    }

    func testExhaustedByDepth() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.isExhausted(depth: 6, screenCount: 5, elapsedSeconds: 30))
    }

    func testExhaustedByScreenCount() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.isExhausted(depth: 2, screenCount: 30, elapsedSeconds: 30))
    }

    func testExhaustedByTime() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.isExhausted(depth: 2, screenCount: 5, elapsedSeconds: 300))
    }

    func testCustomBudgetLimits() {
        let budget = ExplorationBudget(
            maxDepth: 3,
            maxScreens: 10,
            maxTimeSeconds: 60,
            maxActionsPerScreen: 3,
            scrollLimit: 2,
            skipPatterns: ["Delete"]
        )

        XCTAssertFalse(budget.isExhausted(depth: 2, screenCount: 9, elapsedSeconds: 59))
        XCTAssertTrue(budget.isExhausted(depth: 3, screenCount: 5, elapsedSeconds: 30))
        XCTAssertTrue(budget.isExhausted(depth: 1, screenCount: 10, elapsedSeconds: 30))
        XCTAssertTrue(budget.isExhausted(depth: 1, screenCount: 5, elapsedSeconds: 60))
    }

    func testCustomCalibrationScrollLimit() {
        let budget = ExplorationBudget(
            maxDepth: 3,
            maxScreens: 10,
            maxTimeSeconds: 60,
            maxActionsPerScreen: 3,
            scrollLimit: 2,
            calibrationScrollLimit: 20,
            skipPatterns: []
        )

        XCTAssertEqual(budget.scrollLimit, 2)
        XCTAssertEqual(budget.calibrationScrollLimit, 20)
    }

    func testCalibrationScrollLimitPassesThroughMerge() {
        let budget = ExplorationBudget(
            maxDepth: 3,
            maxScreens: 10,
            maxTimeSeconds: 60,
            maxActionsPerScreen: 3,
            scrollLimit: 2,
            calibrationScrollLimit: 25,
            skipPatterns: []
        )

        let merged = budget.mergedWith(["extra"])
        XCTAssertEqual(merged.calibrationScrollLimit, 25,
            "calibrationScrollLimit should pass through mergedWith()")
        XCTAssertEqual(merged.scrollLimit, 2)
    }

    // MARK: - shouldSkipElement

    func testSkipDestructiveActions() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Delete Account"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Sign Out"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Log Out"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Reset All Settings"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Erase All Content"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Remove All"))
    }

    func testSkipIsCaseInsensitive() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "delete account"))
        XCTAssertTrue(budget.shouldSkipElement(text: "SIGN OUT"))
    }

    func testDoNotSkipSafeElements() {
        let budget = ExplorationBudget.default

        XCTAssertFalse(budget.shouldSkipElement(text: "General"))
        XCTAssertFalse(budget.shouldSkipElement(text: "About"))
        XCTAssertFalse(budget.shouldSkipElement(text: "Privacy"))
        XCTAssertFalse(budget.shouldSkipElement(text: "Display & Brightness"))
    }

    // MARK: - French Destructive Actions

    func testSkipFrenchDestructiveActions() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Supprimer le compte"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Déconnexion"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Se déconnecter"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Réinitialiser tous les réglages"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Effacer contenu et réglages"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Tout supprimer"))
    }

    // MARK: - Spanish Destructive Actions

    func testSkipSpanishDestructiveActions() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Eliminar cuenta"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Cerrar sesión"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Restablecer ajustes"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Borrar contenido"))
    }

    // MARK: - Network Toggles

    func testSkipNetworkToggles() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Airplane Mode"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Mode Avion"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Modo avión"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Flugmodus"))
    }

    // MARK: - Ad/Sponsored Content

    func testSkipsAdContent() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Sponsored"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Promoted Post"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Advertisement"))
        XCTAssertTrue(budget.shouldSkipElement(text: "ORDER NOW"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Buy Now"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Install Now"))
    }

    func testSkipsAdContentCaseInsensitive() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "sponsored content"))
        XCTAssertTrue(budget.shouldSkipElement(text: "buy now button"))
    }

    // MARK: - Purchase Actions

    func testSkipPurchaseActions() {
        let budget = ExplorationBudget.default

        XCTAssertTrue(budget.shouldSkipElement(text: "Subscribe Now"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Purchase"))
        XCTAssertTrue(budget.shouldSkipElement(text: "S'abonner"))
        XCTAssertTrue(budget.shouldSkipElement(text: "Acheter"))
    }
}
