// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: iPhone Mirroring's own interstitial strings, in English and the Mac's language, keyed by what unblocks them.
// ABOUTME: Matches the words a blocked window shows to the one move that frees the session.

import AppKit
import Foundation
import HelperLib

/// What frees a blocked mirroring session.
enum SessionBlockMove: String, Sendable, CaseIterable, Codable {
    case approveOnMac
    case turnOnMacWiFi
    case turnOnMacBluetooth
    case waitForCameraOrMicrophone
    case lockIPhone
    case unlockIPhone
    case pressConnect
    case reconnectIPhone
    case waitWhileConnecting
    case pressResume
    case clearOnMac
    case reopenMirroring
    case unlockMac
    case showMirroring
    case reopenAfterQuit

    /// Whether only the user can make this move. The agent has no tool for the
    /// Mac's own windows, settings or prompts, nor for the iPhone's side button;
    /// it can only wait out a connection that is still forming.
    var needsUser: Bool {
        switch self {
        case .waitForCameraOrMicrophone, .waitWhileConnecting: return false
        default: return true
        }
    }

    /// The next move, worded for the agent to relay to the user.
    var advice: String {
        switch self {
        case .approveOnMac:
            return "This needs the user: a Mac Touch ID or password prompt is showing. Ask them "
                + "to approve or cancel it on the Mac; a password is never typed for them."
        case .turnOnMacWiFi:
            return "This needs the user: turn on Wi-Fi on the Mac, then retry."
        case .turnOnMacBluetooth:
            return "This needs the user: turn on Bluetooth on the Mac, then retry."
        case .waitForCameraOrMicrophone:
            return "The iPhone's camera or microphone is in use; the session connects once it "
                + "is released. Wait, then retry."
        case .lockIPhone:
            return "This needs the user: lock the iPhone (press its side button), then retry. "
                + "iPhone Mirroring connects only while the iPhone is locked."
        case .unlockIPhone:
            return "This needs the user: unlock the iPhone once with its passcode (needed after "
                + "a restart), lock it again, then retry. A passcode is never typed for them."
        case .pressConnect:
            return "Press Connect or Try Again in the mirroring window once, then retry. If the "
                + "same screen comes back, the iPhone is unlocked or out of range."
        case .reconnectIPhone:
            return "This needs the user: keep the iPhone near the Mac, powered on and recently "
                + "unlocked, with Bluetooth and Wi-Fi on, then press Try Again in the mirroring "
                + "window. Retry once they say it is back."
        case .waitWhileConnecting:
            return "iPhone Mirroring is still connecting. Wait a few seconds, then retry."
        case .pressResume:
            return "Click Resume in the mirroring window, then retry."
        case .clearOnMac:
            return "Clear it in the iPhone Mirroring window on the Mac, then retry."
        case .unlockMac:
            return "This needs the user: unlock the Mac, then retry. iPhone Mirroring stops while "
                + "the Mac's screen is locked, and nothing can be read from it or sent to it. If "
                + "the window then says the Mac was locked, press Connect in it once."
        case .reopenAfterQuit:
            return "This needs the user: open iPhone Mirroring again, then retry. It was running "
                + "earlier and is gone now, and that is a stop: nothing reopens it for the agent."
        case .showMirroring:
            return "This needs the user: show iPhone Mirroring again (click its icon in the Dock), "
                + "then retry. A hidden window can still be read, but input sent to it is lost."
        case .reopenMirroring:
            return "Accessibility cannot read the iPhone Mirroring window, so whether it is "
                + "connected cannot be told; a screenshot shows what it displays. This needs the "
                + "user: quit and reopen iPhone Mirroring, then retry."
        }
    }
}

/// The interstitial strings iPhone Mirroring draws, grouped by the move that
/// clears each one, resolved to normalized fragments a label can contain.
///
/// The keys are the app's own localization keys (its English text), read from
/// the `ScreenContinuityUI` framework inside the app, so the match follows the
/// Mac's language without a hand-kept translation list. A key with several
/// paragraphs contributes each one as its own fragment.
struct InterstitialPhrases: Sendable {

    /// One move and the fragments that identify it.
    struct Entry: Sendable, Equatable {
        let move: SessionBlockMove
        let fragments: [String]
    }

    /// Entries in priority order: the first whose fragment a label contains
    /// wins. Camera and microphone come before the iPhone-in-use case because
    /// some languages word "iPhone Camera in Use" around "iPhone in Use", and a
    /// specific failure comes before the generic "Connecting to" it embeds.
    let entries: [Entry]

    /// Normalized titles of the buttons that resume or dismiss an
    /// interruption: English plus the Mac's language.
    let resumeControlTitles: Set<String>

    /// Localization keys of iPhone Mirroring's interstitials, by move, in
    /// priority order. Credential prompts also match on a text field, which
    /// `SessionBlockClassifier` checks first.
    static let appKeys: [(SessionBlockMove, [String])] = [
        (.approveOnMac, [
            "Authenticate to access %@. Touch\u{00A0}ID or enter your password to continue.",
            "Authenticate to access %@. Enter your password to continue.",
            "Touch\u{00A0}ID or enter the Mac login for “%@” to continue.",
            "Your macOS user password or Touch\u{00A0}ID is required to access your iPhone with iPhone Mirroring.",
        ]),
        (.turnOnMacWiFi, ["Wi‑Fi Off", "Turn on Mac Wi‑Fi to connect.", "Turn on Mac WLAN to connect."]),
        (.turnOnMacBluetooth, ["Bluetooth Off", "Turn on Mac Bluetooth to connect."]),
        (.waitForCameraOrMicrophone, [
            "iPhone Camera in Use", "iPhone Microphone in Use",
            "iPhone Mirroring will connect when iPhone camera is no longer in use.",
            "iPhone Mirroring will connect when iPhone microphone is no longer in use.",
        ]),
        (.lockIPhone, [
            "iPhone in Use",
            "iPhone Mirroring timed out due to iPhone use while connecting.\n\nLock your iPhone before connecting.",
            "iPhone Mirroring ended due to iPhone use.\n\nLock your iPhone to connect.",
            "iPhone Mirroring ended due to iPhone use.",
            "Lock your iPhone to connect.\n\niPhone Mirroring will connect when iPhone is no longer in use.",
        ]),
        (.unlockIPhone, ["Unlock Your iPhone"]),
        (.pressConnect, ["Unable to Connect to iPhone", "Timed Out", "iPhone Mirroring timed out connecting."]),
        (.waitWhileConnecting, ["Connecting to %@", "Connecting to"]),
        (.reconnectIPhone, ["Connection Interrupted", "iPhone Not Found"]),
        (.pressResume, ["Connection Paused"]),
    ]

    /// Localization keys of the buttons that resume or dismiss an
    /// interruption: the camera dialog's OK, the pause overlay's Resume, and
    /// the Try Again and Connect of the in-use and timed-out screens.
    static let resumeControlKeys: [String] = ["OK", "Resume", "Try Again", "Connect"]

    /// The framework inside iPhone Mirroring.app that carries its strings.
    static let stringsFrameworkPath = "Contents/Frameworks/ScreenContinuityUI.framework"

    /// Fragments shorter than this are dropped: a stray word or punctuation
    /// would match unrelated labels.
    static let minFragmentLength = 4

    /// Phrases resolved for this Mac: English plus the Mac's language, read
    /// from the installed iPhone Mirroring app. English alone when the app or
    /// its strings cannot be found.
    static let live = InterstitialPhrases(localize: liveLocalizer(bundleID: EnvConfig.mirroringBundleID))

    /// Build the table, asking `localize` for every rendering of each key.
    init(localize: (String) -> [String]) {
        resumeControlTitles = Set(
            Self.resumeControlKeys.flatMap { [$0] + localize($0) }.map(Self.normalize))
        entries = Self.appKeys.map { move, keys in
            var seen = Set<String>()
            let fragments = keys.flatMap { key in ([key] + localize(key)).flatMap(Self.fragments) }
                .filter { seen.insert($0).inserted }
            return Entry(move: move, fragments: fragments)
        }
    }

    /// Whether a button titled `label` resumes or dismisses an interruption:
    /// its title, in English or the Mac's language, is one of
    /// `resumeControlKeys`. A button with no title never is.
    func isResumeControl(label: String?) -> Bool {
        guard let label else { return false }
        let normalized = Self.normalize(label)
        return !normalized.isEmpty && resumeControlTitles.contains(normalized)
    }

    /// The move for the first entry, in priority order, whose fragment one of
    /// `labels` contains; nil when none matches.
    func move(for labels: [String]) -> SessionBlockMove? {
        let normalized = labels.map(Self.normalize)
        return entries.first { entry in
            entry.fragments.contains { fragment in normalized.contains { $0.contains(fragment) } }
        }?.move
    }

    /// Lower-cased, with typographic spaces, hyphens and apostrophes folded to
    /// plain ones and runs of whitespace collapsed.
    static func normalize(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2019}", with: "'")
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The literal parts of `phrase`, one per paragraph, normalized. A
    /// paragraph with a placeholder keeps only its longest literal part: a
    /// short tail such as "to continue." would match unrelated screens.
    static func fragments(_ phrase: String) -> [String] {
        phrase.components(separatedBy: .newlines).compactMap { paragraph in
            paragraph.components(separatedBy: "%@")
                .map { normalize($0).trimmingCharacters(in: CharacterSet(charactersIn: " “”\"")) }
                .max { $0.count < $1.count }
        }.filter { $0.count >= minFragmentLength }
    }

    /// Reads each key's rendering in the Mac's language from the installed
    /// app's strings framework.
    static func liveLocalizer(bundleID: String) -> (String) -> [String] {
        guard let bundle = stringsBundle(bundleID: bundleID) else { return { _ in [] } }
        return { key in [bundle.localizedString(forKey: key, value: key, table: nil)] }
    }

    /// The bundle inside the installed iPhone Mirroring app that carries its
    /// strings, or nil when the app or the framework is not found.
    static func stringsBundle(bundleID: String) -> Bundle? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0.appendingPathComponent(stringsFrameworkPath)) }
    }
}
