// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the loader of system-phrases.md, the pattern data file holding the words iOS draws on its system screens.
// ABOUTME: Also checks the titles of the resume buttons, which come from iPhone Mirroring's own strings instead.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class SystemPhrasesTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemPhrasesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ content: String, in folder: String) throws -> String {
        let dir = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(SystemPhrases.fileName).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

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

    func testLoadTakesTheFirstCandidateThatExists() throws {
        let missing = directory.appendingPathComponent("absent/\(SystemPhrases.fileName)").path
        let first = try write("## Lock Screen\n\n- first\n", in: "a")
        let second = try write("## Lock Screen\n\n- second\n", in: "b")
        XCTAssertEqual(SystemPhrases.load(candidates: [missing, first, second]).lockScreen, ["first"])
    }

    func testNoFileAnywhereYieldsNoPhrases() {
        let missing = directory.appendingPathComponent("absent/\(SystemPhrases.fileName)").path
        XCTAssertEqual(SystemPhrases.load(candidates: [missing]), SystemPhrases(lockScreen: []))
    }

    /// The skills checkout ships the file, where the explorer looks for it.
    func testTheSkillsCheckoutDeclaresTheLockScreenPhrases() {
        let phrases = SystemPhrases.load().lockScreen
        XCTAssertTrue(phrases.contains("enter passcode"), "\(phrases) from \(SystemPhrases.candidates())")
        XCTAssertTrue(phrases.contains("slide to unlock"))
    }

    /// It is data, not a component: it must not join the component definitions.
    func testTheDataFileIsNotLoadedAsAComponent() {
        let definitions = ComponentLoader.loadAll()
        XCTAssertFalse(definitions.isEmpty, "the checkout's components must load for this to mean anything")
        XCTAssertFalse(definitions.contains { $0.name == "system-phrases" })
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
