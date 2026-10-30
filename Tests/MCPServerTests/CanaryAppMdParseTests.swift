// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Smoke tests that load the canary APP.md files (Settings, Weather, Clock) and assert the simulator block parses.
// ABOUTME: Catches drift between the schema and the on-disk files that ship with mirroir-skills.

import XCTest
@testable import mirroir_mcp
@testable import HelperLib

final class CanaryAppMdParseTests: XCTestCase {

    // MARK: - Settings canary

    func testSettingsAppMdParsesWithSimulatorBlock() throws {
        let description = try loadAppMd(app: "settings")

        XCTAssertEqual(description.appName, "Settings")
        XCTAssertNotNil(description.simulator,
            "Settings APP.md must declare a Simulator block now")

        let sim = description.simulator!
        XCTAssertEqual(sim.spotlightName, "Settings")
        XCTAssertEqual(sim.icon, "⚙")
        XCTAssertEqual(sim.rootScreenID, "main")

        // Spot-check key screens exist
        let mainElements = sim.screens["main"]?.elements ?? []
        XCTAssertTrue(mainElements.contains { $0.displayText == "General" },
            "main screen must offer General row")
        XCTAssertNotNil(sim.screens["general"], "general screen must exist")
        XCTAssertNotNil(sim.screens["about"], "about screen must exist")

        // Back navigation chain
        XCTAssertEqual(sim.screens["general"]?.backTo, "main")
        XCTAssertEqual(sim.screens["about"]?.backTo, "general")
        XCTAssertNil(sim.screens["main"]?.backTo, "main is root, no back")

        // Obstacles declared in APP.md must be present
        let obstacleIDs = sim.obstacles.map { $0.id }
        XCTAssertTrue(obstacleIDs.contains("software_update"))
        XCTAssertTrue(obstacleIDs.contains("signin"))
    }

    // MARK: - Weather canary

    func testWeatherAppMdParsesWithSimulatorBlock() throws {
        let description = try loadAppMd(app: "weather")

        XCTAssertEqual(description.appName, "Weather")
        XCTAssertNotNil(description.simulator,
            "Weather APP.md must declare a Simulator block now")

        let sim = description.simulator!
        XCTAssertEqual(sim.icon, "☀")
        XCTAssertEqual(sim.rootScreenID, "main")

        XCTAssertNotNil(sim.screens["main"])
        XCTAssertNotNil(sim.screens["cities"])
        XCTAssertEqual(sim.screens["cities"]?.backTo, "main")

        let obstacleIDs = sim.obstacles.map { $0.id }
        XCTAssertTrue(obstacleIDs.contains("location_permission"))
    }

    // MARK: - Sante / TikTok / Instagram / Claude canaries

    func testSanteAppMdParses() throws {
        let description = try loadAppMd(app: "sante")
        XCTAssertEqual(description.appName, "Santé")
        XCTAssertEqual(description.simulator?.spotlightName, "Sante")
        XCTAssertEqual(description.simulator?.rootScreenID, "resume")
        let screens = description.simulator?.screens ?? [:]
        XCTAssertNotNil(screens["resume"])
        XCTAssertNotNil(screens["parcourir"])
        XCTAssertNotNil(screens["activite"])
        XCTAssertEqual(screens["activite"]?.backTo, "resume")
    }

    func testTikTokAppMdParses() throws {
        let description = try loadAppMd(app: "tiktok")
        XCTAssertEqual(description.appName, "TikTok")
        XCTAssertEqual(description.simulator?.rootScreenID, "pour_toi")
        XCTAssertNotNil(description.simulator?.screens["explorer"])
        // 5 tabs declared as elements on every tab-bar screen
        let pourToiTabs = description.simulator?.screens["pour_toi"]?.elements
            .compactMap { element -> String? in
                if case .tab(let text, _) = element { return text }
                return nil
            } ?? []
        XCTAssertGreaterThanOrEqual(pourToiTabs.count, 4)
    }

    func testInstagramAppMdParses() throws {
        let description = try loadAppMd(app: "instagram")
        XCTAssertEqual(description.appName, "Instagram")
        XCTAssertEqual(description.simulator?.rootScreenID, "accueil")
        XCTAssertNotNil(description.simulator?.screens["recherche"])
        XCTAssertNotNil(description.simulator?.screens["profil_ig"])
    }

    func testClaudeAppMdParses() throws {
        let description = try loadAppMd(app: "claude")
        XCTAssertEqual(description.appName, "Claude")
        XCTAssertEqual(description.simulator?.icon, "✦")
        XCTAssertEqual(description.simulator?.rootScreenID, "home")
        XCTAssertNotNil(description.simulator?.screens["conversations"])
        XCTAssertNotNil(description.simulator?.screens["composer"])
    }

    // MARK: - Clock golden-journey pack

    func testClockAppMdParses() throws {
        let description = try loadAppMd(app: "clock")

        XCTAssertEqual(description.appName, "Clock")
        XCTAssertEqual(description.tabs, ["World Clock", "Alarms", "Stopwatch", "Timers"])
        XCTAssertTrue(description.skipElements.contains("Delete Alarm"))

        let sim = try XCTUnwrap(description.simulator,
            "Clock APP.md must declare a Simulator block")
        XCTAssertEqual(sim.spotlightName, "Clock")
        XCTAssertEqual(sim.icon, "⏰")
        XCTAssertEqual(sim.rootScreenID, "alarms")
        XCTAssertEqual(Set(sim.screens.keys),
            ["alarms", "add_alarm", "world_clock", "stopwatch", "timers"])
        XCTAssertTrue(sim.obstacles.isEmpty, "Clock declares no simulator obstacle")

        // Golden journey: Alarms → Add Alarm → Save → Alarms, no tab-bar tap.
        let alarms = try XCTUnwrap(sim.screens["alarms"])
        XCTAssertEqual(alarms.title, "Alarms")
        XCTAssertTrue(alarms.hasTabBar)
        XCTAssertNil(alarms.backTo)
        XCTAssertTrue(alarms.elements.contains(.button(text: "Add Alarm", leadsTo: "add_alarm")))
        for label in ["6:30 AM", "Alarm, every weekday", "7:45 AM", "Gym"] {
            XCTAssertTrue(alarms.elements.contains(.text(label)),
                "alarms screen must list '\(label)'")
        }

        let addAlarm = try XCTUnwrap(sim.screens["add_alarm"])
        XCTAssertEqual(addAlarm.title, "Add Alarm")
        XCTAssertFalse(addAlarm.hasTabBar)
        XCTAssertTrue(addAlarm.elements.contains(.button(text: "Save", leadsTo: "alarms")))
        XCTAssertTrue(addAlarm.elements.contains(.button(text: "Cancel", leadsTo: "alarms")))
        XCTAssertEqual(
            addAlarm.elements.compactMap { element -> String? in
                if case .row(let text, _) = element { return text }
                return nil
            },
            ["Repeat", "Label", "Sound", "Snooze"])

        // Every tab-bar screen carries the same four tabs.
        for (id, screen) in sim.screens where screen.hasTabBar {
            let tabs = screen.elements.compactMap { element -> String? in
                if case .tab(let text, _) = element { return text }
                return nil
            }
            XCTAssertEqual(tabs, ["World Clock", "Alarms", "Stopwatch", "Timers"],
                "screen '\(id)' must carry the four Clock tabs")
        }
    }

    /// The "Clock (Drift)" fixture is the Clock scene graph with exactly one
    /// label changed, so a replay recorded against Clock must report one drift.
    /// It is loaded the way FakeMirroring loads packs (sectioning + simulator
    /// parser), since the fixture carries only simulator sections.
    func testClockDriftFixtureDiffersByOneLabel() throws {
        let base = try XCTUnwrap(try loadAppMd(app: "clock").simulator)
        let drift = try loadSimulatorSpec(app: "test_fixtures/clock_drift")

        XCTAssertEqual(drift.appName, "Clock (Drift)")
        XCTAssertEqual(drift.spotlightName, "Clock (Drift)")
        XCTAssertEqual(drift.icon, base.icon)
        XCTAssertEqual(drift.rootScreenID, base.rootScreenID)
        XCTAssertEqual(drift.tabBarStyle, base.tabBarStyle)
        XCTAssertEqual(drift.obstacles, base.obstacles)
        XCTAssertEqual(Set(drift.screens.keys), Set(base.screens.keys))

        var differences: [(screen: String, base: SimulatorElement, drift: SimulatorElement)] = []
        for (id, baseScreen) in base.screens {
            let driftScreen = try XCTUnwrap(drift.screens[id])
            XCTAssertEqual(driftScreen.title, baseScreen.title, "[\(id)] title")
            XCTAssertEqual(driftScreen.backTo, baseScreen.backTo, "[\(id)] back")
            XCTAssertEqual(driftScreen.hasTabBar, baseScreen.hasTabBar, "[\(id)] tab_bar")
            XCTAssertEqual(driftScreen.elements.count, baseScreen.elements.count,
                "[\(id)] element count")
            for (baseElement, driftElement) in zip(baseScreen.elements, driftScreen.elements)
                where baseElement != driftElement {
                differences.append((id, baseElement, driftElement))
            }
        }

        XCTAssertEqual(differences.count, 1, "exactly one label must differ: \(differences)")
        let only = try XCTUnwrap(differences.first)
        XCTAssertEqual(only.screen, "alarms")
        XCTAssertEqual(only.base, .text("Gym"))
        XCTAssertEqual(only.drift, .text("Swim"))
    }

    // MARK: - Drift checker

    /// Walk every APP.md in the skills directory and assert structural integrity:
    ///   1. Every leads_to and back reference points at a screen that exists.
    ///   2. Every obstacle has at least one button.
    ///   3. The root screen ID exists in the screens map.
    func testAllAppMdSimulatorBlocksAreInternallyConsistent() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let appsDir = "\(cwd)/../mirroir-skills/patterns/apps"
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: appsDir)) ?? []

        var packsChecked = 0
        for slug in entries.sorted() {
            let path = "\(appsDir)/\(slug)/APP.md"
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8),
                  let description = AppDescriptionParser.parse(content: content),
                  let sim = description.simulator else { continue }

            let knownIDs = Set(sim.screens.keys)
            XCTAssertTrue(knownIDs.contains(sim.rootScreenID),
                "[\(slug)] root '\(sim.rootScreenID)' must exist in screens")

            for (id, screen) in sim.screens {
                if let backTo = screen.backTo {
                    XCTAssertTrue(knownIDs.contains(backTo),
                        "[\(slug)] screen '\(id)' back='\(backTo)' missing")
                }
                for element in screen.elements {
                    if let leadsTo = element.leadsTo {
                        XCTAssertTrue(knownIDs.contains(leadsTo),
                            "[\(slug)] screen '\(id)' element '\(element.displayText)' " +
                            "leads_to='\(leadsTo)' missing")
                    }
                }
            }
            for obstacle in sim.obstacles {
                XCTAssertFalse(obstacle.buttons.isEmpty,
                    "[\(slug)] obstacle '\(obstacle.id)' must have at least one button")
            }
            packsChecked += 1
        }
        XCTAssertGreaterThanOrEqual(packsChecked, 6,
            "Expected ≥6 packs (settings, weather, sante, tiktok, instagram, claude)")
    }

    // MARK: - Helpers

    private func loadAppMd(app slug: String) throws -> AppDescription {
        // Tests run with the package root as cwd. mirroir-skills is a sibling
        // checkout (per CLAUDE.md "Sibling Repositories"), so go up one level.
        let cwd = FileManager.default.currentDirectoryPath
        let appMdPath = "\(cwd)/../mirroir-skills/patterns/apps/\(slug)/APP.md"

        let content = try String(contentsOfFile: appMdPath, encoding: .utf8)
        guard let description = AppDescriptionParser.parse(content: content) else {
            XCTFail("AppDescriptionParser returned nil for \(slug)")
            throw NSError(domain: "test", code: 1)
        }
        return description
    }

    /// Parse only the simulator sections of a pack, exactly as FakeMirroring's
    /// `AppPackLoader` does — for fixtures that carry no guidance sections.
    private func loadSimulatorSpec(app slug: String) throws -> SimulatorSpec {
        let cwd = FileManager.default.currentDirectoryPath
        let appMdPath = "\(cwd)/../mirroir-skills/patterns/apps/\(slug)/APP.md"
        let content = try String(contentsOfFile: appMdPath, encoding: .utf8)
        let extracted = AppMdSectioning.extract(content: content)
        let appName = try XCTUnwrap(extracted.frontMatter["app"],
            "\(slug) APP.md must declare app: in its front matter")
        return try XCTUnwrap(
            SimulatorSpecParser.parse(
                sections: extracted.sections,
                frontMatter: extracted.frontMatter,
                appName: appName),
            "\(slug) APP.md must declare a Simulator block")
    }
}
