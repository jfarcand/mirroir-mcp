// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds the Mac's multitouch trackpad in the IORegistry and returns its registry entry ID.
// ABOUTME: That ID is the sender iPhone Mirroring requires on pinch and rotate gesture events.

import Foundation
import IOKit

/// A multitouch device as read from the IORegistry.
struct MultitouchServiceCandidate: Sendable, Equatable {
    /// IORegistry entry ID, the value a gesture event names as its sender.
    let registryID: UInt64
    /// Whether the device is the Mac's built-in trackpad.
    let builtIn: Bool
    /// HID usage pages the device reports.
    let usagePages: [Int]
}

/// Picks the trackpad a gesture event should name as its sender.
enum MultitouchSenderSelector {

    /// HID usage page of digitizers, which every multitouch trackpad reports.
    static let digitizerUsagePage = 0x0D

    /// The built-in digitizer when there is one, else the first external one
    /// (a Magic Trackpad), else nil.
    static func select(from candidates: [MultitouchServiceCandidate]) -> UInt64? {
        let digitizers = candidates.filter { $0.usagePages.contains(digitizerUsagePage) }
        return (digitizers.first { $0.builtIn } ?? digitizers.first)?.registryID
    }
}

/// Live `MultitouchSenderResolving`: reads every `AppleMultitouchDevice` from
/// the IORegistry on each call. Nothing is cached, so a Magic Trackpad that
/// reconnects under a new registry entry is picked up on the next gesture.
struct IOKitMultitouchSenderResolver: MultitouchSenderResolving {

    /// IOKit class of the multitouch trackpad devices.
    static let serviceClass = "AppleMultitouchDevice"
    /// Registry property that is true on the built-in trackpad.
    static let builtInKey = "MT Built-In"
    /// Registry property listing the device's HID usage page/usage pairs.
    static let usagePairsKey = "DeviceUsagePairs"
    /// Key of the usage page inside one `usagePairsKey` entry.
    static let usagePageKey = "DeviceUsagePage"
    /// Registry property naming the device's primary HID usage page.
    static let primaryUsagePageKey = "PrimaryUsagePage"

    func multitouchSenderID() -> UInt64? {
        let candidates = Self.candidates()
        let selected = MultitouchSenderSelector.select(from: candidates)
        DebugLog.log("gesture", "multitouch candidates=\(candidates.count) sender=\(selected.map { String($0) } ?? "none")")
        return selected
    }

    /// Every multitouch device the IORegistry holds right now.
    static func candidates() -> [MultitouchServiceCandidate] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var found: [MultitouchServiceCandidate] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
                continue
            }
            found.append(MultitouchServiceCandidate(
                registryID: registryID,
                builtIn: property(service, builtInKey) as? Bool ?? false,
                usagePages: usagePages(of: service)))
        }
        return found
    }

    private static func usagePages(of service: io_service_t) -> [Int] {
        let pairs = property(service, usagePairsKey) as? [[String: Any]] ?? []
        var pages = pairs.compactMap { $0[usagePageKey] as? Int }
        if let primary = property(service, primaryUsagePageKey) as? Int {
            pages.append(primary)
        }
        return pages
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
