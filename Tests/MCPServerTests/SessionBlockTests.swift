// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that every iPhone Mirroring interstitial reads as paused and maps to the move that frees it.
// ABOUTME: Runs the English and fr_CA fixture corpus, and pins the refusal text and phrase normalization.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SessionBlockTests: XCTestCase {

    private let englishOnly = InterstitialPhrases(localize: { _ in [] })
    private let frenchCanadian = InterstitialPhrases(localize: { key in
        InterstitialFixtures.frenchCanadian[key].map { [$0] } ?? []
    })

    // MARK: - Corpus

    func testEveryEnglishInterstitialReadsAsPausedAndNamesItsMove() {
        for fixture in InterstitialFixtures.english {
            XCTAssertEqual(
                MirroringWindowResolver.state(of: fixture.window) { true }, .paused, fixture.name)
            XCTAssertEqual(
                SessionBlockClassifier.block(of: fixture.window, phrases: englishOnly).move,
                fixture.move, fixture.name)
        }
    }

    func testEveryFrenchInterstitialNamesItsMove() {
        for fixture in InterstitialFixtures.french {
            XCTAssertEqual(
                SessionBlockClassifier.block(of: fixture.window, phrases: frenchCanadian).move,
                fixture.move, fixture.name)
        }
    }

    func testFrenchWordsAreUnknownWithoutTheMacsLanguage() {
        let inUse = InterstitialFixtures.french[0]
        XCTAssertEqual(
            SessionBlockClassifier.block(of: inUse.window, phrases: englishOnly).move, .clearOnMac)
    }

    // MARK: - Quoting

    func testToolbarChromeIsNeverQuoted() {
        let touchID = InterstitialFixtures.english.first { $0.name == "touch id sheet" }
        let quoted = touchID.map { SessionBlockClassifier.labels(of: $0.window) } ?? []
        XCTAssertFalse(quoted.contains("[Home Screen]"), "\(quoted)")
        XCTAssertFalse(quoted.contains("[App Switcher]"), "\(quoted)")
        XCTAssertTrue(quoted.contains("[Cancel]"), "\(quoted)")
    }

    func testRefusalQuotesTheWindowAndSaysNothingWasSent() {
        let inUse = InterstitialFixtures.english[0]
        let refusal = SessionBlockClassifier.block(of: inUse.window, phrases: englishOnly)
            .refusal(targetName: "iphone")
        XCTAssertTrue(refusal.hasPrefix("'iphone' is not accepting input. The window says: “iPhone in Use”"),
                      refusal)
        XCTAssertTrue(refusal.contains("[Try Again]"), refusal)
        XCTAssertTrue(refusal.contains("lock the iPhone"), refusal)
        XCTAssertTrue(refusal.hasSuffix("No input was sent. " + AgentInstruction.waitForUser), refusal)
    }

    func testAWindowWithNoWordsSaysSo() {
        let block = SessionBlock(quoted: [], move: .clearOnMac)
        XCTAssertTrue(block.refusal(targetName: "iphone").contains("an interruption with no text"))
    }

    func testQuotingIsBounded() {
        let many = (1...10).map { InterstitialFixtures.text("line \($0)") }
        let fixture = InterstitialFixtures.overlay("many", many, .clearOnMac)
        XCTAssertEqual(SessionBlockClassifier.block(of: fixture.window, phrases: englishOnly).quoted.count,
                       SessionBlockClassifier.maxQuotedLabels)
    }

    // MARK: - Credential prompts outrank the words

    func testATextFieldIsACredentialPromptWhateverItSays() {
        let fixture = InterstitialFixtures.overlay("field", [
            InterstitialFixtures.text("iPhone in Use"),
            AXNodeSnapshot(role: "AXTextField"),
        ], .approveOnMac)
        XCTAssertEqual(SessionBlockClassifier.block(of: fixture.window, phrases: englishOnly).move,
                       .approveOnMac)
    }

    func testThePlainResumeOverlayIsNotACredentialPrompt() {
        let paused = InterstitialFixtures.english.first { $0.name == "connection paused" }
        XCTAssertEqual(paused.map { SessionBlockClassifier.hasCredentialPrompt($0.window) }, false)
    }

    // MARK: - Phrases

    func testNormalizationFoldsTypographicCharacters() {
        XCTAssertEqual(InterstitialPhrases.normalize("Wi\u{2011}Fi\u{00A0}Off"), "wi-fi off")
        XCTAssertEqual(InterstitialPhrases.normalize("d’utilisation"), "d'utilisation")
        XCTAssertEqual(InterstitialPhrases.normalize("  Lock\n\nyour   iPhone "), "lock your iphone")
    }

    func testFragmentsSplitOnPlaceholdersAndParagraphs() {
        XCTAssertEqual(InterstitialPhrases.fragments("Connecting to %@"), ["connecting to"])
        XCTAssertEqual(
            InterstitialPhrases.fragments("Ended.\n\nLock your iPhone to connect."),
            ["ended.", "lock your iphone to connect."])
        XCTAssertEqual(
            InterstitialPhrases.fragments("Touch ID or enter the Mac login for “%@” to continue."),
            ["touch id or enter the mac login for"])
    }

    /// Every move the window's words can pick has words to pick it. The five
    /// left out are picked without words: the two fallbacks, and the locked
    /// Mac, the hidden app and the quit app, which the system reports.
    func testEveryMoveTheWindowCanNameHasPhrases() {
        let covered = Set(englishOnly.entries.filter { !$0.fragments.isEmpty }.map(\.move))
        XCTAssertEqual(covered, Set(SessionBlockMove.allCases)
            .subtracting([.clearOnMac, .reopenMirroring, .unlockMac, .showMirroring, .reopenAfterQuit]))
    }

    /// Measured 2026-11-03: with "Connection Paused" on screen, AXMainWindow
    /// answered with the application element, whose subtree is only menus.
    func testAnUnreadableWindowIsBlockedAndAsksForAReopen() {
        let appElement = AXNodeSnapshot(role: "AXApplication", label: "iPhone Mirroring", children: [
            AXNodeSnapshot(role: "AXMenuBar", children: [AXNodeSnapshot(role: "AXMenuBarItem", label: "View")]),
        ])
        let window = MirroringAXWindow(title: "iPhone Mirroring", frame: nil,
                                       hostingView: appElement, isWindow: false)
        XCTAssertEqual(MirroringWindowResolver.state(of: window) { false }, .paused)
        let block = SessionBlockClassifier.block(of: window, phrases: englishOnly)
        XCTAssertEqual(block.move, .reopenMirroring)
        XCTAssertTrue(block.refusal(targetName: "iphone")
            .contains("The window says: nothing Accessibility can read."))
    }

    /// The live table always carries the English keys, whatever the Mac's
    /// language and whether or not the app's strings framework was found.
    func testTheLiveTableAlwaysMatchesEnglish() {
        XCTAssertEqual(InterstitialPhrases.live.move(for: ["iPhone in Use"]), .lockIPhone)
        XCTAssertEqual(InterstitialPhrases.live.move(for: ["Wi-Fi Off"]), .turnOnMacWiFi)
    }
}
