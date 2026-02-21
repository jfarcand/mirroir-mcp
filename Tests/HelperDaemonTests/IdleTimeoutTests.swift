// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for client idle timeout and SO_SNDTIMEO behavior in CommandServer.
// ABOUTME: Verifies that idle clients are dropped after consecutive recv timeouts.

import XCTest
import Darwin
import Foundation
import HelperLib
@testable import mirroir_helper

final class IdleTimeoutTests: XCTestCase {

    private var server: CommandServer!
    private var karabiner: StubKarabiner!

    override func setUp() {
        super.setUp()
        karabiner = StubKarabiner()
        server = CommandServer(karabiner: karabiner)
        server.running = true
    }

    override func tearDown() {
        server.running = false
        server = nil
        karabiner = nil
        super.tearDown()
    }

    /// Create a connected Unix socket pair. Returns (serverFd, clientFd).
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw NSError(domain: "test", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        return (fds[0], fds[1])
    }

    /// Set SO_RCVTIMEO on a socket to a short interval for fast test execution.
    private func setShortRecvTimeout(_ fd: Int32, milliseconds: Int = 100) {
        var timeout = timeval(tv_sec: 0, tv_usec: Int32(milliseconds * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Idle Timeout Tests

    func testIdleClientDroppedAfterMaxTimeouts() throws {
        let (serverFd, clientFd) = try makeSocketPair()
        defer { Darwin.close(clientFd) }

        // Use a very short recv timeout so the test completes quickly.
        // With 100ms timeout and default maxIdleTimeouts=4, client should
        // be dropped after ~400ms of idle.
        setShortRecvTimeout(serverFd, milliseconds: 100)

        let expectation = XCTestExpectation(description: "handleClient returns after idle timeout")

        DispatchQueue.global().async {
            self.server.handleClient(fd: serverFd)
            // Close serverFd after handleClient returns so the client
            // side sees EOF. In production, the caller (start()) does this.
            Darwin.close(serverFd)
            expectation.fulfill()
        }

        // Client stays idle — sends nothing. handleClient should exit
        // after clientIdleMaxTimeouts consecutive EAGAIN results.
        wait(for: [expectation], timeout: 5.0)

        // Verify the connection was closed by trying to read from the client side.
        // Since serverFd was closed above, recv should return 0 (EOF).
        var buf = [UInt8](repeating: 0, count: 1)
        let bytesRead = recv(clientFd, &buf, buf.count, 0)
        XCTAssertEqual(bytesRead, 0, "Client should see EOF after server drops the connection")
    }

    func testRealDataResetsIdleCounter() throws {
        let (serverFd, clientFd) = try makeSocketPair()
        defer {
            Darwin.close(serverFd)
            Darwin.close(clientFd)
        }

        setShortRecvTimeout(serverFd, milliseconds: 100)
        // Also set a recv timeout on the client side so response reads don't block
        setShortRecvTimeout(clientFd, milliseconds: 500)

        let startTime = CFAbsoluteTimeGetCurrent()

        // Track when handleClient exits
        let handleClientDone = XCTestExpectation(description: "handleClient returns")

        DispatchQueue.global().async {
            self.server.handleClient(fd: serverFd)
            handleClientDone.fulfill()
        }

        // Send a command partway through the idle window to reset the counter.
        // With 100ms timeout and maxIdle=4, the threshold is ~400ms.
        // We send data at ~250ms to reset the counter, then wait for the
        // full idle timeout to occur.
        let maxIdle = TimingConstants.clientIdleMaxTimeouts
        let perTimeoutMs = 100
        let resetPoint = (maxIdle - 1) * perTimeoutMs

        // Wait until just before the idle threshold, then send data
        Thread.sleep(forTimeInterval: Double(resetPoint) / 1000.0)
        let command = Data(#"{"action":"status"}"#.utf8 + [0x0A])
        _ = command.withUnsafeBytes { buf in
            send(clientFd, buf.baseAddress, buf.count, 0)
        }

        // Read the response to keep the socket flowing
        var responseBuf = [UInt8](repeating: 0, count: 4096)
        _ = recv(clientFd, &responseBuf, responseBuf.count, 0)

        // Now stay idle again — counter was reset, so it needs another
        // maxIdle timeouts before dropping.
        wait(for: [handleClientDone], timeout: 5.0)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let minExpected = Double(resetPoint + maxIdle * perTimeoutMs) / 1000.0

        // The total elapsed time should be longer than if data hadn't been sent,
        // proving the counter was reset. Without the reset, it would take ~400ms.
        // With the reset, it takes ~300ms (pre-reset idle) + ~400ms (post-reset idle) = ~700ms.
        XCTAssertGreaterThan(elapsed, minExpected * 0.8,
                             "Elapsed \(elapsed)s should exceed \(minExpected)s — data should have reset the idle counter")
    }

    func testCleanDisconnectExitsImmediately() throws {
        let (serverFd, clientFd) = try makeSocketPair()
        defer { Darwin.close(serverFd) }

        setShortRecvTimeout(serverFd, milliseconds: 100)

        let expectation = XCTestExpectation(description: "handleClient returns on clean disconnect")

        DispatchQueue.global().async {
            self.server.handleClient(fd: serverFd)
            expectation.fulfill()
        }

        // Close the client side immediately — server sees recv() == 0
        Darwin.close(clientFd)

        // handleClient should exit almost immediately, not wait for idle timeouts
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - SO_SNDTIMEO Tests

    func testSendTimeoutIsConfigurable() throws {
        // Verify that SO_SNDTIMEO can be set and read back correctly,
        // validating the same code path used in CommandServer.start()
        let (serverFd, clientFd) = try makeSocketPair()
        defer {
            Darwin.close(serverFd)
            Darwin.close(clientFd)
        }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let setResult = setsockopt(serverFd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                                   socklen_t(MemoryLayout<timeval>.size))
        XCTAssertEqual(setResult, 0, "setsockopt SO_SNDTIMEO should succeed")

        var readback = timeval()
        var readbackLen = socklen_t(MemoryLayout<timeval>.size)
        let getResult = getsockopt(serverFd, SOL_SOCKET, SO_SNDTIMEO, &readback, &readbackLen)
        XCTAssertEqual(getResult, 0, "getsockopt SO_SNDTIMEO should succeed")
        XCTAssertEqual(readback.tv_sec, 5, "SO_SNDTIMEO should be 5 seconds")
    }
}
