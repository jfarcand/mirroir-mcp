// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Typed errors for every layer of the CoreDevice stack: XPC codec, HTTP/2, transport, RSD, HID.
// ABOUTME: Each case carries the structured context a caller needs instead of a formatted string.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// Failures decoding or encoding Apple's XPC wire format.
public enum XPCCodecError: Error, Equatable, Sendable {
    /// The input ended before `needed` bytes could be read at `offset`.
    case truncated(offset: Int, needed: Int, available: Int)
    /// The message did not start with the RemoteXPC wrapper magic.
    case wrongWrapperMagic(UInt32)
    /// The body did not start with the XPC object magic.
    case wrongObjectMagic(UInt32)
    /// The body declared a protocol version this codec does not speak.
    case unsupportedBodyVersion(UInt32)
    /// The wrapper declared a body shorter than the 8-byte body header.
    case bodyLengthTooSmall(UInt64)
    /// The wrapper declared a body larger than the codec accepts.
    case bodyLengthTooLarge(declared: UInt64, limit: UInt64)
    /// The top-level object of a message body was not a dictionary.
    case topLevelNotDictionary
    /// An object carried a type tag this codec does not know.
    case unknownType(UInt32)
    /// A container declared more entries than bytes remain, so it cannot be well formed.
    case entryCountExceedsRemaining(container: String, count: UInt32, remaining: Int)
    /// A length field declared more bytes than remain in the body.
    case lengthExceedsRemaining(field: String, length: UInt32, remaining: Int)
    /// A string or dictionary key was not valid UTF-8.
    case invalidUTF8(field: String)
    /// A dictionary key was not NUL-terminated inside the body.
    case unterminatedKey
    /// Containers nested deeper than the codec's recursion limit.
    case nestingTooDeep(limit: Int)
    /// A file-transfer object did not carry its size in a `uint64` under `s`.
    case malformedFileTransfer
    /// A value is too large for its 32-bit wire length field.
    case valueTooLarge(field: String, length: Int)
}

/// Failures of the byte transport under HTTP/2.
public enum TransportError: Error, Equatable, Sendable {
    /// The peer closed the connection, or it was closed locally.
    case closed
    /// A connection or I/O operation did not complete within its deadline.
    case timedOut(operation: String)
    /// The operating system refused the connection or the I/O operation.
    case failed(operation: String, reason: String)
    /// The host or port could not be turned into a network endpoint.
    case invalidEndpoint(host: String, port: Int)
}

/// Protocol violations and peer-initiated failures on the HTTP/2 connection.
public enum HTTP2Error: Error, Equatable, Sendable {
    /// A frame declared a payload larger than this connection accepts.
    case frameTooLarge(length: Int, limit: Int)
    /// A frame's payload does not fit its type (SETTINGS not a multiple of 6, and so on).
    case malformedFrame(type: UInt8, reason: String)
    /// The peer sent GOAWAY.
    case goAway(lastStreamID: UInt32, errorCode: UInt32)
    /// The peer reset a stream.
    case streamReset(streamID: UInt32, errorCode: UInt32)
    /// DATA arrived on a stream RemoteXPC does not use.
    case unexpectedStream(UInt32)
    /// A write was attempted on a stream RemoteXPC does not use.
    case unsupportedStream(UInt32)
    /// The peer sent a SETTINGS value outside the range RFC 9113 allows.
    case invalidSetting(id: UInt16, value: UInt32)
    /// Data arrived for a stream faster than it was read, past the buffer cap.
    case receiveBufferOverflow(streamID: UInt32, buffered: Int, limit: Int)
}

/// Failures of the RemoteXPC layer above HTTP/2.
public enum RemoteXPCError: Error, Equatable, Sendable {
    /// A message expected to carry a body arrived without one.
    case missingBody(stream: UInt32)
    /// The connection was closed and cannot be used.
    case connectionClosed
}

/// Failures of the remote service discovery handshake.
public enum RSDError: Error, Equatable, Sendable {
    /// The device answered with a message type other than `Handshake`.
    case unexpectedMessageType(String?)
    /// The handshake carried no `Properties.UniqueDeviceID`.
    case missingUDID
    /// The handshake carried no `Services` dictionary.
    case missingServices
    /// A service entry's port was absent or not a valid port number.
    case invalidPort(service: String)
    /// No service by that name (nor its `.shim.remote` variant) is published.
    case serviceNotPublished(String)
}

/// Failures building a touchscreen digitizer report.
public enum TouchReportError: Error, Equatable, Sendable {
    /// A report must describe between one and the descriptor's maximum contacts.
    case contactCountOutOfRange(count: Int, maximum: Int)
    /// A contact identifier is outside the descriptor's logical range.
    case contactIdentifierOutOfRange(identifier: UInt8, maximum: UInt8)
    /// Two contacts in one report share an identifier.
    case duplicateContactIdentifier(UInt8)
}

/// Failures of the stateful multi-touch session.
public enum MultiTouchSessionError: Error, Equatable, Sendable {
    /// The session was closed.
    case closed
    /// `down` for a contact that is already held.
    case contactAlreadyDown(UInt8)
    /// `move` for a contact that is not held.
    case contactNotDown(UInt8)
}

/// A touch report that could not be written, and the lift the session sent to
/// recover from it. The device may have applied the failed report, so every
/// contact it described is lifted where that report put it.
public struct MultiTouchSendError: Error {
    /// Why the report was not written.
    public let underlying: Error
    /// The contacts of the recovery lift report, all with `touching == false`.
    public let recoveryLift: [TouchContact]
    /// Why the recovery lift was not written either. When set, the device may
    /// still consider `recoveryLift`'s contacts down.
    public let recoveryLiftError: Error?

    public init(underlying: Error, recoveryLift: [TouchContact], recoveryLiftError: Error?) {
        self.underlying = underlying
        self.recoveryLift = recoveryLift
        self.recoveryLiftError = recoveryLiftError
    }
}

/// Failures locating the macOS CoreDevice tunnel of a device.
public enum CoreDeviceTunnelError: Error, Equatable, Sendable {
    /// `devicectl` exited non-zero.
    case devicectlFailed(status: Int32, stderr: String)
    /// `devicectl` wrote JSON this parser does not recognise.
    case unrecognisedOutput(reason: String)
    /// No device matched the requested identifier.
    case deviceNotFound(String)
    /// The device is known but its tunnel is not connected.
    case tunnelNotConnected(device: String, tunnelState: String?)
    /// The tunnel is reported connected but carries no tunnel address.
    case missingTunnelAddress(device: String)
}

/// Failures of the display-stream request builders and the RTP sink.
public enum DisplayStreamError: Error, Equatable, Sendable {
    /// zlib reported an error compressing the media blob.
    case compressionFailed(status: Int32)
    /// The offer plist could not be serialised.
    case plistEncodingFailed(reason: String)
    /// The request lacks an address or port the device needs.
    case missingAddress(field: String)
}
