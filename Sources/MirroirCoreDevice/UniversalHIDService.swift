// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: UniversalHID service request payloads and the RemoteXPC connection that delivers HID reports.
// ABOUTME: Port of go-ios ios/hid/payload.go and hid.go (universalConnection); wire shape confirmed by ipb captures.

import Foundation

/// Request payloads for `com.apple.coredevice.hid.universalhidservice`.
public enum UniversalHIDPayload {
    /// The RSD name of the service (ships in the iOS 27 Developer Disk Image, `dtuhidd`).
    public static let serviceName = "com.apple.coredevice.hid.universalhidservice"
    /// Feature identifier every request names.
    public static let featureIdentifier = "com.apple.coredevice.feature.remote.universalhidservice"
    /// `messageType` of a request.
    public static let requestMessageType = "Request"
    /// Service id the device gives its built-in touchscreen (`mainTouchscreen`, 0x101).
    public static let mainTouchscreenServiceID: UInt64 = 0x101

    static let featureIdentifierKey = "featureIdentifier"
    static let messageTypeKey = "messageType"
    static let payloadKey = "payload"
    static let sendKey = "send"
    static let reportArgumentKey = "_0"
    static let serviceArgumentKey = "_1"

    /// `{featureIdentifier, messageType: "Request", payload: {send: {_0: report, _1: serviceID}}}`.
    /// The report travels as XPC data and the service id as `uint64`; the
    /// device's Swift decoder rejects any other width.
    public static func sendReport(_ report: Data, serviceID: UInt64) -> RemoteXPCDictionary {
        let send: RemoteXPCDictionary = [
            reportArgumentKey: .data(report),
            serviceArgumentKey: .uint64(serviceID),
        ]
        return [
            featureIdentifierKey: .string(featureIdentifier),
            messageTypeKey: .string(requestMessageType),
            payloadKey: .dictionary([sendKey: .dictionary(send)]),
        ]
    }
}

/// Delivers HID reports over a RemoteXPC connection to the universal HID
/// service. Needs a CoreDevice tunnel, the iOS 27 Developer Disk Image mounted,
/// and a running display media stream: without one the device accepts every
/// report and discards it with no error (go-ios `ios/hid`).
public final class UniversalHIDConnection: HIDReportSending {
    private let connection: RemoteXPCConnection

    public init(connection: RemoteXPCConnection) {
        self.connection = connection
    }

    /// Resolves the service through `handshake` and opens a RemoteXPC
    /// connection to it on the device's tunnel address.
    public static func connect(tunnelAddress: String, handshake: RSDHandshake) throws -> UniversalHIDConnection {
        let port = try handshake.port(for: UniversalHIDPayload.serviceName)
        let transport = try NWConnectionTransport(host: tunnelAddress, port: port)
        return UniversalHIDConnection(connection: try RemoteXPCConnection.open(transport: transport))
    }

    /// Sends one report with the heartbeat-request flag, as go-ios does. The
    /// device returns nothing, so this reports the write, not its effect.
    public func sendReport(_ report: Data, serviceID: UInt64) throws {
        try connection.send(UniversalHIDPayload.sendReport(report, serviceID: serviceID),
                            flags: .heartbeatRequest)
    }

    public func close() {
        connection.close()
    }
}
