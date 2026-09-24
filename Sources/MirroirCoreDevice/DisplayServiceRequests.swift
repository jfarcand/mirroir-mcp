// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Builds the CoreDevice display-service requests that start and stop a video media stream.
// ABOUTME: Port of go-ios ios/display/display.go and coredevice.BuildRequestWithAction payload shapes.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// Where the device should send a display's RTP frames. The receiver must be
/// bound first: the device starts sending as soon as it answers.
public struct VideoStreamRequest: Equatable, Sendable {
    /// Main display.
    public static let defaultDisplayID = 1

    /// The host's tunnel address and bound UDP port (from an `RTPSink`).
    public let receiverIP: String
    public let receiverPort: Int
    /// The device's tunnel address.
    public let senderIP: String
    public let displayID: Int

    public init(receiverIP: String, receiverPort: Int, senderIP: String,
                displayID: Int = VideoStreamRequest.defaultDisplayID) {
        self.receiverIP = receiverIP
        self.receiverPort = receiverPort
        self.senderIP = senderIP
        self.displayID = displayID
    }
}

/// Request payloads for `com.apple.coredevice.displayservice`.
public enum DisplayServiceRequests {
    public static let serviceName = "com.apple.coredevice.displayservice"
    public static let featureStartMediaStream = "com.apple.coredevice.feature.startmediastream"
    public static let featureStopMediaStream = "com.apple.coredevice.feature.stopmediastream"
    public static let actionMediaStreamStart = "com.apple.coredevice.action.mediastreamstart"
    public static let actionMediaStreamStop = "com.apple.coredevice.action.mediastreamstop"

    /// Values Xcode sends over a tunnel; their meaning is undocumented.
    static let clientSupportedFeatures: UInt64 = 140
    static let accessNetworkType: Int64 = 1
    static let transportProtocolType: Int64 = 2
    /// The device's own negotiation deadline; kept under the caller's so the
    /// device gives up first and answers with an error.
    public static let negotiationTimeoutSeconds: UInt64 = 10

    /// CoreDevice protocol versions displayservice requires (go-ios BuildRequestWithAction).
    static let ddiProtocolVersion: Int64 = 2
    static let coreDeviceVersionComponents: [UInt64] = [629, 3]
    static let coreDeviceVersionString = "629.3"
    static let originalComponentsCount: Int64 = 2

    /// Key of the reply dictionary that carries a request's output.
    public static let outputKey = "CoreDevice.output"

    /// Wraps `input` in the CoreDevice request envelope, naming the action as
    /// displayservice requires.
    public static func coreDeviceRequest(deviceIdentifier: String, feature: String, action: String,
                                         input: RemoteXPCDictionary,
                                         invocationIdentifier: UUID = UUID()) -> RemoteXPCDictionary {
        let version: RemoteXPCDictionary = [
            "components": .array(coreDeviceVersionComponents.map(RemoteXPCObject.uint64)),
            "originalComponentsCount": .int64(originalComponentsCount),
            "stringValue": .string(coreDeviceVersionString),
        ]
        return [
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(ddiProtocolVersion),
            "CoreDevice.action": .dictionary(RemoteXPCDictionary()),
            "CoreDevice.actionIdentifier": .string(action),
            "CoreDevice.coreDeviceVersion": .dictionary(version),
            "CoreDevice.deviceIdentifier": .string(deviceIdentifier),
            "CoreDevice.featureIdentifier": .string(feature),
            "CoreDevice.input": .dictionary(input),
            "CoreDevice.invocationIdentifier": .string(invocationIdentifier.uuidString.lowercased()),
        ]
    }

    /// The `startmediastream` request for one display. `offer` comes from
    /// `DisplayStreamOffer.videoNegotiatorOffer`; `clientSessionID` identifies
    /// the stream and is what `stopMediaStream` names later.
    public static func startVideoStream(_ request: VideoStreamRequest, offer: Data, clientSessionID: UUID,
                                        deviceIdentifier: String) throws -> RemoteXPCDictionary {
        guard !request.receiverIP.isEmpty else { throw DisplayStreamError.missingAddress(field: "receiverIP") }
        guard request.receiverPort > 0 else { throw DisplayStreamError.missingAddress(field: "receiverPort") }
        guard !request.senderIP.isEmpty else { throw DisplayStreamError.missingAddress(field: "senderIP") }
        let options: RemoteXPCDictionary = [
            "AVCMediaStreamNegotiatorAccessNetworkType": .dictionary(["int": .int64(accessNetworkType)]),
            "AVCMediaStreamNegotiatorTransportProtocolType": .dictionary(["int": .int64(transportProtocolType)]),
            "CoreDeviceVideoDisplayMode": .dictionary(["string": .string("DisplayByID")]),
            "VideoStreamForDisplayID": .dictionary(["int": .int64(Int64(request.displayID))]),
            "avcMediaStreamOptionClientSessionID": .dictionary(["uuid": .uuid(clientSessionID)]),
        ]
        let input: RemoteXPCDictionary = [
            "clientSupportedFeatures": .uint64(clientSupportedFeatures),
            "direction": .string("output"),
            "negotiatorOffer": .data(offer),
            "options": .dictionary(options),
            "receiverIP": .string(request.receiverIP),
            "receiverPort": .uint64(UInt64(request.receiverPort)),
            "senderIP": .string(request.senderIP),
            "timeout": .uint64(negotiationTimeoutSeconds),
            "type": .string("video"),
        ]
        return coreDeviceRequest(deviceIdentifier: deviceIdentifier, feature: featureStartMediaStream,
                                 action: actionMediaStreamStart, input: input)
    }

    /// The `stopmediastream` request. The device rejects it unless `stopAll`
    /// is present and true, though a client only ever holds one stream.
    public static func stopMediaStream(clientSessionID: UUID, deviceIdentifier: String) -> RemoteXPCDictionary {
        let input: RemoteXPCDictionary = [
            "avcMediaStreamOptionClientSessionID": .dictionary(["uuid": .uuid(clientSessionID)]),
            "stopAll": .bool(true),
        ]
        return coreDeviceRequest(deviceIdentifier: deviceIdentifier, feature: featureStopMediaStream,
                                 action: actionMediaStreamStop, input: input)
    }
}
