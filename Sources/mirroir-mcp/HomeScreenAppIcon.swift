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
// ABOUTME: Finds an app's icon on a Home Screen page by the label under it, equal to the app's name and nothing else.
// ABOUTME: launch_app's Home Screen route reads only the page Home shows: a drag on the icon grid can move icons.

import Foundation
import HelperLib

/// An app icon on the Home Screen, found by its name label.
///
/// The label must equal the app's name once case and accents are folded:
/// never a near match, so "Réglages" (Settings) is opened for "Réglages" and
/// for nothing else. The icon detector is not needed: the label alone names
/// the app, and its tap point (lifted toward the icon by `TapPointCalculator`)
/// opens it. Apps in a folder, in the Dock (whose icons have no label) or only
/// in the App Library have no such label on a page.
enum HomeScreenAppIcon {

    /// The label of `name`'s icon on this page, or nil when no label equals it.
    /// Detector icons are not labels; with two equal labels (an icon and a
    /// widget of the same app), the higher one wins.
    static func label(for name: String, in elements: [TapPoint]) -> TapPoint? {
        let target = fold(name)
        guard !target.isEmpty else { return nil }
        return elements
            .filter { $0.text != CoreMLElementDetector.iconLabel && fold($0.text) == target }
            .min { $0.tapY < $1.tapY }
    }

    /// `text` trimmed, without case or accents.
    static func fold(_ text: String) -> String {
        SystemPhrases.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
