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
// ABOUTME: Resolves a keyboard layout written as macOS shows it ("Swiss German") to its source ID.
// ABOUTME: Matches the source ID without spaces, then the layout's display name, among installed layouts.

import Carbon
import Foundation

extension LayoutMapper {

    /// One installed keyboard layout: its TIS source ID and the name macOS shows.
    public struct InstalledLayout: Sendable, Equatable {
        public let sourceID: String
        public let name: String

        public init(sourceID: String, name: String) {
            self.sourceID = sourceID
            self.name = name
        }
    }

    /// The source ID of the installed layout `layout` names when it is not
    /// written as a source ID: "Swiss German" is `com.apple.keylayout.SwissGerman`
    /// (the ID has no space), and "Canadian – CSA" is the display name of
    /// `com.apple.keylayout.Canadian-CSA`. Case is ignored. Nil when no
    /// installed layout matches.
    public static func installedSourceID(forLayout layout: String,
                                         installed: [InstalledLayout]) -> String? {
        let trimmed = layout.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let squeezed = sourceID(forLayout: trimmed.replacingOccurrences(of: " ", with: ""))
        if let match = installed.first(where: { $0.sourceID.caseInsensitiveCompare(squeezed) == .orderedSame }) {
            return match.sourceID
        }
        return installed.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }?.sourceID
    }

    /// The keyboard layouts installed on this Mac (`com.apple.keylayout.` sources).
    public static func installedLayouts() -> [InstalledLayout] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard let id = stringProperty(source, kTISPropertyInputSourceID),
                  id.hasPrefix("com.apple.keylayout.") else { return nil }
            return InstalledLayout(sourceID: id, name: stringProperty(source, kTISPropertyLocalizedName) ?? id)
        }
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
