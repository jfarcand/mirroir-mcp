// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AppDelegate that boots the FakeMirroring window, loads AppPacks, and builds the menu bar.
// ABOUTME: Extracted from main.swift to keep that file under the 500-line ceiling.

import AppKit
import Foundation
import HelperLib

/// Application delegate that creates the main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    let registry = AppRegistry()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowWidth: CGFloat = 410
        let windowHeight: CGFloat = 898

        let window = AlwaysAcceptingWindow(
            contentRect: NSRect(x: 200, y: 200, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Avoid NSWindow over-releasing under ARC when the close button is
        // hit during a test run, which leaves AppDelegate.window dangling and
        // crashes the next menu action with EXC_BAD_ACCESS on contentView.
        window.isReleasedWhenClosed = false
        window.title = "FakeMirroring"
        let view = FakeScreenView(
            frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        window.contentView = view
        window.acceptsMouseMovedEvents = true
        // Float above other windows during integration tests so CGEvent taps
        // always hit FakeMirroring. Opt-in via env var to avoid annoying manual users.
        if ProcessInfo.processInfo.environment["FAKEMIRRORING_FLOATING"] == "1" {
            window.level = .floating
        }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Wire AppRegistry → view: every foreground change updates the data source.
        registry.onForegroundChanged = { [weak view, weak self] in
            guard let view, let self else { return }
            view.appPack = self.registry.foregroundPack
        }
        loadAppPacks()
        buildMenuBar()

        // Default to Settings foreground at startup so integration tests that
        // expect a populated screen at boot work without an explicit launch.
        let packCount = registry.packs.count
        if let settings = registry.lookup(spotlightInput: "Settings") {
            registry.launch(settings)
            FileHandle.standardError.write(Data(
                "[FakeMirroring] auto-launched Settings (loaded packs: \(packCount))\n".utf8))
        } else {
            FileHandle.standardError.write(Data(
                "[FakeMirroring] Settings pack not found (loaded packs: \(packCount): \(registry.packs.keys.sorted()))\n".utf8))
        }
    }

    /// Resolve the skills directory and load APP.md packs.
    /// Search order:
    ///   1. $MIRROIR_SKILLS_PATH (explicit, e.g. CI)
    ///   2. ../../../../mirroir-skills/patterns/apps relative to the .app bundle
    ///      (`.build/{release|debug}/FakeMirroring.app` → workspace root)
    ///   3. ../mirroir-skills/patterns/apps relative to the running executable's
    ///      *binary* directory (covers raw-binary launches and Xcode builds)
    ///   4. cwd-relative fallbacks
    private func loadAppPacks() {
        let env = ProcessInfo.processInfo.environment
        if let configured = env["MIRROIR_SKILLS_PATH"], !configured.isEmpty {
            registry.loadPacks(from: configured)
            return
        }
        let candidates = skillsDirectoryCandidates()
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                registry.loadPacks(from: candidate)
                return
            }
        }
        FileHandle.standardError.write(Data(
            "[FakeMirroring] no skills directory found; AppPacks not loaded. Searched: \(candidates)\n".utf8))
    }

    /// Ordered list of directories to probe for APP.md files.
    /// Independent of `cwd` because `open .app` launches with `cwd=/`. Walks
    /// every ancestor of the bundle/executable and probes each for a
    /// `mirroir-skills/patterns/apps` sibling, so the search survives both the
    /// `.build/release/` symlink layout and the resolved
    /// `.build/arm64-apple-macosx/release/` real path.
    private func skillsDirectoryCandidates() -> [String] {
        var candidates: [String] = []
        var anchors: [URL] = [Bundle.main.bundleURL]
        if let exePath = Bundle.main.executablePath {
            anchors.append(URL(fileURLWithPath: exePath))
        }
        for anchor in anchors {
            var current = anchor
            for _ in 0..<8 {
                current = current.deletingLastPathComponent()
                candidates.append(current
                    .appendingPathComponent("mirroir-skills/patterns/apps").path)
                if current.path == "/" { break }
            }
        }
        // cwd-relative fallbacks (work when launched via swift run from package root).
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append("\(cwd)/../mirroir-skills/patterns/apps")
        candidates.append("\(cwd)/mirroir-skills/patterns/apps")
        return candidates
    }

    /// Build menus: View menu for AX traversal tests, Scenario menu for content switching.
    private func buildMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit FakeMirroring",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(
            title: "Home Screen",
            action: #selector(showHomeScreen(_:)),
            keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(
            title: "Spotlight",
            action: #selector(showSpotlight(_:)),
            keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(
            title: "App Switcher",
            action: #selector(showAppSwitcher(_:)),
            keyEquivalent: ""))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Build the Scenario menu from registered packs so existing
        // integration tests that triggerMenuAction("Scenario", "Settings")
        // still resolve. Items appear sorted by app name for stable AX traversal.
        let scenarioMenuItem = NSMenuItem()
        let scenarioMenu = NSMenu(title: "Scenario")
        let sortedNames = registry.packs.values.map { $0.spec.appName }.sorted()
        for name in sortedNames {
            let item = NSMenuItem(
                title: name,
                action: #selector(switchScenario(_:)),
                keyEquivalent: ""
            )
            item.representedObject = name
            scenarioMenu.addItem(item)
        }
        scenarioMenuItem.submenu = scenarioMenu
        mainMenu.addItem(scenarioMenuItem)

        let testMenuItem = NSMenuItem()
        let testMenu = NSMenu(title: "Test")
        testMenu.addItem(NSMenuItem(
            title: "Slider 90%",
            action: #selector(setSlider90(_:)),
            keyEquivalent: ""
        ))
        testMenuItem.submenu = testMenu
        mainMenu.addItem(testMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func setSlider90(_ sender: Any?) {
        guard let view = window?.contentView as? FakeScreenView else { return }
        view.sliderFraction = 0.9
        view.needsDisplay = true
    }

    @objc func switchScenario(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let view = window?.contentView as? FakeScreenView else { return }
        // The Scenario menu is built from registered packs, so every item
        // resolves through the registry. Items are removed automatically when
        // a pack is unloaded, so a stale rawValue here is a programmer error.
        if let pack = registry.lookup(spotlightInput: rawValue) {
            // Dismiss any stuck overlay from a previous test/interaction so
            // the launched pack is actually visible.
            view.spotlightOverlay = nil
            view.appSwitcherOverlay = nil
            // Scenario menu is a test-only convenience: always give a fresh
            // cold-launch state so back-to-back tests don't observe stale
            // obstacles/screens from a prior test's interactions.
            registry.forceQuit(pack)
            registry.launch(pack)
            return
        }
        FileHandle.standardError.write(Data(
            "[FakeMirroring] Scenario menu '\(rawValue)' has no matching pack\n".utf8))
    }

    @objc func showHomeScreen(_ sender: Any?) {
        // Home closes the App Switcher and Spotlight, as on iOS; either overlay
        // left up would draw over every app launched afterwards.
        if let view = window?.contentView as? FakeScreenView {
            view.spotlightOverlay = nil
            view.appSwitcherOverlay = nil
        }
        registry.goHome()
    }

    @objc func showSpotlight(_ sender: Any?) {
        guard let view = window?.contentView as? FakeScreenView else { return }
        // Toggle: a second invocation dismisses the overlay rather than
        // stacking another one. Keeps test state clean across tearDowns.
        if view.spotlightOverlay != nil {
            view.spotlightOverlay = nil
            return
        }
        view.spotlightOverlay = SpotlightOverlay(registry: registry) { [weak view] pack in
            view?.spotlightOverlay = nil
            if let pack { self.registry.launch(pack) }
        }
        view.needsDisplay = true
    }

    @objc func showAppSwitcher(_ sender: Any?) {
        guard let view = window?.contentView as? FakeScreenView else { return }
        if view.appSwitcherOverlay != nil {
            view.appSwitcherOverlay = nil
            return
        }
        view.appSwitcherOverlay = AppSwitcherOverlay(registry: registry) { [weak view] in
            view?.appSwitcherOverlay = nil
            view?.needsDisplay = true
        }
        view.needsDisplay = true
    }
}
