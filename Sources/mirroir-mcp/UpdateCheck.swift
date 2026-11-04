// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: At most once a day, asks the npm registry for the newest mirroir-mcp and says when this binary is behind.
// ABOUTME: Cached in ~/.mirroir-mcp, two-second timeout, off with updateCheck=false; status, check_health and doctor show it.

import Foundation
import HelperLib

/// A once-a-day check for a newer release. The answer is cached so that
/// status, check_health and doctor never wait on the network more than once
/// in 24 hours, and a failed lookup is cached too: an offline Mac is asked
/// again the next day, not on every call.
enum UpdateCheck {

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

    /// The newest version, from `cache` when it is younger than a day, else
    /// from `fetch`, whose result (even a failure) becomes the new cache.
    static func latest(now: Date, cache: Cache?, fetch: () -> String?,
                       store: (Cache) -> Void) -> String? {
        if let cache, now.timeIntervalSince(cache.checkedAt) < cacheLifetime {
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
        let latest = latest(now: Date(), cache: readCache(), fetch: fetchLatest, store: writeCache)
        return notice(current: MirroirVersion.current, latest: latest)
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
