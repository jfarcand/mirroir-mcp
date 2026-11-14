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
// ABOUTME: Unit tests for MenuShortcuts: maps the three iPhone Mirroring View-menu nav items to their Cmd+digit keycodes.
// ABOUTME: Used as a locale-invariant fallback when AX menu lookup misses on translated macOS locales.

import XCTest
@testable import mirroir_mcp

final class MenuShortcutsTests: XCTestCase {

    func testHomeScreenMapsToCmd1() {
        let s = MenuShortcuts.viewNavShortcut(for: "Home Screen")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.keycode, 0x12)  // kVK_ANSI_1
        XCTAssertEqual(s?.label, "1")
    }

    func testAppSwitcherMapsToCmd2() {
        let s = MenuShortcuts.viewNavShortcut(for: "App Switcher")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.keycode, 0x13)  // kVK_ANSI_2
        XCTAssertEqual(s?.label, "2")
    }

    func testSpotlightMapsToCmd3() {
        let s = MenuShortcuts.viewNavShortcut(for: "Spotlight")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.keycode, 0x14)  // kVK_ANSI_3
        XCTAssertEqual(s?.label, "3")
    }

    func testCaseInsensitiveMatch() {
        XCTAssertNotNil(MenuShortcuts.viewNavShortcut(for: "home screen"))
        XCTAssertNotNil(MenuShortcuts.viewNavShortcut(for: "HOME SCREEN"))
        XCTAssertNotNil(MenuShortcuts.viewNavShortcut(for: "HoMe ScReEn"))
    }

    func testReturnsNilForUnknownItem() {
        XCTAssertNil(MenuShortcuts.viewNavShortcut(for: "Quit iPhone Mirroring"))
        XCTAssertNil(MenuShortcuts.viewNavShortcut(for: "Settings"))
        XCTAssertNil(MenuShortcuts.viewNavShortcut(for: ""))
    }

    func testReturnsNilForLocalizedTitles() {
        // Localized titles intentionally do NOT match — callers reach the
        // shortcut path only after AX-by-title misses, where the *English*
        // name is still the lookup key. Translated strings would never be
        // passed to viewNavShortcut.
        XCTAssertNil(MenuShortcuts.viewNavShortcut(for: "查看"))
        XCTAssertNil(MenuShortcuts.viewNavShortcut(for: "聚焦搜索"))
        XCTAssertNil(MenuShortcuts.viewNavShortcut(for: "Affichage"))
    }
}
