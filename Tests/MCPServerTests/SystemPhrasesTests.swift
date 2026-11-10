// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the system-phrases.md data compiled into the binary: the words iOS draws on its system screens.
// ABOUTME: Also checks the titles of the resume buttons, which come from iPhone Mirroring's own strings instead.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SystemPhrasesTests: XCTestCase {

    func testParsesLockScreenBulletsLowerCased() {
        let phrases = SystemPhrases.parse(content: """
            ---
            name: system-phrases
            ---
            # System Phrases

            ## Lock Screen

            Text of the lock screen.

            - Enter Passcode
            -   Saisir le code
            - 

            ## Something Else

            - not a lock phrase
            """)
        XCTAssertEqual(phrases.lockScreen, ["enter passcode", "saisir le code"])
    }

    func testAFileWithoutTheSectionYieldsNoPhrases() {
        XCTAssertEqual(SystemPhrases.parse(content: "# System Phrases\n\n## Other\n\n- x\n").lockScreen, [])
    }

    /// A Homebrew or npx install ships the binary alone: no skills checkout,
    /// no `~/.mirroir-mcp/skills`. The words come with the binary, so
    /// launch_app, the alert detector and the lock-screen check work there;
    /// without them every launch is refused.
    func testTheBinaryCarriesEverySectionWithoutAnyCheckout() {
        let shipped = SystemPhrases.parse(content: SystemPhrases.shippedContent)
        for section in SystemPhrases.Section.allCases {
            XCTAssertFalse(shipped.phrases(section).isEmpty, "\(section.rawValue) is not in the binary")
        }
        XCTAssertEqual(SystemPhrases.live, shipped, "the detectors run on the compiled copy, nothing else")
    }

    /// The English and French words the detectors were measured with.
    func testTheShippedWordsHoldWhatTheDetectorsWereMeasuredWith() {
        let phrases = SystemPhrases.live
        XCTAssertEqual(phrases.phrases(.alertDismiss).first, "don't allow", "the most conservative button leads")
        XCTAssertTrue(phrases.phrases(.spotlightTopHit).contains("top hit"))
        XCTAssertTrue(phrases.phrases(.spotlightOpen).contains("ouvrir"))
        XCTAssertTrue(phrases.lockScreen.contains("enter passcode"))
        XCTAssertTrue(phrases.lockScreen.contains("slide to unlock"))
    }

    func testEachHeadingFillsItsOwnSectionAndOthersAreIgnored() {
        let phrases = SystemPhrases.parse(content: """
            ## Spotlight Open

            - Open
            - Ouvrir

            ## Something Else

            - ignored

            ## Alert Dismiss

            - Don’t Allow
            - OK
            """)
        XCTAssertEqual(phrases.phrases(.spotlightOpen), ["open", "ouvrir"])
        XCTAssertEqual(phrases.phrases(.alertDismiss), ["don't allow", "ok"], "curly apostrophe folded")
        XCTAssertEqual(phrases.lockScreen, [])
    }

    /// iOS draws a curly apostrophe; the data file is typed with a straight one.
    func testACurlyApostropheOnScreenMatchesTheStraightOneInTheData() {
        let alert = AlertDetector.detectAlert(elements: [
            TapPoint(text: "“Maps” Would Like to Use Your Location", tapX: 200, tapY: 300, confidence: 0.9),
            TapPoint(text: "Don’t Allow", tapX: 120, tapY: 420, confidence: 0.9),
            TapPoint(text: "Allow Once", tapX: 280, tapY: 420, confidence: 0.9),
        ])
        XCTAssertEqual(alert?.dismissTarget.text, "Don’t Allow")
    }

    // MARK: - Resume buttons, from iPhone Mirroring's own strings

    func testResumeTitlesAreEnglishPlusTheMacsLanguage() {
        let french = InterstitialFixtures.frenchCanadianPhrases
        for title in ["Réessayer", "Connexion", "Reprendre", "Try Again", "Connect", "Resume", "OK"] {
            XCTAssertTrue(french.isResumeControl(label: title), title)
        }
        let english = InterstitialFixtures.englishPhrases
        XCTAssertTrue(english.isResumeControl(label: "Try Again"))
        XCTAssertFalse(english.isResumeControl(label: "Réessayer"))
        XCTAssertEqual(InterstitialPhrases.resumeControlKeys, ["OK", "Resume", "Try Again", "Connect"])
    }

    func testResumeTitleMatchFoldsCaseAndSpaces() {
        let english = InterstitialFixtures.englishPhrases
        XCTAssertTrue(english.isResumeControl(label: " OK "))
        XCTAssertTrue(english.isResumeControl(label: "try\u{00A0}again"))
    }

    /// Pressing the wrong overlay button can quit iPhone Mirroring, so a
    /// button that is unlabeled or says anything else is never a resume control.
    func testUnlabeledAndOtherButtonsAreNeverResumeControls() {
        let french = InterstitialFixtures.frenchCanadianPhrases
        for title in [nil, "", "  ", "Close", "Quit", "Disconnect", "Cancel", "Continuer", "Continue"] {
            XCTAssertFalse(french.isResumeControl(label: title), title ?? "nil")
        }
    }
}
