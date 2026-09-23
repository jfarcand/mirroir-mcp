// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: devicectl device-list parsing tests: an unavailable device captured on a Mac, and a connected variant.
// ABOUTME: The connected fixture adds the documented tunnelIPAddress field; the only local device had no tunnel to capture.

import Foundation
import XCTest
@testable import MirroirCoreDevice

final class CoreDeviceTunnelLocatorTests: XCTestCase {
    /// Captured from `xcrun devicectl list devices --json-output` (devicectl
    /// 518.33) with the device's identifiers replaced; its tunnel is unavailable.
    private func unavailable() throws -> Data { try Fixture.data("devicectl_unavailable", "json") }
    /// The same document with `tunnelState: connected` and `tunnelIPAddress`,
    /// plus a second device listed first.
    private func connected() throws -> Data { try Fixture.data("devicectl_connected", "json") }

    func testUnavailableTunnelIsATypedError() throws {
        XCTAssertThrowsError(try DevicectlDeviceListParser.tunnel(for: "TestPhone", in: try unavailable())) { error in
            XCTAssertEqual(error as? CoreDeviceTunnelError,
                           .tunnelNotConnected(device: "TestPhone", tunnelState: "unavailable"))
        }
    }

    func testConnectedTunnelMatchedByIdentifierUDIDOrName() throws {
        for key in ["11111111-2222-3333-4444-555555555555", "00008140-0000000000000001", "testphone"] {
            let tunnel = try DevicectlDeviceListParser.tunnel(for: key, in: try connected())
            XCTAssertEqual(tunnel.deviceIdentifier, "11111111-2222-3333-4444-555555555555", key)
            XCTAssertEqual(tunnel.udid, "00008140-0000000000000001")
            XCTAssertEqual(tunnel.name, "TestPhone")
            XCTAssertEqual(tunnel.tunnelAddress, "fd7b:e5b:6f53::1")
            XCTAssertEqual(tunnel.rsdPort, RSDClient.defaultPort)
            XCTAssertEqual(tunnel.rsdPortSource, .wellKnownDefault)
        }
    }

    func testReportedRSDPortWinsOverTheDefault() throws {
        let json = try replacingInConnected("\"tunnelTransportProtocol\"", with: "\"rsdPort\" : 61234, \"tunnelTransportProtocol\"")
        let tunnel = try DevicectlDeviceListParser.tunnel(for: "TestPhone", in: json)
        XCTAssertEqual(tunnel.rsdPort, 61234)
        XCTAssertEqual(tunnel.rsdPortSource, .reported)
    }

    func testConnectedWithoutAnAddressIsATypedError() throws {
        let json = try replacingInConnected("\"tunnelIPAddress\"", with: "\"unrelatedKey\"")
        XCTAssertThrowsError(try DevicectlDeviceListParser.tunnel(for: "TestPhone", in: json)) { error in
            XCTAssertEqual(error as? CoreDeviceTunnelError, .missingTunnelAddress(device: "TestPhone"))
        }
    }

    func testUnknownDeviceAndGarbageAreTypedErrors() throws {
        XCTAssertThrowsError(try DevicectlDeviceListParser.tunnel(for: "nope", in: try connected())) { error in
            XCTAssertEqual(error as? CoreDeviceTunnelError, .deviceNotFound("nope"))
        }
        XCTAssertThrowsError(try DevicectlDeviceListParser.tunnel(for: "x", in: Data("{}".utf8))) { error in
            guard case .unrecognisedOutput? = error as? CoreDeviceTunnelError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try DevicectlDeviceListParser.tunnel(for: "x", in: Data("not json".utf8)))
    }

    /// Runs the real `xcrun devicectl` on this machine. No device in this
    /// repository's environments has a connected tunnel under this name, so
    /// the locator must end in a typed error, never a crash or a bogus tunnel.
    func testLiveLocatorEndsInATypedError() {
        XCTAssertThrowsError(try CoreDeviceTunnelLocator.locate(device: "mirroir-no-such-device")) { error in
            XCTAssertNotNil(error as? CoreDeviceTunnelError, "\(error)")
        }
    }

    private func replacingInConnected(_ target: String, with replacement: String) throws -> Data {
        let text = String(decoding: try connected(), as: UTF8.self)
        XCTAssertTrue(text.contains(target))
        return Data(text.replacingOccurrences(of: target, with: replacement).utf8)
    }
}
