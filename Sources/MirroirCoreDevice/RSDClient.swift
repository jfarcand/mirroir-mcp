// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Remote service discovery: reads the device's Handshake over RemoteXPC into a service-to-port map.
// ABOUTME: Port of go-ios ios/rsd.go (Handshake, GetPort with the .shim.remote fallback, GetService).
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// One service the device publishes through remote service discovery.
public struct RSDServiceEntry: Equatable, Sendable {
    /// TCP port on the device's tunnel address.
    public let port: Int
    /// The entitlement a client needs, when the device names one.
    public let entitlement: String?
    /// Service properties (`UsesRemoteXPC`, `ServiceVersion`, ...), when present.
    public let properties: RemoteXPCDictionary?

    public init(port: Int, entitlement: String? = nil, properties: RemoteXPCDictionary? = nil) {
        self.port = port
        self.entitlement = entitlement
        self.properties = properties
    }
}

/// The parsed RSD handshake: who the device is and where its services listen.
public struct RSDHandshake: Equatable, Sendable {
    /// Suffix of the lockdown shim variant of a service name.
    public static let shimSuffix = ".shim.remote"

    public let udid: String
    public let services: [String: RSDServiceEntry]
    /// The device's `Properties` dictionary (OS version, product type, ...).
    public let properties: RemoteXPCDictionary

    public init(udid: String, services: [String: RSDServiceEntry], properties: RemoteXPCDictionary) {
        self.udid = udid
        self.services = services
        self.properties = properties
    }

    /// The port of `service`, falling back to `<service>.shim.remote` as go-ios
    /// does. Throws when neither is published, rather than returning port 0:
    /// dialling 0 fails later with a misleading "connection refused".
    public func port(for service: String) throws -> Int {
        if let entry = services[service] { return entry.port }
        if let shim = services[service + Self.shimSuffix] { return shim.port }
        throw RSDError.serviceNotPublished(service)
    }

    /// The name of the service listening on `port`, if any.
    public func service(forPort port: Int) -> String? {
        services.first { $0.value.port == port }?.key
    }
}

/// Remote service discovery over RemoteXPC.
public enum RSDClient {
    /// The port RSD listens on over a CoreDevice tunnel (go-ios `rsd.go`).
    public static let defaultPort = 58_783

    static let messageTypeKey = "MessageType"
    static let handshakeMessageType = "Handshake"
    static let propertiesKey = "Properties"
    static let udidKey = "UniqueDeviceID"
    static let servicesKey = "Services"
    static let portKey = "Port"
    static let entitlementKey = "Entitlement"

    /// Connects to RSD at `host`:`port` over TCP and reads the handshake. The
    /// device sends it unprompted once the XPC init handshake completes.
    public static func handshake(host: String, port: Int = defaultPort) throws -> RSDHandshake {
        let transport = try NWConnectionTransport(host: host, port: port)
        let connection = try RemoteXPCConnection.open(transport: transport)
        defer { connection.close() }
        return try handshake(over: connection)
    }

    /// Reads and parses the handshake from an open RemoteXPC connection.
    public static func handshake(over connection: RemoteXPCConnection) throws -> RSDHandshake {
        let message = try connection.receiveOnClientServerStream()
        guard let body = message.body else {
            throw RemoteXPCError.missingBody(stream: RemoteXPCStream.clientServer.rawValue)
        }
        return try parse(body)
    }

    /// Parses a handshake body. Pure, so the parsing is testable without a device.
    public static func parse(_ body: RemoteXPCDictionary) throws -> RSDHandshake {
        let properties = body[propertiesKey]?.dictionaryValue ?? RemoteXPCDictionary()
        guard let udid = properties[udidKey]?.stringValue, !udid.isEmpty else {
            throw RSDError.missingUDID
        }
        let messageType = body[messageTypeKey]?.stringValue
        guard messageType == handshakeMessageType else {
            throw RSDError.unexpectedMessageType(messageType)
        }
        guard let servicesDictionary = body[servicesKey]?.dictionaryValue else {
            throw RSDError.missingServices
        }
        var services: [String: RSDServiceEntry] = [:]
        for entry in servicesDictionary.entries {
            guard let description = entry.value.dictionaryValue,
                  let port = parsePort(description[portKey]) else {
                throw RSDError.invalidPort(service: entry.key)
            }
            services[entry.key] = RSDServiceEntry(
                port: port,
                entitlement: description[entitlementKey]?.stringValue,
                properties: description[propertiesKey]?.dictionaryValue)
        }
        return RSDHandshake(udid: udid, services: services, properties: properties)
    }

    /// Devices send ports as decimal strings; integer forms are accepted too.
    static func parsePort(_ object: RemoteXPCObject?) -> Int? {
        let candidate: Int?
        switch object {
        case .string(let text)?:
            candidate = Int(text)
        case .uint64(let value)?:
            candidate = Int(exactly: value)
        case .int64(let value)?:
            candidate = Int(exactly: value)
        default:
            candidate = nil
        }
        guard let port = candidate, port > 0, port <= Int(UInt16.max) else { return nil }
        return port
    }
}
