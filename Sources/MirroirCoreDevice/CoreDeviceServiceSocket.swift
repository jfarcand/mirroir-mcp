// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Asks the Mac's CoreDeviceService (libxpc) for a connected device service socket: createservicesocket.
// ABOUTME: Builds the request dictionary, maps CoreDevice.error to typed errors and adopts the returned socket fd.

import Foundation
import XPC

/// A CoreDevice version, as the `CoreDevice.coreDeviceVersion` field of a
/// CoreDeviceService request carries it: numeric components plus their string
/// form. Requests report the version installed on this Mac.
public struct CoreDeviceVersion: Equatable, Sendable {
    /// Where the installed CoreDevice framework records its version.
    public static let installedInfoPlistPath =
        "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/Info.plist"
    static let shortVersionKey = "CFBundleShortVersionString"
    static let componentSeparator: Character = "."

    /// The numeric components, most significant first (`518.33` is `[518, 33]`).
    public let components: [UInt64]

    /// Parses a dotted version such as `518.33`; `nil` unless every
    /// component is an unsigned integer.
    public init?(parsing text: String) {
        let parts = text.split(separator: Self.componentSeparator, omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt64($0) }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        components = numbers
    }

    /// The dotted string form, as `stringValue` carries it.
    public var stringValue: String {
        components.map(String.init).joined(separator: String(Self.componentSeparator))
    }

    /// Reads the version of the CoreDevice framework installed on this Mac.
    public static func installed(infoPlistPath: String = installedInfoPlistPath) throws -> CoreDeviceVersion {
        let url = URL(fileURLWithPath: infoPlistPath)
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        } catch {
            throw CoreDeviceServiceSocketError.versionUnreadable(path: infoPlistPath, reason: "\(error)")
        }
        guard let version = (plist as? [String: Any])?[shortVersionKey] as? String else {
            throw CoreDeviceServiceSocketError.versionUnreadable(path: infoPlistPath, reason: "no \(shortVersionKey)")
        }
        guard let parsed = CoreDeviceVersion(parsing: version) else {
            throw CoreDeviceServiceSocketError.versionUnreadable(path: infoPlistPath, reason: "unparseable \(version)")
        }
        return parsed
    }
}

/// What a service socket connects to on the device.
public enum CoreDeviceServiceTarget: Equatable, Sendable {
    /// A CoreDevice feature, e.g. `com.apple.coredevice.feature.remote.universalhidservice`.
    case feature(String)
    /// A RemoteXPC service by name.
    case serviceName(String)
}

/// A connected service socket CoreDeviceService handed over, already adopted
/// by a transport that closes it.
public struct CoreDeviceServiceSocketGrant {
    /// The connected socket.
    public let transport: FileDescriptorTransport
    /// `remoteXPCVersionFlags` from the reply: the RemoteXPC protocol flags
    /// Apple's own client passes when it opens a connection on this socket.
    public let remoteXPCVersionFlags: UInt64
    /// `featureIdentifiers` from the reply: the features the socket serves.
    public let featureIdentifiers: [String]
}

/// The `createservicesocket` action of the Mac's CoreDeviceService: the host
/// path Apple's own tools use to reach a device service through the
/// CoreDevice tunnel. The device must be leased (see `CoreDeviceTunnelLease`)
/// or the service answers 1011, and run iOS 27 with the Xcode 27 Developer
/// Disk Image or it answers 1001.
public struct CoreDeviceServiceSocket {
    /// Bound on one CoreDeviceService request. The service answers in well
    /// under a second when the tunnel is up; it waits on the tunnel otherwise.
    public static let defaultTimeout: TimeInterval = 30
    /// The action that asks for a connected service socket.
    public static let createServiceSocketAction = "com.apple.coredevice.action.createservicesocket"
    /// The Developer Disk Image protocol version Apple's clients send.
    public static let ddiProtocolVersion: Int64 = 1

    static let actionIdentifierKey = "CoreDevice.actionIdentifier"
    static let deviceIdentifierKey = "CoreDevice.deviceIdentifier"
    static let coreDeviceVersionKey = "CoreDevice.coreDeviceVersion"
    static let ddiProtocolVersionKey = "CoreDevice.CoreDeviceDDIProtocolVersion"
    static let invocationIdentifierKey = "CoreDevice.invocationIdentifier"
    static let inputKey = "CoreDevice.input"
    static let outputKey = "CoreDevice.output"
    static let errorKey = "CoreDevice.error"
    static let versionComponentsKey = "components"
    static let versionOriginalCountKey = "originalComponentsCount"
    static let versionStringKey = "stringValue"
    static let featureIdentifierKey = "featureIdentifier"
    static let serviceNameKey = "serviceName"
    static let fileDescriptorKey = "fileDescriptor"
    static let remoteXPCVersionFlagsKey = "remoteXPCVersionFlags"
    static let featureIdentifiersKey = "featureIdentifiers"
    static let errorDomainKey = "domain"
    static let errorCodeKey = "code"
    static let errorUserInfoKey = "userInfo"
    static let localizedDescriptionKey = "NSLocalizedDescription"

    /// The CoreDevice identifier of the device (a UUID, not its UDID).
    public let deviceIdentifier: String
    public let version: CoreDeviceVersion
    private let messenger: CoreDeviceServiceMessaging
    private let timeout: TimeInterval

    public init(deviceIdentifier: String, version: CoreDeviceVersion, messenger: CoreDeviceServiceMessaging,
                timeout: TimeInterval = CoreDeviceServiceSocket.defaultTimeout) {
        self.deviceIdentifier = deviceIdentifier
        self.version = version
        self.messenger = messenger
        self.timeout = timeout
    }

    /// A client for `deviceIdentifier` that reports the installed CoreDevice
    /// version and talks to the real CoreDeviceService.
    public static func installed(deviceIdentifier: String) throws -> CoreDeviceServiceSocket {
        CoreDeviceServiceSocket(deviceIdentifier: deviceIdentifier, version: try CoreDeviceVersion.installed(),
                                messenger: CoreDeviceServiceConnection())
    }

    /// Asks CoreDeviceService for a socket connected to `target` on the device.
    public func open(_ target: CoreDeviceServiceTarget) throws -> CoreDeviceServiceSocketGrant {
        let request = Self.makeRequest(deviceIdentifier: deviceIdentifier, target: target, version: version,
                                       invocationIdentifier: UUID())
        return try Self.grant(fromReply: try messenger.sendMessage(request, timeout: timeout))
    }

    /// The `createservicesocket` request dictionary.
    static func makeRequest(deviceIdentifier: String, target: CoreDeviceServiceTarget, version: CoreDeviceVersion,
                            invocationIdentifier: UUID) -> xpc_object_t {
        let input = xpc_dictionary_create_empty()
        switch target {
        case .feature(let feature):
            xpc_dictionary_set_string(input, featureIdentifierKey, feature)
        case .serviceName(let name):
            xpc_dictionary_set_string(input, serviceNameKey, name)
        }
        let components = xpc_array_create_empty()
        for component in version.components {
            xpc_array_append_value(components, xpc_uint64_create(component))
        }
        let versionObject = xpc_dictionary_create_empty()
        xpc_dictionary_set_value(versionObject, versionComponentsKey, components)
        xpc_dictionary_set_int64(versionObject, versionOriginalCountKey, Int64(version.components.count))
        xpc_dictionary_set_string(versionObject, versionStringKey, version.stringValue)

        let request = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(request, actionIdentifierKey, createServiceSocketAction)
        xpc_dictionary_set_string(request, deviceIdentifierKey, deviceIdentifier)
        xpc_dictionary_set_value(request, coreDeviceVersionKey, versionObject)
        xpc_dictionary_set_int64(request, ddiProtocolVersionKey, ddiProtocolVersion)
        xpc_dictionary_set_string(request, invocationIdentifierKey, invocationIdentifier.uuidString.uppercased())
        xpc_dictionary_set_value(request, inputKey, input)
        return request
    }

    /// Maps a CoreDeviceService reply to a grant or a typed error.
    static func grant(fromReply reply: xpc_object_t) throws -> CoreDeviceServiceSocketGrant {
        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            let description = string(in: reply, key: String(cString: XPC_ERROR_KEY_DESCRIPTION)) ?? "unknown XPC error"
            throw CoreDeviceServiceSocketError.serviceConnectionFailed(description: description)
        }
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
            throw CoreDeviceServiceSocketError.malformedReply(reason: "reply is not a dictionary")
        }
        if let error = xpc_dictionary_get_dictionary(reply, errorKey) {
            throw CoreDeviceServiceSocketError.refused(try failure(from: error))
        }
        guard let output = xpc_dictionary_get_dictionary(reply, outputKey) else {
            throw CoreDeviceServiceSocketError.malformedReply(reason: "no \(outputKey) and no \(errorKey)")
        }
        let descriptor = xpc_dictionary_dup_fd(output, fileDescriptorKey)
        guard descriptor >= 0 else { throw CoreDeviceServiceSocketError.missingFileDescriptor }
        let transport = try FileDescriptorTransport(adopting: descriptor)
        return CoreDeviceServiceSocketGrant(
            transport: transport,
            remoteXPCVersionFlags: xpc_dictionary_get_uint64(output, remoteXPCVersionFlagsKey),
            featureIdentifiers: strings(in: xpc_dictionary_get_array(output, featureIdentifiersKey)))
    }

    /// Reads `{domain, code, userInfo.NSLocalizedDescription}`.
    static func failure(from error: xpc_object_t) throws -> CoreDeviceFailure {
        guard let domain = string(in: error, key: errorDomainKey), let code = integer(in: error, key: errorCodeKey) else {
            throw CoreDeviceServiceSocketError.malformedReply(reason: "\(errorKey) without domain and code")
        }
        let description = xpc_dictionary_get_dictionary(error, errorUserInfoKey)
            .flatMap { string(in: $0, key: localizedDescriptionKey) }
        return CoreDeviceFailure(domain: domain, code: code, localizedDescription: description)
    }

    private static func string(in dictionary: xpc_object_t, key: String) -> String? {
        xpc_dictionary_get_string(dictionary, key).map { String(cString: $0) }
    }

    /// Error codes arrive as `int64`; an unsigned encoding is accepted too.
    private static func integer(in dictionary: xpc_object_t, key: String) -> Int64? {
        guard let value = xpc_dictionary_get_value(dictionary, key) else { return nil }
        if xpc_get_type(value) == XPC_TYPE_INT64 { return xpc_int64_get_value(value) }
        if xpc_get_type(value) == XPC_TYPE_UINT64 { return Int64(exactly: xpc_uint64_get_value(value)) }
        return nil
    }

    private static func strings(in array: xpc_object_t?) -> [String] {
        guard let array, xpc_get_type(array) == XPC_TYPE_ARRAY else { return [] }
        return (0..<xpc_array_get_count(array)).compactMap { index in
            xpc_array_get_string(array, index).map { String(cString: $0) }
        }
    }
}
