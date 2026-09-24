// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: createservicesocket tests with a fake CoreDeviceService: the request dictionary and every reply mapping.
// ABOUTME: Replies are real libxpc objects shaped like the ones CoreDeviceService 518.33 returned on a device.

import Foundation
import XCTest
import XPC
@testable import MirroirCoreDevice

/// Stands in for CoreDeviceService, which cannot grant a socket without a
/// paired iOS 27 device: records the request and returns a canned reply.
final class FakeCoreDeviceService: CoreDeviceServiceMessaging {
    private(set) var requests: [xpc_object_t] = []
    private(set) var timeouts: [TimeInterval] = []
    var reply: () throws -> xpc_object_t

    init(reply: @escaping () throws -> xpc_object_t) {
        self.reply = reply
    }

    func sendMessage(_ message: xpc_object_t, timeout: TimeInterval) throws -> xpc_object_t {
        requests.append(message)
        timeouts.append(timeout)
        return try reply()
    }
}

final class CoreDeviceServiceSocketTests: XCTestCase {
    private let device = "11111111-2222-3333-4444-555555555555"
    private let hidFeature = "com.apple.coredevice.feature.remote.universalhidservice"
    private let version = CoreDeviceVersion(parsing: "518.33")

    private func makeSocket(_ service: FakeCoreDeviceService) throws -> CoreDeviceServiceSocket {
        CoreDeviceServiceSocket(deviceIdentifier: device, version: try XCTUnwrap(version), messenger: service, timeout: 7)
    }

    /// `CoreDevice.error` as CoreDeviceService sends it.
    private func errorReply(domain: String = CoreDeviceFailure.coreDeviceErrorDomain, code: Int64,
                            description: String) -> xpc_object_t {
        let userInfo = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(userInfo, "NSLocalizedDescription", description)
        let error = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(error, "domain", domain)
        xpc_dictionary_set_int64(error, "code", code)
        xpc_dictionary_set_value(error, "userInfo", userInfo)
        let reply = xpc_dictionary_create_empty()
        xpc_dictionary_set_value(reply, "CoreDevice.error", error)
        return reply
    }

    private func string(_ dictionary: xpc_object_t, _ key: String) -> String? {
        xpc_dictionary_get_string(dictionary, key).map { String(cString: $0) }
    }

    // MARK: - Request

    func testFeatureRequestCarriesEveryCoreDeviceField() throws {
        let service = FakeCoreDeviceService { self.errorReply(code: 1001, description: "x") }
        XCTAssertThrowsError(try makeSocket(service).open(.feature(hidFeature)))
        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(service.timeouts, [7])

        XCTAssertEqual(string(request, "CoreDevice.actionIdentifier"), "com.apple.coredevice.action.createservicesocket")
        XCTAssertEqual(string(request, "CoreDevice.deviceIdentifier"), device)
        XCTAssertEqual(xpc_dictionary_get_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion"), 1)
        let invocation = try XCTUnwrap(string(request, "CoreDevice.invocationIdentifier"))
        XCTAssertNotNil(UUID(uuidString: invocation))
        XCTAssertEqual(invocation, invocation.uppercased())

        let version = try XCTUnwrap(xpc_dictionary_get_dictionary(request, "CoreDevice.coreDeviceVersion"))
        let components = try XCTUnwrap(xpc_dictionary_get_array(version, "components"))
        XCTAssertEqual(xpc_array_get_count(components), 2)
        XCTAssertTrue(xpc_get_type(xpc_array_get_value(components, 0)) == XPC_TYPE_UINT64)
        XCTAssertEqual(xpc_array_get_uint64(components, 0), 518)
        XCTAssertEqual(xpc_array_get_uint64(components, 1), 33)
        XCTAssertTrue(xpc_get_type(try XCTUnwrap(xpc_dictionary_get_value(version, "originalComponentsCount")))
                      == XPC_TYPE_INT64)
        XCTAssertEqual(xpc_dictionary_get_int64(version, "originalComponentsCount"), 2)
        XCTAssertEqual(string(version, "stringValue"), "518.33")

        let input = try XCTUnwrap(xpc_dictionary_get_dictionary(request, "CoreDevice.input"))
        XCTAssertEqual(xpc_dictionary_get_count(input), 1)
        XCTAssertEqual(string(input, "featureIdentifier"), hidFeature)
        XCTAssertEqual(xpc_dictionary_get_count(request), 6)
    }

    func testServiceNameRequestNamesOnlyTheService() throws {
        let service = FakeCoreDeviceService { self.errorReply(code: 1001, description: "x") }
        XCTAssertThrowsError(try makeSocket(service).open(.serviceName("com.example.service")))
        let input = try XCTUnwrap(xpc_dictionary_get_dictionary(try XCTUnwrap(service.requests.first), "CoreDevice.input"))
        XCTAssertEqual(xpc_dictionary_get_count(input), 1)
        XCTAssertEqual(string(input, "serviceName"), "com.example.service")
    }

    func testEveryRequestGetsItsOwnInvocationIdentifier() throws {
        let service = FakeCoreDeviceService { self.errorReply(code: 1001, description: "x") }
        let socket = try makeSocket(service)
        XCTAssertThrowsError(try socket.open(.feature(hidFeature)))
        XCTAssertThrowsError(try socket.open(.feature(hidFeature)))
        let ids = service.requests.map { string($0, "CoreDevice.invocationIdentifier") }
        XCTAssertNotEqual(ids[0], ids[1])
    }

    // MARK: - Error replies

    func testCapabilityNotSupportedIsATypedRefusal() throws {
        let description = "The capability \"Create Service Socket\" is not supported by this device."
        let service = FakeCoreDeviceService { self.errorReply(code: 1001, description: description) }
        XCTAssertThrowsError(try makeSocket(service).open(.feature(hidFeature))) { error in
            let expected = CoreDeviceFailure(domain: "com.apple.dt.CoreDeviceError", code: 1001,
                                             localizedDescription: description)
            XCTAssertEqual(error as? CoreDeviceServiceSocketError, .refused(expected))
            XCTAssertEqual(expected.reason, .capabilityNotSupported)
        }
    }

    func testConnectionNotEstablishedIsATypedRefusal() throws {
        let description = "A connection to this device has not been established."
        let service = FakeCoreDeviceService { self.errorReply(code: 1011, description: description) }
        XCTAssertThrowsError(try makeSocket(service).open(.feature(hidFeature))) { error in
            guard case .refused(let failure)? = error as? CoreDeviceServiceSocketError else { return XCTFail("\(error)") }
            XCTAssertEqual(failure.reason, .connectionNotEstablished)
            XCTAssertEqual(failure.code, 1011)
            XCTAssertEqual(failure.localizedDescription, description)
        }
    }

    func testOtherCodesAndDomainsKeepTheirRawValues() throws {
        XCTAssertEqual(CoreDeviceFailure(domain: CoreDeviceFailure.coreDeviceErrorDomain, code: 4000,
                                         localizedDescription: nil).reason, .remoteServiceDiscoveryUnavailable)
        XCTAssertEqual(CoreDeviceFailure(domain: CoreDeviceFailure.coreDeviceErrorDomain, code: 10005,
                                         localizedDescription: nil).reason, .developerModeDisabled)
        XCTAssertEqual(CoreDeviceFailure(domain: "NSPOSIXErrorDomain", code: 1001, localizedDescription: nil).reason,
                       .unrecognised)
        let service = FakeCoreDeviceService { self.errorReply(domain: "NSPOSIXErrorDomain", code: 61, description: "refused") }
        XCTAssertThrowsError(try makeSocket(service).open(.feature(hidFeature))) { error in
            XCTAssertEqual(error as? CoreDeviceServiceSocketError,
                           .refused(CoreDeviceFailure(domain: "NSPOSIXErrorDomain", code: 61, localizedDescription: "refused")))
        }
    }

    func testMalformedRepliesAreTypedErrors() throws {
        let noCode = xpc_dictionary_create_empty()
        let error = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(error, "domain", CoreDeviceFailure.coreDeviceErrorDomain)
        xpc_dictionary_set_value(noCode, "CoreDevice.error", error)
        let replies: [xpc_object_t] = [xpc_dictionary_create_empty(), noCode, xpc_string_create("nope")]
        for reply in replies {
            let service = FakeCoreDeviceService { reply }
            XCTAssertThrowsError(try makeSocket(service).open(.feature(hidFeature))) { error in
                guard case .malformedReply? = error as? CoreDeviceServiceSocketError else { return XCTFail("\(error)") }
            }
        }
    }

    func testAnXPCConnectionErrorIsATypedError() throws {
        let service = FakeCoreDeviceService { XPC_ERROR_CONNECTION_INVALID }
        XCTAssertThrowsError(try makeSocket(service).open(.feature(hidFeature))) { error in
            guard case .serviceConnectionFailed(let description)? = error as? CoreDeviceServiceSocketError else {
                return XCTFail("\(error)")
            }
            XCTAssertFalse(description.isEmpty)
        }
    }

    func testTimeoutFromTheServicePropagates() throws {
        let service = FakeCoreDeviceService { throw CoreDeviceServiceSocketError.timedOut(seconds: 7) }
        XCTAssertThrowsError(try makeSocket(service).open(.feature(hidFeature))) { error in
            XCTAssertEqual(error as? CoreDeviceServiceSocketError, .timedOut(seconds: 7))
        }
    }

    // MARK: - Success reply

    private func successReply(descriptor: Int32?) -> xpc_object_t {
        let output = xpc_dictionary_create_empty()
        if let descriptor { xpc_dictionary_set_fd(output, "fileDescriptor", descriptor) }
        xpc_dictionary_set_uint64(output, "remoteXPCVersionFlags", 0x0100_0000_0000_0006)
        let features = xpc_array_create_empty()
        xpc_array_append_value(features, xpc_string_create(hidFeature))
        xpc_dictionary_set_value(output, "featureIdentifiers", features)
        let reply = xpc_dictionary_create_empty()
        xpc_dictionary_set_value(reply, "CoreDevice.output", output)
        return reply
    }

    func testSuccessReplyYieldsATransportOnTheGrantedSocket() throws {
        let (granted, peer) = try SocketPair.make()
        defer { Darwin.close(peer) }
        let reply = successReply(descriptor: granted)
        Darwin.close(granted)
        let grant = try makeSocket(FakeCoreDeviceService { reply }).open(.feature(hidFeature))
        XCTAssertEqual(grant.remoteXPCVersionFlags, 0x0100_0000_0000_0006)
        XCTAssertEqual(grant.featureIdentifiers, [hidFeature])

        try grant.transport.write(Data([1, 2, 3]))
        var bytes = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(Darwin.read(peer, &bytes, 3), 3)
        XCTAssertEqual(bytes, [1, 2, 3])
        grant.transport.close()
    }

    func testSuccessWithoutADescriptorIsATypedError() throws {
        let reply = successReply(descriptor: nil)
        XCTAssertThrowsError(try makeSocket(FakeCoreDeviceService { reply }).open(.feature(hidFeature))) { error in
            XCTAssertEqual(error as? CoreDeviceServiceSocketError, .missingFileDescriptor)
        }
    }

    /// The HID connection asks for the universal HID feature and runs
    /// RemoteXPC on the socket it is granted.
    func testUniversalHIDConnectsThroughTheGrantedSocket() throws {
        let (granted, peer) = try SocketPair.make()
        let device = SocketPeer(descriptor: peer, script: DeviceScript.settings() + (try DeviceScript.handshakeReplies()))
        let reply = successReply(descriptor: granted)
        Darwin.close(granted)
        let service = FakeCoreDeviceService { reply }
        let hid = try UniversalHIDConnection.connect(through: try makeSocket(service))
        hid.close()
        let input = try XCTUnwrap(xpc_dictionary_get_dictionary(try XCTUnwrap(service.requests.first), "CoreDevice.input"))
        XCTAssertEqual(string(input, "featureIdentifier"), UniversalHIDPayload.featureIdentifier)
        XCTAssertTrue(try device.receivedAfterClientCloses().starts(with: HTTP2Framer.clientPreface))
    }

    // MARK: - Version

    func testVersionParsing() throws {
        XCTAssertEqual(CoreDeviceVersion(parsing: "518.33")?.components, [518, 33])
        XCTAssertEqual(CoreDeviceVersion(parsing: "636.3.1")?.stringValue, "636.3.1")
        for invalid in ["", "518.", "a.b", "518..33", "-1.2"] {
            XCTAssertNil(CoreDeviceVersion(parsing: invalid), invalid)
        }
    }

    func testInstalledVersionIsReadFromTheInfoPlist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coredevice-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "518.33"], format: .xml, options: 0)
        try plist.write(to: url)
        XCTAssertEqual(try CoreDeviceVersion.installed(infoPlistPath: url.path).components, [518, 33])

        XCTAssertThrowsError(try CoreDeviceVersion.installed(infoPlistPath: url.path + ".missing")) { error in
            guard case .versionUnreadable? = error as? CoreDeviceServiceSocketError else { return XCTFail("\(error)") }
        }
    }
}
