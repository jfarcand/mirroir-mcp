// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Finds the macOS system CoreDevice tunnel of a device by parsing `xcrun devicectl list devices` JSON.
// ABOUTME: Reads the tunnel address and RSD port defensively and throws a typed error when no tunnel is up.

import Foundation

/// The system CoreDevice tunnel of one device, as `devicectl` reports it.
public struct CoreDeviceTunnel: Equatable, Sendable {
    /// Whether the RSD port came from devicectl or is the well-known default.
    public enum PortSource: Equatable, Sendable {
        case reported
        case wellKnownDefault
    }

    /// CoreDevice identifier (a UUID, distinct from the UDID).
    public let deviceIdentifier: String
    public let udid: String?
    public let name: String?
    /// The device's address inside the tunnel (IPv6).
    public let tunnelAddress: String
    public let rsdPort: Int
    public let rsdPortSource: PortSource
}

/// Parses `devicectl list devices --json-output` documents.
///
/// The observed shape (devicectl 518.33, `jsonVersion` 3) is
/// `result.devices[]` with `identifier`, `hardwareProperties.udid`,
/// `deviceProperties.name` and `connectionProperties.tunnelState`. A connected
/// device additionally reports `connectionProperties.tunnelIPAddress`. No
/// captured document shows an RSD port, so port keys are searched for and the
/// well-known RSD port is used when none is present.
public enum DevicectlDeviceListParser {
    static let resultKey = "result"
    static let devicesKey = "devices"
    static let identifierKey = "identifier"
    static let hardwareKey = "hardwareProperties"
    static let udidKey = "udid"
    static let devicePropertiesKey = "deviceProperties"
    static let nameKey = "name"
    static let connectionKey = "connectionProperties"
    static let tunnelStateKey = "tunnelState"
    static let connectedState = "connected"
    /// Address keys, most specific first; searched through the whole device entry.
    static let tunnelAddressKeys = ["tunnelIPAddress", "tunnelIpAddress", "tunnelAddress"]
    /// Port keys a devicectl version might use for the tunnel's RSD endpoint.
    static let rsdPortKeys = ["tunnelRSDPort", "rsdPort", "remoteServiceDiscoveryPort", "tunnelPort"]

    /// Returns the tunnel of the device whose CoreDevice identifier, UDID or
    /// name equals `device` (case-insensitive).
    public static func tunnel(for device: String, in json: Data) throws -> CoreDeviceTunnel {
        let entry = try deviceEntry(matching: device, in: json)
        let connection = entry[connectionKey] as? [String: Any] ?? [:]
        let state = connection[tunnelStateKey] as? String
        let address = firstString(forKeys: tunnelAddressKeys, in: entry)
        guard state == connectedState || (state == nil && address != nil) else {
            throw CoreDeviceTunnelError.tunnelNotConnected(device: device, tunnelState: state)
        }
        guard let tunnelAddress = address, !tunnelAddress.isEmpty else {
            throw CoreDeviceTunnelError.missingTunnelAddress(device: device)
        }
        let reportedPort = firstPort(forKeys: rsdPortKeys, in: entry)
        return CoreDeviceTunnel(
            deviceIdentifier: entry[identifierKey] as? String ?? device,
            udid: (entry[hardwareKey] as? [String: Any])?[udidKey] as? String,
            name: (entry[devicePropertiesKey] as? [String: Any])?[nameKey] as? String,
            tunnelAddress: tunnelAddress,
            rsdPort: reportedPort ?? RSDClient.defaultPort,
            rsdPortSource: reportedPort == nil ? .wellKnownDefault : .reported)
    }

    static func deviceEntry(matching device: String, in json: Data) throws -> [String: Any] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: json)
        } catch {
            throw CoreDeviceTunnelError.unrecognisedOutput(reason: "not JSON: \(error.localizedDescription)")
        }
        guard let document = root as? [String: Any],
              let result = document[resultKey] as? [String: Any],
              let devices = result[devicesKey] as? [[String: Any]] else {
            throw CoreDeviceTunnelError.unrecognisedOutput(reason: "no result.devices array")
        }
        let wanted = device.lowercased()
        let match = devices.first { entry in
            let candidates = [
                entry[identifierKey] as? String,
                (entry[hardwareKey] as? [String: Any])?[udidKey] as? String,
                (entry[devicePropertiesKey] as? [String: Any])?[nameKey] as? String,
            ]
            return candidates.contains { $0?.lowercased() == wanted }
        }
        guard let match else { throw CoreDeviceTunnelError.deviceNotFound(device) }
        return match
    }

    /// Depth-first search for the first string value under any of `keys`,
    /// trying keys in priority order.
    static func firstString(forKeys keys: [String], in object: Any) -> String? {
        for key in keys {
            if let value = findValue(forKey: key, in: object) as? String { return value }
        }
        return nil
    }

    static func firstPort(forKeys keys: [String], in object: Any) -> Int? {
        for key in keys {
            switch findValue(forKey: key, in: object) {
            case let number as NSNumber where number.intValue > 0 && number.intValue <= Int(UInt16.max):
                return number.intValue
            case let text as String:
                if let port = Int(text), port > 0, port <= Int(UInt16.max) { return port }
            default:
                continue
            }
        }
        return nil
    }

    private static func findValue(forKey key: String, in object: Any) -> Any? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] { return value }
            for nested in dictionary.values {
                if let found = findValue(forKey: key, in: nested) { return found }
            }
        } else if let array = object as? [Any] {
            for nested in array {
                if let found = findValue(forKey: key, in: nested) { return found }
            }
        }
        return nil
    }
}

/// Runs `xcrun devicectl list devices` and extracts a device's tunnel.
/// Creating the tunnel (pairing, utun) is CoreDevice's job, not this type's:
/// it only reads what the system tunnel already provides.
public enum CoreDeviceTunnelLocator {
    static let xcrunPath = "/usr/bin/xcrun"
    /// Status reported when `xcrun` could not be launched at all.
    public static let launchFailureStatus: Int32 = -1

    /// Locates the tunnel of `device` (CoreDevice identifier, UDID or name).
    public static func locate(device: String) throws -> CoreDeviceTunnel {
        try DevicectlDeviceListParser.tunnel(for: device, in: listDevicesJSON())
    }

    /// The raw `devicectl list devices` JSON document.
    public static func listDevicesJSON() throws -> Data {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunPath)
        process.arguments = ["devicectl", "list", "devices", "--quiet", "--json-output", output.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CoreDeviceTunnelError.devicectlFailed(status: launchFailureStatus, stderr: "\(error)")
        }
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CoreDeviceTunnelError.devicectlFailed(
                status: process.terminationStatus,
                stderr: String(decoding: errorOutput, as: UTF8.self))
        }
        do {
            return try Data(contentsOf: output)
        } catch {
            throw CoreDeviceTunnelError.unrecognisedOutput(reason: "no JSON written: \(error.localizedDescription)")
        }
    }
}
