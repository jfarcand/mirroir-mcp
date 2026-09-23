// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Per-skill validation of real skill files under apps/, apps/mail, testing/, workflows/, and ci/.
// ABOUTME: Asserts each shipped skill parses and contains the expected step kinds and targets.

import XCTest
import HelperLib
@testable import mirroir_mcp

extension SkillFileTests {

    // MARK: - Individual skill validation: apps/

    func testCheckAbout() throws {
        let s = try parseSkill("apps/settings/check-about")
        XCTAssertEqual(s.name, "Read Device Info")
        XCTAssertFalse(s.description.isEmpty)
        if !s.steps.isEmpty {
            XCTAssertTrue(s.description.contains("Settings"))
            XCTAssertEqual(s.steps.count, 9)
            assertStepKinds(s.steps, [
                "launch", "wait_for", "tap", "wait_for", "tap",
                "wait_for", "remember", "assert_visible", "screenshot",
            ], file: "check-about")
        }
    }

    func testCheckAboutFr() throws {
        let s = try parseSkill("apps/settings/check-about-fr")
        XCTAssertEqual(s.name, "Vérifier l'écran À propos")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 7)
        }
    }

    func testSetTimer() throws {
        let s = try parseSkill("apps/clock/set-timer")
        XCTAssertEqual(s.name, "Set Timer")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 8)
            assertContains(s, "assert_visible")
        }
    }

    func testSetAlarm() throws {
        let s = try parseSkill("apps/clock/set-alarm")
        XCTAssertEqual(s.name, "Set Alarm")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 10)
            assertContains(s, "type")
        }
    }

    func testCheckToday() throws {
        let s = try parseSkill("apps/calendar/check-today")
        XCTAssertEqual(s.name, "Read Today's Schedule")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 6)
            assertContains(s, "remember")
        }
    }

    func testCreateEvent() throws {
        let s = try parseSkill("apps/calendar/create-event")
        XCTAssertEqual(s.name, "Create Calendar Event")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 11)
        }
    }

    func testCheckForecast() throws {
        let s = try parseSkill("apps/weather/check-forecast")
        XCTAssertEqual(s.name, "Read Weather Forecast")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 8)
            assertContains(s, "swipe")
            assertContains(s, "remember")
        }
    }

    func testAddCity() throws {
        let s = try parseSkill("apps/weather/add-city")
        XCTAssertEqual(s.name, "Add City to Weather")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 12)
        }
    }

    func testSendMessage() throws {
        let s = try parseSkill("apps/slack/send-message")
        XCTAssertEqual(s.name, "Send Slack Message")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 11)
            assertContains(s, "press_key")
        }
    }

    func testCheckUnread() throws {
        let s = try parseSkill("apps/slack/check-unread")
        XCTAssertEqual(s.name, "Read Unread Slack Messages")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 6)
        }
    }

    func testSaveDirections() throws {
        let s = try parseSkill("apps/maps/save-directions")
        XCTAssertEqual(s.name, "Get Directions and Travel Time")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 11)
        }
    }

    func testShareRecent() throws {
        let s = try parseSkill("apps/photos/share-recent")
        XCTAssertEqual(s.name, "Share Recent Photo")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 16)
            // long_press is a recognized step type parsed as .longPress
            let longPress = s.steps.filter {
                if case .longPress = $0 { return true }
                return false
            }
            XCTAssertEqual(longPress.count, 1,
                "Expected exactly 1 long_press step in share-recent")
        }
    }

    func testListApps() throws {
        let s = try parseSkill("apps/settings/list-apps")
        XCTAssertEqual(s.name, "List Installed Apps")
        XCTAssertTrue(s.description.contains("iPhone Storage"))
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 14)
            assertContains(s, "remember")
            assertContains(s, "swipe")
        }
    }

    func testInstallApp() throws {
        let s = try parseSkill("apps/appstore/install-app")
        XCTAssertEqual(s.name, "Install App from App Store")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 17)
            assertContains(s, "condition")
            assertContains(s, "press_key")
        }
    }

    func testUninstallApp() throws {
        let s = try parseSkill("apps/settings/uninstall-app")
        XCTAssertEqual(s.name, "Uninstall App")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 13)
            assertContains(s, "scroll_to")
        }
    }

    // MARK: - Individual skill validation: apps/mail

    func testEmailTriage() throws {
        let s = try parseSkill("apps/mail/email-triage")
        XCTAssertEqual(s.name, "Email Triage")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 13)
            // Two nested condition blocks are flattened by the parser
            let conditions = s.steps.filter {
                if case .skipped(let t, _) = $0, t == "condition" { return true }
                return false
            }
            XCTAssertEqual(conditions.count, 2, "Expected 2 nested conditions")
        }
    }

    func testBatchArchive() throws {
        let s = try parseSkill("apps/mail/batch-archive")
        XCTAssertEqual(s.name, "Batch Archive Inbox")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 12)
            assertContains(s, "repeat")
            assertContains(s, "assert_not_visible")
        }
    }

    // MARK: - Individual skill validation: testing/

    func testLoginFlow() throws {
        let s = try parseSkill("testing/expo-go/login-flow")
        XCTAssertEqual(s.name, "Expo Go Login Flow")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 20)
            assertContains(s, "condition")
        }
    }

    func testShakeDebugMenu() throws {
        let s = try parseSkill("testing/expo-go/shake-debug-menu")
        XCTAssertEqual(s.name, "Expo Go Debug Menu")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 7)
            assertContains(s, "shake")
        }
    }

    func testQASmokePack() throws {
        let s = try parseSkill("testing/expo-go/qa-smoke-pack")
        XCTAssertEqual(s.name, "Visual Regression Test")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 15)
            assertContains(s, "remember")
        }
    }

    // MARK: - Individual skill validation: workflows/

    func testCommuteETA() throws {
        let s = try parseSkill("workflows/commute-eta-notify")
        XCTAssertEqual(s.name, "Commute ETA Notification")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 26)
            assertContains(s, "home")
            assertContains(s, "press_key")
            assertContains(s, "remember")
        }
    }

    func testMorningBriefing() throws {
        let s = try parseSkill("workflows/morning-briefing")
        XCTAssertEqual(s.name, "Morning Briefing")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 25)
            assertContains(s, "home")
            assertContains(s, "remember")
        }
    }

    func testStandupAutoposter() throws {
        let s = try parseSkill("workflows/standup-autoposter")
        XCTAssertEqual(s.name, "Standup Autoposter")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 20)
            assertContains(s, "home")
            assertContains(s, "press_key")
        }
    }

    // MARK: - Individual skill validation: ci/

    func testFakeMirroringCheck() throws {
        let s = try parseSkill("ci/fake-mirroring-check")
        XCTAssertEqual(s.name, "FakeMirroring smoke test")
        if !s.steps.isEmpty {
            XCTAssertEqual(s.steps.count, 10)
            assertContains(s, "home")
            assertContains(s, "assert_not_visible")
        }
    }
}
