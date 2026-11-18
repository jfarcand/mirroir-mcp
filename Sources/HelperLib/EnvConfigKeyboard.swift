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
// ABOUTME: The keyboardLayout setting: the iPhone hardware-keyboard layouts, one name or a list per phone.
// ABOUTME: Split from EnvConfigFeatures.swift to stay under the 500-line limit.

import Foundation

extension EnvConfig {

    // MARK: - Keyboard Layout

    /// iPhone hardware-keyboard layout names; text is typed with their keys.
    /// `keyboardLayout` holds one name, or a list when iPhones with different
    /// layouts take turns on this Mac (`["Canadian-CSA", "US"]`). An empty
    /// name, or no setting at all, means US QWERTY. The environment variable
    /// takes a comma-separated list. Set via `mirroir-mcp configure`, which
    /// saves one name to settings.json.
    public static var keyboardLayouts: [String] {
        layoutNames(setting: settings["keyboardLayout"], env: env["IPHONE_KEYBOARD_LAYOUT"])
    }

    /// The layout names a `keyboardLayout` setting (a string or an array of
    /// strings) or, when it is absent, the environment variable names. Empty
    /// names read as US, and a name listed twice counts once.
    static func layoutNames(setting: Any?, env: String?) -> [String] {
        let names: [String]
        if let one = setting as? String {
            names = [one]
        } else if let list = setting as? [String] {
            names = list
        } else if let env {
            names = env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            names = []
        }
        var seen = Set<String>()
        let resolved = names.map { $0.isEmpty ? "US" : $0 }.filter { seen.insert($0).inserted }
        return resolved.isEmpty ? ["US"] : resolved
    }
}
