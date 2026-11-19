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
// ABOUTME: Asks the npm registry for the newest mirroir-mcp and says when this binary is behind; status and check_health ask once a day.
// ABOUTME: Cached in ~/.mirroir-mcp, two-second timeout, off with updateCheck=false; doctor always asks the registry itself.

import Foundation
import HelperLib

/// A check for a newer release. The answer is cached so that status and
/// check_health never wait on the network more than once in 24 hours, and a
/// failed lookup is cached too: an offline Mac is asked again the next day,
/// not on every call. Doctor is run on purpose to diagnose an install, so it
/// asks the registry every time rather than repeat a day-old answer.
enum UpdateCheck {

    /// Whether a lookup may answer from a cache younger than `cacheLifetime`.
    enum CachePolicy {
        /// Reuse a cache younger than a day (status, check_health).
        case reuse
        /// Ask the registry now and store its answer (doctor).
        case refresh
    }

    /// How long a lookup, successful or not, is reused.
    static let cacheLifetime: TimeInterval = 24 * 60 * 60

    /// How long to wait on the registry.
    static let timeoutSeconds: TimeInterval = 2

    /// Where the newest published version is read.
    static let registryURL = URL(string: "https://registry.npmjs.org/mirroir-mcp/latest")

    /// The last lookup: when it ran and what it found (nil when it failed).
    struct Cache: Codable, Equatable {
        let checkedAt: Date
        let latest: String?
    }

    /// Whether `candidate` is a later `X.Y.Z` than `current` (a leading `v` is ignored).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parse = { (version: String) -> [Int] in
            version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let lhs = parse(candidate), rhs = parse(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// The line to show when `latest` is newer than `current`, else nil.
    static func notice(current: String, latest: String?) -> String? {
        guard let latest, isNewer(latest, than: current) else { return nil }
        return "mirroir-mcp \(latest) is available (this is \(current)). Run `mirroir-mcp update` "
            + "to see how to upgrade this install."
    }

    /// The newest version, from `cache` when the policy allows it and it is
    /// younger than a day, else from `fetch`, whose result (even a failure)
    /// becomes the new cache.
    static func latest(now: Date, policy: CachePolicy = .reuse, cache: Cache?, fetch: () -> String?,
                       store: (Cache) -> Void) -> String? {
        if policy == .reuse, let cache, now.timeIntervalSince(cache.checkedAt) < cacheLifetime {
            return cache.latest
        }
        let fresh = Cache(checkedAt: now, latest: fetch())
        store(fresh)
        return fresh.latest
    }

    /// The notice for this binary, or nil when it is current, the check is
    /// off, or the registry could not be reached.
    static func liveNotice() -> String? {
        guard EnvConfig.updateCheck else { return nil }
        return notice(current: MirroirVersion.current, latest: liveLatest(policy: .reuse))
    }

    /// The registry's newest version under `policy`, or nil when it could not
    /// be reached. Callers check `EnvConfig.updateCheck` first.
    static func liveLatest(policy: CachePolicy) -> String? {
        latest(now: Date(), policy: policy, cache: readCache(), fetch: fetchLatest, store: writeCache)
    }

    // MARK: - Doctor

    /// Doctor's version check: the registry asked just now, never a cached answer.
    static func doctorCheck() -> DoctorCheck {
        let enabled = EnvConfig.updateCheck
        return doctorCheck(enabled: enabled, latest: enabled ? liveLatest(policy: .refresh) : nil)
    }

    /// Whether a newer release is published, from the registry's answer just
    /// now (`latest`, nil when it could not be reached); a warning, never a failure.
    static func doctorCheck(enabled: Bool, latest: String?,
                            current: String = MirroirVersion.current) -> DoctorCheck {
        let name = "mirroir-mcp version"
        guard enabled else {
            return DoctorCheck(name: name, status: .passed, detail: "\(current) (check off)", fixHint: nil)
        }
        guard let latest else {
            return DoctorCheck(name: name, status: .warned,
                               detail: "\(current) (the npm registry could not be reached to check for a newer release)",
                               fixHint: "Check the network, or run `mirroir-mcp update` later.")
        }
        guard let notice = notice(current: current, latest: latest) else {
            return DoctorCheck(name: name, status: .passed, detail: "\(current) (latest release)", fixHint: nil)
        }
        return DoctorCheck(name: name, status: .warned, detail: notice, fixHint: "Run `mirroir-mcp update`.")
    }

    // MARK: - Live sources

    private static var cachePath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".mirroir-mcp/update-check.json")
    }

    private static func readCache() -> Cache? {
        guard let data = FileManager.default.contents(atPath: cachePath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    private static func writeCache(_ cache: Cache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        let directory = (cachePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cachePath, contents: data)
    }

    /// The registry's `latest` version, or nil on any failure or after the timeout.
    private static func fetchLatest() -> String? {
        guard let url = registryURL else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var found: String?
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? String {
                found = version
            }
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + timeoutSeconds) == .success else {
            task.cancel()
            return nil
        }
        return found
    }
}
