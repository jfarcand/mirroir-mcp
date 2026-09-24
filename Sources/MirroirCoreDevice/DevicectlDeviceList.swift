// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Reads a device's CoreDevice tunnel state from `xcrun devicectl list devices --json-output`.
// ABOUTME: Also parses the NSError-shaped `error` object devicectl writes to its JSON output when a command fails.

import Foundation

/// `devicectl list devices` as a `TunnelStateReading`, and the parsing of the
/// JSON documents devicectl writes.
///
/// The observed shape (devicectl 518.33, `jsonVersion` 3) is
/// `result.devices[]` with `identifier`, `hardwareProperties.udid`,
/// `deviceProperties.name` and `connectionProperties.tunnelState`; a failed
/// command writes `error {domain, code, userInfo.NSLocalizedDescription.string}`.
public final class DevicectlDeviceList: TunnelStateReading {
    /// The state a device reports once its tunnel is usable.
    public static let connectedState = "connected"
    /// Status reported when `xcrun` could not be launched at all.
    public static let launchFailureStatus: Int32 = -1
    static let xcrunPath = "/usr/bin/xcrun"

    static let resultKey = "result"
    static let devicesKey = "devices"
    static let identifierKey = "identifier"
    static let hardwareKey = "hardwareProperties"
    static let udidKey = "udid"
    static let devicePropertiesKey = "deviceProperties"
    static let nameKey = "name"
    static let connectionKey = "connectionProperties"
    static let tunnelStateKey = "tunnelState"
    static let errorKey = "error"
    static let domainKey = "domain"
    static let codeKey = "code"
    static let userInfoKey = "userInfo"
    static let localizedDescriptionKey = "NSLocalizedDescription"
    static let stringKey = "string"

    public init() {}

    /// Runs `devicectl list devices` and reads the tunnel state of `device`.
    public func tunnelState(ofDevice device: String) throws -> String? {
        try Self.tunnelState(ofDevice: device, in: Self.listDevicesJSON())
    }

    /// The tunnel state of the device whose CoreDevice identifier, UDID or
    /// name equals `device` (case-insensitive) in a `list devices` document.
    public static func tunnelState(ofDevice device: String, in json: Data) throws -> String? {
        let entry = try deviceEntry(matching: device, in: json)
        return (entry[connectionKey] as? [String: Any])?[tunnelStateKey] as? String
    }

    /// The `error` a failed devicectl command recorded in its JSON output, or
    /// `nil` when the document holds none.
    public static func failure(in json: Data) -> CoreDeviceFailure? {
        guard let document = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let error = document[errorKey] as? [String: Any],
              let domain = error[domainKey] as? String,
              let code = (error[codeKey] as? NSNumber)?.int64Value else {
            return nil
        }
        let description = (error[userInfoKey] as? [String: Any])?[localizedDescriptionKey]
        let text = (description as? [String: Any])?[stringKey] as? String ?? description as? String
        return CoreDeviceFailure(domain: domain, code: code, localizedDescription: text)
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

    /// The raw `devicectl list devices` JSON document.
    static func listDevicesJSON() throws -> Data {
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
