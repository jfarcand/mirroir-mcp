// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the loopback HTTP listener: a real NWListener on a free port, driven by URLSession and raw sockets.
// ABOUTME: Covers serving, the loopback-only bind, the read deadline, a port already taken, and one-at-a-time dispatch.

import Network
import XCTest
@testable import mirroir_mcp

final class NetworkHTTPServerTests: XCTestCase {

    private var servers: [NetworkHTTPServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
    }

    /// Start a listener whose responder refuses nothing before the body.
    private func start(
        readTimeout: TimeInterval = NetworkHTTPServer.readTimeout,
        refuse: @escaping @Sendable (HTTPRequest) -> HTTPResponse? = { _ in nil },
        respond: @escaping @Sendable (HTTPRequest, @escaping @Sendable () -> Bool) -> HTTPResponse
    ) throws -> UInt16 {
        let server = NetworkHTTPServer(port: 0, readTimeout: readTimeout) { _ in }
        servers.append(server)
        try server.start(responder: HTTPResponder(refuse: refuse, respond: respond))
        return try XCTUnwrap(server.boundPort)
    }

    private func start(handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws -> UInt16 {
        try start(respond: { request, _ in handler(request) })
    }

    private func post(_ body: String, port: UInt16) -> (status: Int?, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let done = expectation(description: "response")
        let result = Box<(Int?, String)>((nil, ""))
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            result.value = ((response as? HTTPURLResponse)?.statusCode,
                            String(decoding: data ?? Data(), as: UTF8.self))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        return result.value
    }

    func testServesAPostOnLoopback() throws {
        let port = try start { request in
            .json(200, Data("{\"echo\":\"\(request.method) \(request.path) \(request.body.count)\"}".utf8))
        }
        XCTAssertNotEqual(port, 0, "port 0 asks the system for a free one")
        let answer = post("{\"a\":1}", port: port)
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.body, "{\"echo\":\"POST /mcp 7\"}")
    }

    func testABodyLargerThanOneReadIsReassembled() throws {
        let port = try start { .text(200, String($0.body.count)) }
        let large = String(repeating: "x", count: 300_000)
        XCTAssertEqual(post(large, port: port).body, "300000\n")
    }

    func testBindsOnlyToLoopback() throws {
        guard case .hostPort(let host, let port) = NetworkHTTPServer.localEndpoint(port: 8765) else {
            return XCTFail("expected a host and port")
        }
        XCTAssertEqual("\(host)", "127.0.0.1")
        XCTAssertEqual(port.rawValue, 8765)
        XCTAssertEqual(NetworkHTTPServer.loopbackHost, "127.0.0.1")
    }

    /// The bind seen from outside: the port answers on loopback and not on the
    /// machine's other addresses.
    func testThePortIsClosedOnOtherAddresses() throws {
        let port = try start { _ in .text(200, "ok") }
        XCTAssertTrue(canConnect(host: "127.0.0.1", port: port))
        for address in Self.nonLoopbackIPv4Addresses() {
            XCTAssertFalse(canConnect(host: address, port: port), "reachable on \(address)")
        }
    }

    func testClosesAConnectionThatSendsNothing() throws {
        let port = try start(readTimeout: 0.3, respond: { _, _ in .text(200, "never") })
        let closed = expectation(description: "closed by the server")
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)), using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data("POST /mcp HTTP/1.1\r\n".utf8), completion: .contentProcessed { _ in })
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
            XCTAssertNil(data, "no answer to half a request")
            if isComplete || error != nil { closed.fulfill() }
        }
        wait(for: [closed], timeout: 5)
        connection.cancel()
    }

    func testASecondListenerOnTheSamePortIsRefused() throws {
        let port = try start { _ in .text(200, "first") }
        let second = NetworkHTTPServer(port: port) { _ in }
        let responder = HTTPResponder(refuse: { _ in nil }, respond: { _, _ in .text(200, "second") })
        XCTAssertThrowsError(try second.start(responder: responder)) {
            XCTAssertEqual($0 as? HTTPServerError, .portInUse(port))
            XCTAssertEqual($0.localizedDescription, "Port \(port) is in use. Pass --port.")
        }
    }

    func testAStoppedListenerFreesItsPort() throws {
        let port = try start { _ in .text(200, "ok") }
        servers.removeLast().stop()
        let deadline = Date().addingTimeInterval(5)
        while canConnect(host: "127.0.0.1", port: port), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(canConnect(host: "127.0.0.1", port: port))
    }

    func testRequestsAreAnsweredOneAtATime() throws {
        let loop = SerialJobLoop()
        Thread { loop.run() }.start()
        let overlap = Box<(running: Int, worst: Int)>((0, 0))
        let lock = NSLock()
        let port = try start { request in
            let served: String? = loop.perform {
                lock.withLock {
                    overlap.value.running += 1
                    overlap.value.worst = max(overlap.value.worst, overlap.value.running)
                }
                Thread.sleep(forTimeInterval: 0.05)
                lock.withLock { overlap.value.running -= 1 }
                return String(decoding: request.body, as: UTF8.self)
            }
            return .text(200, served ?? "")
        }

        let answers = Box<[String]>([])
        let all = expectation(description: "all answered")
        all.expectedFulfillmentCount = 6
        for index in 0..<6 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = Data("call-\(index)".utf8)
            URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, _ in
                lock.withLock { answers.value.append(String(decoding: data ?? Data(), as: UTF8.self)) }
                all.fulfill()
            }.resume()
        }
        wait(for: [all], timeout: 20)
        XCTAssertEqual(lock.withLock { overlap.value.worst }, 1, "two tool calls never overlap")
        XCTAssertEqual(Set(lock.withLock { answers.value }), Set((0..<6).map { "call-\($0)\n" }),
                       "each connection got its own answer")
    }

    /// Sends raw bytes and returns everything the server writes before closing.
    private func exchange(_ bytes: String, port: UInt16, thenClose: Bool = false) throws -> String {
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)), using: .tcp)
        let closed = expectation(description: "closed")
        let received = Box<Data>(Data())
        func readAll() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data { received.value.append(data) }
                if isComplete || error != nil { closed.fulfill() } else { readAll() }
            }
        }
        connection.start(queue: .global())
        connection.send(content: Data(bytes.utf8), completion: .contentProcessed { _ in
            guard thenClose else { return }
            connection.cancel()
            closed.fulfill()
        })
        if !thenClose { readAll() }
        wait(for: [closed], timeout: 10)
        connection.cancel()
        return String(decoding: received.value, as: UTF8.self)
    }

    /// A request refused on its headers is answered before its body is sent:
    /// the client here announces a megabyte and sends none of it.
    func testARefusalFromTheHeadersDoesNotWaitForTheBody() throws {
        let reachedResponder = Box(false)
        let port = try start(
            refuse: { $0.headers["authorization"] == nil ? .text(401, "no token") : nil },
            respond: { _, _ in
                reachedResponder.value = true
                return .text(200, "ok")
            })
        let answer = try exchange(
            "POST /mcp HTTP/1.1\r\nContent-Length: 1000000\r\n\r\n", port: port)
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 401 "), answer)
        XCTAssertFalse(reachedResponder.value)
    }

    /// A client that gives up while its call waits behind another: by the time
    /// the responder reaches the call, it is told nobody is waiting.
    func testACallWhoseClientLeftIsMarkedAbandoned() throws {
        let release = DispatchSemaphore(value: 0)
        let firstStarted = expectation(description: "first call running")
        let secondSeen = expectation(description: "second call reached")
        let abandonedFlags = Box<[String: Bool]>([:])
        let lock = NSLock()
        let port = try start(respond: { request, isAbandoned in
            let name = String(decoding: request.body, as: UTF8.self)
            if name == "first" {
                firstStarted.fulfill()
                release.wait()
            }
            lock.withLock { abandonedFlags.value[name] = isAbandoned() }
            if name == "second" { secondSeen.fulfill() }
            return .text(200, name)
        })

        let first = expectation(description: "first answered")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data("first".utf8)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, _ in
            XCTAssertEqual(String(decoding: data ?? Data(), as: UTF8.self), "first\n")
            first.fulfill()
        }.resume()
        wait(for: [firstStarted], timeout: 10)

        // The second client sends its whole request, then closes without waiting.
        _ = try exchange("POST /mcp HTTP/1.1\r\nContent-Length: 6\r\n\r\nsecond", port: port, thenClose: true)
        Thread.sleep(forTimeInterval: 0.3)
        release.signal()
        wait(for: [first, secondSeen], timeout: 10)
        XCTAssertEqual(lock.withLock { abandonedFlags.value }, ["first": false, "second": true])
    }

    func testAListenerThatStopsItselfDoesNotReportAFailure() throws {
        let failures = Box<[String]>([])
        let server = NetworkHTTPServer(port: 0) { failures.value.append($0) }
        try server.start(responder: HTTPResponder(refuse: { _ in nil }, respond: { _, _ in .text(200, "ok") }))
        server.stop()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(failures.value, [], "stopping on purpose is not a failure")
    }

    // MARK: - Helpers

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// How long `canConnect` waits for an answer, in milliseconds. An address
    /// that drops the packet instead of refusing it would otherwise hold the
    /// test for the system's connect timeout.
    private static let connectTimeoutMs: Int32 = 1000

    /// Whether a TCP connection to `host:port` is accepted within `connectTimeoutMs`.
    private func canConnect(host: String, port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&waiting, 1, Self.connectTimeoutMs) == 1 else { return false }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure == 0
    }

    /// The IPv4 addresses of this machine other than loopback.
    private static func nonLoopbackIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let raw = entry.pointee.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(raw, socklen_t(raw.pointee.sa_len), &name, socklen_t(name.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: name))
            }
        }
        return addresses
    }
}
