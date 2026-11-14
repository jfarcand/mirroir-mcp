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
// ABOUTME: Tests for SimulatorSpecParser — parses the `## Simulator …` H2 sections of APP.md.
// ABOUTME: Covers screens, elements (row/button/text/tab), obstacles, and trigger variants.

import XCTest
@testable import HelperLib

final class SimulatorSpecParserTests: XCTestCase {

    // MARK: - Empty / missing

    func testReturnsNilWhenNoSimulatorSections() {
        let spec = SimulatorSpecParser.parse(
            sections: ["Structure": "prose"],
            frontMatter: ["app": "Settings"],
            appName: "Settings"
        )
        XCTAssertNil(spec)
    }

    // MARK: - Minimal screen-only spec

    func testParsesSingleScreen() {
        let body = """
        - title: Settings
        - tab_bar: false
        - element row: "General" → general
        - element row: "Display" → display
        """
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen main": body],
            frontMatter: ["app": "Settings"],
            appName: "Settings"
        )
        XCTAssertNotNil(spec)
        let main = spec?.screens["main"]
        XCTAssertEqual(main?.title, "Settings")
        XCTAssertEqual(main?.hasTabBar, false)
        XCTAssertEqual(main?.elements.count, 2)
        XCTAssertEqual(main?.elements[0], .row(text: "General", leadsTo: "general"))
        XCTAssertEqual(main?.elements[1], .row(text: "Display", leadsTo: "display"))
    }

    // MARK: - Spotlight name & icon overrides

    func testSpotlightNameAndIconFromFrontmatter() {
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen main": "- title: X"],
            frontMatter: ["app": "Santé", "spotlight_name": "Sante", "icon": "❤️"],
            appName: "Santé"
        )
        XCTAssertEqual(spec?.spotlightName, "Sante")
        XCTAssertEqual(spec?.icon, "❤️")
    }

    func testDefaultsWhenFrontmatterAbsent() {
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen main": "- title: X"],
            frontMatter: ["app": "Settings"],
            appName: "Settings"
        )
        XCTAssertEqual(spec?.spotlightName, "Settings")
        XCTAssertEqual(spec?.icon, "S",
            "Falls back to first character of appName when icon absent")
    }

    // MARK: - Root screen resolution

    func testExplicitRootInSimulatorSection() {
        let spec = SimulatorSpecParser.parse(
            sections: [
                "Simulator": "- root: home",
                "Simulator Screen home": "- title: Home",
                "Simulator Screen detail": "- title: Detail",
            ],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.rootScreenID, "home")
    }

    func testRootDefaultsToAlphabeticallyFirstScreenWhenAbsent() {
        let spec = SimulatorSpecParser.parse(
            sections: [
                "Simulator Screen general": "- title: General",
                "Simulator Screen about": "- title: About",
            ],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.rootScreenID, "about",
            "When no Simulator section, falls back to first screen alphabetically")
    }

    // MARK: - Element kinds

    func testParsesAllElementKinds() {
        let body = """
        - title: Profile
        - element row: "Settings" → settings
        - element button: "Save" → main
        - element button: "Cancel"
        - element text: "Profile picture goes here"
        - element tab: "Home" → home
        """
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen profile": body],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        let elements = spec?.screens["profile"]?.elements ?? []
        XCTAssertEqual(elements.count, 5)
        XCTAssertEqual(elements[0], .row(text: "Settings", leadsTo: "settings"))
        XCTAssertEqual(elements[1], .button(text: "Save", leadsTo: "main"))
        XCTAssertEqual(elements[2], .button(text: "Cancel", leadsTo: nil))
        XCTAssertEqual(elements[3], .text("Profile picture goes here"))
        XCTAssertEqual(elements[4], .tab(text: "Home", leadsTo: "home"))
    }

    func testTabWithoutDestinationIsIgnored() {
        let body = """
        - title: X
        - element tab: "Orphan"
        """
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen x": body],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.screens["x"]?.elements.count, 0,
            "Tab without leads_to is invalid and dropped")
    }

    // MARK: - Back navigation

    func testBackToParsing() {
        let body = """
        - title: General
        - back: main
        """
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen general": body],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.screens["general"]?.backTo, "main")
    }

    func testBackNullMeansRoot() {
        let body = """
        - title: Root
        - back: null
        """
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen root": body],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertNil(spec?.screens["root"]?.backTo)
    }

    // MARK: - Obstacles

    func testParsesObstacle() {
        let obstacleBody = """
        - title: "Software Update Available"
        - body: "iOS 18.5 is available"
        - buttons: Install Now, Later
        - trigger: on_first_describe
        """
        let spec = SimulatorSpecParser.parse(
            sections: [
                "Simulator Screen main": "- title: Settings",
                "Simulator Obstacle update": obstacleBody,
            ],
            frontMatter: ["app": "Settings"],
            appName: "Settings"
        )
        XCTAssertEqual(spec?.obstacles.count, 1)
        let obs = spec?.obstacles.first
        XCTAssertEqual(obs?.id, "update")
        XCTAssertEqual(obs?.title, "Software Update Available")
        XCTAssertEqual(obs?.body, "iOS 18.5 is available")
        XCTAssertEqual(obs?.buttons, ["Install Now", "Later"])
        XCTAssertEqual(obs?.trigger, .onFirstDescribe)
    }

    func testTriggerAfterTaps() {
        let body = """
        - title: T
        - buttons: OK
        - trigger: after_n_taps:5
        """
        let spec = SimulatorSpecParser.parse(
            sections: [
                "Simulator Screen x": "- title: X",
                "Simulator Obstacle late": body,
            ],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.obstacles.first?.trigger, .afterTaps(count: 5))
    }

    func testObstacleWithoutTitleIsDropped() {
        let body = """
        - buttons: OK
        - trigger: on_first_describe
        """
        let spec = SimulatorSpecParser.parse(
            sections: [
                "Simulator Screen x": "- title: X",
                "Simulator Obstacle bad": body,
            ],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.obstacles.count, 0,
            "Obstacle without title is silently dropped")
    }

    // MARK: - Tab bar flag + arrow variants

    func testTabBarTrue() {
        let body = """
        - title: X
        - tab_bar: true
        """
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen x": body],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.screens["x"]?.hasTabBar, true)
    }

    // MARK: - Tab bar style

    func testParsesTabBarStyleIcons() {
        let spec = SimulatorSpecParser.parse(
            sections: [
                "Simulator": "- root: x\n- tab_bar_style: icons",
                "Simulator Screen x": "- title: X\n- tab_bar: true",
            ],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.tabBarStyle, .icons)
    }

    func testTabBarStyleDefaultsToLabels() {
        let spec = SimulatorSpecParser.parse(
            sections: [
                "Simulator": "- root: x",
                "Simulator Screen x": "- title: X\n- tab_bar: true",
            ],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.tabBarStyle, .labels,
            "Absent tab_bar_style falls back to the labeled rendering")
    }

    func testAsciiArrowAccepted() {
        let body = """
        - title: X
        - element row: "Foo" -> bar
        """
        let spec = SimulatorSpecParser.parse(
            sections: ["Simulator Screen x": body],
            frontMatter: ["app": "X"],
            appName: "X"
        )
        XCTAssertEqual(spec?.screens["x"]?.elements.first,
            .row(text: "Foo", leadsTo: "bar"))
    }
}
