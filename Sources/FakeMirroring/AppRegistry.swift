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
// ABOUTME: Holds all loaded AppPacks and tracks which one is foreground; brokers Spotlight launches and force-quits.
// ABOUTME: Built once at FakeMirroring startup from APP.md files in the configured skills directory.

import Foundation
import HelperLib

/// Singleton-style registry of loaded simulator apps.
/// All access is on the main thread (FakeMirroring is a UI app).
@MainActor
final class AppRegistry {
    /// Loaded packs keyed by `SimulatorSpec.appName` (case-insensitive lookups via `lookup(...)`).
    private(set) var packs: [String: AppPack] = [:]
    /// IDs of packs that have been launched at least once and not yet force-quit.
    /// App Switcher renders these as cards.
    private(set) var runningPackIDs: [String] = []
    /// The pack whose scenes are currently being rendered, or nil for the home screen.
    private(set) var foregroundPack: AppPack?

    /// Triggered when the foreground app changes — view layer subscribes to redraw.
    var onForegroundChanged: (() -> Void)?

    /// Load all APP.md files from `directory` and register packs that declare a simulator block.
    /// Files without a simulator block are silently skipped (still useful for guidance).
    func loadPacks(from directory: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory) else { return }
        var count = 0
        while let entry = enumerator.nextObject() as? String {
            guard (entry as NSString).lastPathComponent.lowercased() == "app.md" else {
                continue
            }
            let fullPath = directory + "/" + entry
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                continue
            }
            // Use the same section/frontmatter extraction as AppDescriptionParser
            // by exposing a thin shim there. For now, parse via the public helper.
            guard let pack = AppPackLoader.makePack(content: content) else { continue }
            packs[pack.spec.appName.lowercased()] = pack
            count += 1
        }
        FileHandle.standardError.write(Data("[registry] loaded \(count) AppPack(s) from \(directory)\n".utf8))
    }

    /// Look up a pack by Spotlight name or app name (case-insensitive).
    func lookup(spotlightInput: String) -> AppPack? {
        let folded = spotlightInput.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for pack in packs.values {
            let name = pack.spec.appName.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let spotlight = pack.spec.spotlightName.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if name == folded || spotlight == folded { return pack }
        }
        return nil
    }

    /// Bring `pack` to the foreground. Cold launches (pack not already running)
    /// reset session state to root; warm launches preserve it — matching iOS
    /// Spotlight semantics where relaunching a backgrounded app resumes it.
    func launch(_ pack: AppPack) {
        let isColdLaunch = !runningPackIDs.contains(pack.spec.appName)
        if isColdLaunch {
            pack.resetToRoot()
            runningPackIDs.append(pack.spec.appName)
        }
        foregroundPack = pack
        onForegroundChanged?()
    }

    /// Force-quit `pack` — clears its session state and removes it from running list.
    /// If it was foreground, foreground returns to the home screen.
    func forceQuit(_ pack: AppPack) {
        pack.resetToRoot()
        runningPackIDs.removeAll { $0 == pack.spec.appName }
        if foregroundPack === pack {
            foregroundPack = nil
            onForegroundChanged?()
        }
    }

    /// Return to home screen without quitting the foreground app (preserves state).
    func goHome() {
        foregroundPack = nil
        onForegroundChanged?()
    }
}

/// Builds a runnable `AppPack` from APP.md file content.
/// Splits parsing concern from runtime registry concerns.
enum AppPackLoader {
    static func makePack(content: String) -> AppPack? {
        let extracted = AppMdSectioning.extract(content: content)
        guard let appName = extracted.frontMatter["app"] else { return nil }
        guard let spec = SimulatorSpecParser.parse(
            sections: extracted.sections,
            frontMatter: extracted.frontMatter,
            appName: appName
        ) else { return nil }
        return AppPack(spec: spec)
    }
}
