// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AppPack-aware tap handling for FakeScreenView — dismisses obstacles, navigates via leadsTo.
// ABOUTME: Lives in its own file to keep main.swift under the project's 500-line ceiling.

import AppKit
import HelperLib

extension FakeScreenView {

    /// Resolved scene data for the current frame.
    /// Priority: Spotlight overlay > App Switcher overlay > active AppPack
    /// (obstacle, then current screen) > empty home-screen-style scene.
    func currentSceneData() -> ScenarioData {
        if let spotlight = spotlightOverlay {
            return spotlight.sceneData()
        }
        if let switcher = appSwitcherOverlay {
            return switcher.sceneData()
        }
        if let pack = appPack {
            if let obstacle = pack.activeObstacle {
                return SceneRenderer.render(obstacle)
            }
            if let screen = pack.currentScreen {
                return SceneRenderer.render(screen, tabBarStyle: pack.spec.tabBarStyle)
            }
        }
        // No app foreground — render an empty home-screen-style frame so the
        // window still has chrome (status bar) without any app content.
        return ScenarioData(header: "", rows: [], hasTabBar: false)
    }

    /// Dispatch a tap to the active AppPack: dismiss its obstacle or navigate
    /// to a destination screen. Returns true when the tap was consumed (the
    /// view re-rendered); false to fall through to legacy hit testing.
    func handleAppPackTap(pack: AppPack, at contentPoint: CGPoint, screenPoint: CGPoint) -> Bool {
        let data = currentSceneData()
        NSLog(
            "[fakemirror-tap] handleAppPackTap pack=%@ screen=%@ " +
            "contentPoint=(%.1f,%.1f) screenPoint=(%.1f,%.1f) scrollOffset=%.0f " +
            "rows=%d buttons=%d backChevron=%@ obstacle=%@",
            pack.spec.appName, pack.currentScreen?.id ?? "<none>",
            contentPoint.x, contentPoint.y, screenPoint.x, screenPoint.y,
            scrollOffset,
            data.rows.count, data.buttons.count,
            data.hasBackChevron ? "yes" : "no",
            pack.activeObstacle?.id ?? "none"
        )

        // Active obstacle: any button tap dismisses it.
        if pack.activeObstacle != nil {
            for (_, rect) in data.buttons {
                let adjusted = CGRect(x: rect.minX, y: rect.minY - scrollOffset,
                                      width: rect.width, height: rect.height)
                if adjusted.contains(screenPoint) {
                    pack.dismissActiveObstacle()
                    needsDisplay = true
                    return true
                }
            }
            return false
        }

        // Tab bar tap zone: the bar is fixed chrome at the bottom of the view
        // (not scrolled), drawn by drawTabBar at bounds.height - tabBarHeight
        // with icons centered on tabBarIconXPositions. Map a tap in the bar
        // band to the nearest icon column and navigate via the active screen's
        // `.tab` elements in declaration order — this is what lets explorer
        // taps (text-matched labels or synthesized icon anchors) switch tabs.
        if data.hasTabBar, let screen = pack.currentScreen,
           screenPoint.y >= bounds.height - tabBarHeight {
            let tabs: [(text: String, leadsTo: String)] = screen.elements.compactMap {
                if case .tab(let text, let leadsTo) = $0 { return (text, leadsTo) }
                return nil
            }
            if !tabs.isEmpty,
               let nearest = tabBarIconXPositions.enumerated()
                   .min(by: { abs($0.element - screenPoint.x) < abs($1.element - screenPoint.x) }),
               abs(nearest.element - screenPoint.x) <= 40,
               nearest.offset < tabs.count {
                let tab = tabs[nearest.offset]
                NSLog("[fakemirror-tap] tab bar hit column=%d '%@' → %@",
                      nearest.offset, tab.text, tab.leadsTo)
                pack.navigate(to: tab.leadsTo)
                needsDisplay = true
                return true
            }
        }

        // Back chevron tap zone: a generous top-left strip so OCR-driven taps
        // land inside the hitbox even when the OCR bbox center drifts a bit
        // from the rendered glyph position. The "<" is drawn at view-local
        // y=80 (font ~22pt) and OCR typically reports tapY a bit lower; cover
        // the whole top-left corner up to y=200 to absorb that drift.
        if data.hasBackChevron, let screen = pack.currentScreen, let backTo = screen.backTo {
            let backZone = CGRect(x: 0, y: 0, width: 80, height: 200)
            if backZone.contains(screenPoint) {
                pack.navigate(to: backTo)
                needsDisplay = true
                return true
            }
        }

        // Board tap: the cell under the point leads where its transition says;
        // a cell with none, like any tap on the board, is consumed and stays put.
        if let board = data.board, board.rect.contains(contentPoint) {
            let cell = board.grid.cell(at: contentPoint, in: board.rect)
            let dest = cell.flatMap(board.grid.destination(of:))
            NSLog("[fakemirror-tap] board cell=%@ destination=%@",
                  cell ?? "<none>", dest ?? "<nil>")
            if let dest {
                pack.navigate(to: dest)
                needsDisplay = true
            }
            return true
        }

        // Row tap → navigate via SimulatorElement.leadsTo
        for (label, origin) in data.rows {
            let rowRect = CGRect(x: origin.x - 20, y: origin.y - rowHeight / 2,
                                 width: bounds.width, height: rowHeight)
            let adjusted = CGRect(x: rowRect.minX, y: rowRect.minY - scrollOffset,
                                  width: rowRect.width, height: rowRect.height)
            let hit = adjusted.contains(screenPoint)
            NSLog(
                "[fakemirror-tap] row '%@' rect=(%.0f,%.0f,%.0fx%.0f) hit=%@",
                label, adjusted.minX, adjusted.minY, adjusted.width, adjusted.height,
                hit ? "YES" : "no"
            )
            if hit {
                let dest = destinationFor(label: label, in: pack)
                NSLog("[fakemirror-tap] row '%@' destination=%@", label, dest ?? "<nil>")
                if let dest {
                    pack.navigate(to: dest)
                    needsDisplay = true
                }
                return true
            }
        }

        // Button tap on a regular screen — also navigate via leadsTo.
        // Inflate the hit rect by `buttonHitInset` so OCR tap-center drift
        // (a few points either way on CI runners) still lands inside.
        // Rows already get a row-wide hit zone; this gives buttons the same
        // tolerance, matching the generous back-chevron zone above.
        let buttonHitInset: CGFloat = -16
        for (label, rect) in data.buttons {
            let adjusted = CGRect(x: rect.minX, y: rect.minY - scrollOffset,
                                  width: rect.width, height: rect.height)
                .insetBy(dx: buttonHitInset, dy: buttonHitInset)
            let hit = adjusted.contains(screenPoint)
            NSLog(
                "[fakemirror-tap] button '%@' rect=(%.0f,%.0f,%.0fx%.0f) hit=%@",
                label, adjusted.minX, adjusted.minY, adjusted.width, adjusted.height,
                hit ? "YES" : "no"
            )
            if hit {
                let dest = destinationFor(label: label, in: pack)
                NSLog("[fakemirror-tap] button '%@' destination=%@", label, dest ?? "<nil>")
                if let dest {
                    pack.navigate(to: dest)
                    needsDisplay = true
                }
                return true
            }
        }
        NSLog("[fakemirror-tap] no hit — falling through to legacy handlers")
        return false
    }

    /// Find the leadsTo for an element with matching display text on the active screen.
    fileprivate func destinationFor(label: String, in pack: AppPack) -> String? {
        guard let screen = pack.currentScreen else { return nil }
        for element in screen.elements where element.displayText == label {
            return element.leadsTo
        }
        return nil
    }
}
