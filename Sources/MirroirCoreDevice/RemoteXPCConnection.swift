// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: RemoteXPC client: XPC messages over HTTP/2 streams 1 and 3, with the three-message init handshake.
// ABOUTME: Port of go-ios CreateXpcConnection/initializeXpcConnection (connect.go) and xpc.Connection (xpc.go).
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// A RemoteXPC connection to one service on an iOS 17+ device.
///
/// Requests go out on the client-server stream (1); the device answers there
/// or, for server-initiated traffic and some replies, on the server-client
/// stream (3). Nothing in the framing pairs a reply with its request, so a
/// caller that needs replies must issue one request at a time.
public final class RemoteXPCConnection {
    /// The message id of every request, as go-ios sends it: its Connection
    /// initialises the id to 1 and never advances it, and devices accept that.
    public static let requestMessageID: UInt64 = 1
    /// The message id of the three init-handshake messages.
    public static let handshakeMessageID: UInt64 = 0

    private let http: HTTP2Connection
    private let stateLock = NSLock()
    private var isClosed = false

    /// Wraps an HTTP/2 connection whose init handshake has already run.
    /// Use `open(transport:)` to set one up from a bare transport.
    public init(http: HTTP2Connection) {
        self.http = http
    }

    /// Runs HTTP/2 set-up and the XPC init handshake over `transport`. The
    /// transport is closed when either step fails.
    public static func open(transport: ByteTransport) throws -> RemoteXPCConnection {
        let http: HTTP2Connection
        do {
            http = try HTTP2Connection(transport: transport)
        } catch {
            transport.close()
            throw error
        }
        let connection = RemoteXPCConnection(http: http)
        do {
            try connection.initialize()
        } catch {
            http.close()
            throw error
        }
        return connection
    }

    /// The init handshake from go-ios `initializeXpcConnection`:
    /// 1. stream 1: an empty-dictionary message with `alwaysSet`; read the reply on 1.
    /// 2. stream 3: a body-less message with `initHandshake | alwaysSet`; read the reply on 3.
    /// 3. stream 1: a body-less message with flags `0x201`; read the reply on 1.
    /// The replies' contents are read and discarded, as go-ios does.
    func initialize() throws {
        try write(RemoteXPCMessage(flags: .alwaysSet, messageID: Self.handshakeMessageID, body: RemoteXPCDictionary()),
                  on: .clientServer)
        _ = try receive(on: .clientServer)
        try write(RemoteXPCMessage(flags: [.initHandshake, .alwaysSet], messageID: Self.handshakeMessageID, body: nil),
                  on: .serverClient)
        _ = try receive(on: .serverClient)
        try write(RemoteXPCMessage(flags: [.alwaysSet, .handshakeCompletion], messageID: Self.handshakeMessageID,
                             body: nil),
                  on: .clientServer)
        _ = try receive(on: .clientServer)
    }

    /// Sends `body` on the client-server stream. `alwaysSet` is always set and
    /// `data` whenever a body is present, as in go-ios `Connection.Send`;
    /// `flags` adds to those (typically `.heartbeatRequest`).
    public func send(_ body: RemoteXPCDictionary?, flags: RemoteXPCMessageFlags = []) throws {
        var allFlags = flags.union(.alwaysSet)
        if body != nil { allFlags.insert(.data) }
        try write(RemoteXPCMessage(flags: allFlags, messageID: Self.requestMessageID, body: body), on: .clientServer)
    }

    /// Reads the next message from the client-server stream.
    public func receiveOnClientServerStream() throws -> RemoteXPCMessage {
        try receive(on: .clientServer)
    }

    /// Reads the next message from the server-client stream.
    public func receiveOnServerClientStream() throws -> RemoteXPCMessage {
        try receive(on: .serverClient)
    }

    /// Closes the connection. Idempotent.
    public func close() {
        let wasOpen = stateLock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        if wasOpen { http.close() }
    }

    private func checkOpen() throws {
        if stateLock.withLock({ isClosed }) { throw RemoteXPCError.connectionClosed }
    }

    private func write(_ message: RemoteXPCMessage, on stream: RemoteXPCStream) throws {
        try checkOpen()
        try http.write(XPCWireCodec.encodeMessage(message), on: stream)
    }

    /// Reads one framed message: the fixed wrapper first, then exactly the body
    /// length it declares (capped by the codec before anything is allocated).
    private func receive(on stream: RemoteXPCStream) throws -> RemoteXPCMessage {
        try checkOpen()
        let wrapper = try http.read(XPCWireCodec.wrapperHeaderLength, from: stream)
        let bodyLength = try XPCWireCodec.bodyLength(ofWrapper: wrapper)
        let body = bodyLength == 0 ? Data() : try http.read(bodyLength, from: stream)
        return try XPCWireCodec.decodeMessage(wrapper + body)
    }
}
