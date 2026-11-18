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
// ABOUTME: Remembers which keyboard layout the connected iPhone uses, per mirroring window size, across restarts.
// ABOUTME: An answer is a cache: a window size it was not given for asks again, and a miss on screen forgets it.

import CoreGraphics
import Foundation
import HelperLib

/// The keyboard layout given for each iPhone, keyed by the size of the
/// mirroring window it showed in. Nothing names the connected phone (iPhone
/// Mirroring keeps one paired-device ID and one window ID across a switch),
/// but two models show at different sizes (430x942, 410x898), so each phone
/// keeps its answer and a switch does not ask again. The size only decides
/// whether an answer applies: a size without one asks, and an answer that
/// typed the wrong characters is forgotten (`forget`), so the worst a wrong
/// key costs is one more question, never a wrong character kept.
final class KeyboardLayoutAnswers: @unchecked Sendable {

    /// Where the answers are kept between server runs.
    let path: String
    private let lock = NSLock()

    init(path: String = PermissionPolicy.globalConfigDir + "/keyboard-layouts.json") {
        self.path = path
    }

    /// The layout name given for a window of `size`, or nil. Read from the
    /// file each time: another mirroir process may have answered since.
    func answer(for size: CGSize) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[Self.key(size)]
    }

    /// Remember `name` for a window of `size`.
    func remember(_ name: String, for size: CGSize) {
        update { $0[Self.key(size)] = name }
    }

    /// Forget the answer for a window of `size`.
    func forget(for size: CGSize) {
        update { $0[Self.key(size)] = nil }
    }

    /// The key a window size is kept under: whole points, portrait first, so
    /// a rotation keeps the answer.
    static func key(_ size: CGSize) -> String {
        let sides = [size.width, size.height].map { Int($0.rounded()) }.sorted()
        return "\(sides[0])x\(sides[1])"
    }

    private func load() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    private func update(_ change: (inout [String: String]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var answers = load()
        change(&answers)
        do {
            let data = try JSONSerialization.data(withJSONObject: answers, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            DebugLog.log("keyboard", "could not save keyboard layout answers to \(path): \(error)")
        }
    }
}
