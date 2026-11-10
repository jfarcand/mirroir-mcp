// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AX snapshots of the iPhone Mirroring interstitials, worded with the app's own English and fr_CA strings.
// ABOUTME: The corpus the session-block tests classify; each fixture names the move that frees it.

@testable import mirroir_mcp

/// One interstitial as Accessibility reads it, and the move that frees it.
struct InterstitialFixture {
    let name: String
    let window: MirroringAXWindow
    let move: SessionBlockMove
}

/// Interstitials built from the strings in iPhone Mirroring's
/// `ScreenContinuityUI` loctable (macOS 26.5), plus the Mac prompts that
/// draw over the window. Fixture rationale: these screens appear only when
/// the iPhone is unlocked, out of range, or the Mac's radios are off, so they
/// cannot be produced on demand in a test run.
///
/// A screen that has been captured live is not here: its capture under
/// `Tests/Fixtures/mirroring-ax/` replaces the hand-built entry, and
/// `AXWindowCaptureCorpusTests` replays it. Only screens nobody has captured
/// yet are built by hand.
enum InterstitialFixtures {

    static func text(_ label: String) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXStaticText", label: label)
    }

    static func button(_ label: String) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXButton", label: label)
    }

    /// The toolbar's Home and App Switcher buttons, revealed over any screen.
    static let toolbar: [AXNodeSnapshot] = [
        AXNodeSnapshot(role: "AXButton", identifier: "app.grid.3x3", label: "Home Screen"),
        AXNodeSnapshot(role: "AXButton", identifier: "iphone.app.switcher", label: "App Switcher"),
    ]

    static func overlay(_ name: String, _ nodes: [AXNodeSnapshot],
                        _ move: SessionBlockMove) -> InterstitialFixture {
        InterstitialFixture(
            name: name,
            window: MirroringAXWindow(
                title: "iPhone Mirroring", frame: nil,
                hostingView: AXNodeSnapshot(role: "AXGroup", children: nodes)),
            move: move)
    }

    static func sheet(_ name: String, _ nodes: [AXNodeSnapshot],
                      _ move: SessionBlockMove) -> InterstitialFixture {
        InterstitialFixture(
            name: name,
            window: MirroringAXWindow(
                title: "iPhone Mirroring", frame: nil,
                hostingView: AXNodeSnapshot(role: "AXGroup", children: toolbar),
                sheets: [AXNodeSnapshot(role: "AXSheet", children: nodes)]),
            move: move)
    }

    static let english: [InterstitialFixture] = [
        overlay("in use", [
            text("iPhone in Use"),
            text("Lock your iPhone to connect.\n\niPhone Mirroring will connect when iPhone is no longer in use."),
            button("Try Again"),
        ], .lockIPhone),
        overlay("timed out due to use", [
            AXNodeSnapshot(role: "AXImage", label: "iPhoneOff"),
            text("Timed Out"),
            text("iPhone Mirroring timed out due to iPhone use while connecting.\n\nLock your iPhone before connecting."),
            button("Connect"),
        ], .lockIPhone),
        overlay("ended due to use", [
            text("iPhone Mirroring ended due to iPhone use.\n\nLock your iPhone to connect."),
            button("Try Again"),
        ], .lockIPhone),
        overlay("plain timeout", [
            text("Timed Out"), text("iPhone Mirroring timed out connecting."), button("Try Again"),
        ], .pressConnect),
        overlay("unable to connect", [
            text("Unable to Connect to iPhone"), button("Try Again"),
        ], .pressConnect),
        overlay("connecting", [
            text("Connecting to"), text("iPhone 17 Pro Max"), button("Background"),
        ], .waitWhileConnecting),
        overlay("connecting, no button", [
            text("Connecting to"), text("iPhone 17 Pro Max"),
        ], .waitWhileConnecting),
        overlay("wi-fi off", [
            text("Wi\u{2011}Fi Off"), text("Turn on Mac Wi\u{2011}Fi to connect."),
        ], .turnOnMacWiFi),
        overlay("wi-fi off, plain hyphen", [text("Wi-Fi Off")], .turnOnMacWiFi),
        overlay("bluetooth off", [
            text("Bluetooth Off"), text("Turn on Mac Bluetooth to connect."),
        ], .turnOnMacBluetooth),
        overlay("camera in use", [
            text("iPhone Camera in Use"),
            text("iPhone Mirroring will connect when iPhone camera is no longer in use."),
        ], .waitForCameraOrMicrophone),
        overlay("unlock after restart", [text("Unlock Your iPhone")], .unlockIPhone),
        overlay("connection paused", [text("Connection Paused"), button("Resume")], .pressResume),
        overlay("camera dialog", [
            text("iPhone camera is not available from Mac."), button("OK"),
        ], .clearOnMac),
        overlay("unknown words", [text("Something new from Apple")], .clearOnMac),
        sheet("touch id sheet", [
            text("Passwords"),
            text("Authenticate to access Passwords. Touch ID or enter your password to continue."),
            button("Cancel"),
        ], .approveOnMac),
        sheet("mac login sheet", [
            text("Enter the Mac login password"),
            AXNodeSnapshot(role: "AXTextField", subrole: "AXSecureTextField"),
            button("Unlock"),
        ], .approveOnMac),
    ]

    /// fr_CA renderings of the keys the French fixtures use, verbatim from the loctable.
    static let frenchCanadian: [String: String] = [
        "iPhone in Use": "iPhone en cours d’utilisation",
        "Lock your iPhone to connect.\n\niPhone Mirroring will connect when iPhone is no longer in use.":
            "Verrouillez votre iPhone pour établir la connexion.\n\nL’app Recopie de l’iPhone se "
            + "connectera à l’iPhone quand ce dernier ne sera plus utilisé.",
        "iPhone Camera in Use": "Caméra de l’iPhone en cours d’utilisation",
        "Wi\u{2011}Fi Off": "Wi\u{2011}Fi désactivé",
        "Turn on Mac Wi\u{2011}Fi to connect.":
            "Activez le Wi\u{2011}Fi sur votre Mac pour procéder à la connexion.",
        "Unable to Connect to iPhone": "Connexion à l’iPhone impossible",
        "Connecting to": "Connexion à",
        "Connecting to %@": "Connexion à %@",
        "Timed Out": "Expiré",
        "Connection Paused": "Connexion en pause",
        "Unlock Your iPhone": "Déverrouiller l’iPhone",
        "Resume": "Reprendre",
        "Try Again": "Réessayer",
        "Connect": "Connexion",
    ]

    /// A table for a Mac set to Canadian French, built from the renderings above.
    static let frenchCanadianPhrases = InterstitialPhrases(localize: { key in
        frenchCanadian[key].map { [$0] } ?? []
    })

    /// A table for a Mac set to English: the keys alone.
    static let englishPhrases = InterstitialPhrases(localize: { _ in [] })

    static let french: [InterstitialFixture] = [
        overlay("fr in use", [
            text("iPhone en cours d’utilisation"),
            text("Verrouillez votre iPhone pour établir la connexion."),
            button("Réessayer"),
        ], .lockIPhone),
        overlay("fr camera in use", [text("Caméra de l’iPhone en cours d’utilisation")],
                .waitForCameraOrMicrophone),
        overlay("fr wi-fi off", [text("Wi\u{2011}Fi désactivé")], .turnOnMacWiFi),
        overlay("fr unable to connect", [text("Connexion à l’iPhone impossible")], .pressConnect),
        overlay("fr connecting", [text("Connexion à iPhone 17 Pro Max")], .waitWhileConnecting),
        overlay("fr paused", [text("Connexion en pause"), button("Reprendre")], .pressResume),
        overlay("fr unlock", [text("Déverrouiller l’iPhone")], .unlockIPhone),
    ]
}
