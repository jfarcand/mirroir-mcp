// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the HTTP/1.1 request parser behind `mirroir-mcp serve`.
// ABOUTME: Complete, partial, oversized and malformed requests, and the shape of a serialized response.

import XCTest
@testable import mirroir_mcp

final class HTTPRequestParserTests: XCTestCase {

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    func testParsesAPostWithContentLength() {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: 7\r\n\r\n{\"a\":1}trailing"
        guard case .complete(let request) = HTTPRequestParser.parse(bytes(raw)) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp", "the query string is not part of the path")
        XCTAssertEqual(request.headers["content-type"], "application/json", "names are lower-cased")
        XCTAssertEqual(request.headers["host"], "127.0.0.1")
        XCTAssertEqual(request.body, bytes("{\"a\":1}"), "exactly Content-Length bytes")
    }

    func testReportsIncompleteUntilTheBodyArrives() {
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n"
        XCTAssertEqual(HTTPRequestParser.parse(bytes(head)), .incomplete, "headers not ended")
        XCTAssertEqual(HTTPRequestParser.parse(bytes(head + "\r\n")), .incomplete, "no body yet")
        XCTAssertEqual(HTTPRequestParser.parse(bytes(head + "\r\n12345")), .incomplete, "half a body")
        guard case .complete = HTTPRequestParser.parse(bytes(head + "\r\n1234567890")) else {
            return XCTFail("expected a complete request")
        }
    }

    func testAGetNeedsNoLength() {
        guard case .complete(let request) = HTTPRequestParser.parse(bytes("GET /mcp HTTP/1.1\r\n\r\n")) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.body.isEmpty)
    }

    private func rejectedStatus(_ outcome: HTTPRequestParser.Outcome) -> Int? {
        guard case .rejected(let response) = outcome else { return nil }
        return response.status
    }

    func testRejectsOversizedHeadersAndBodies() {
        let filler = String(repeating: "a", count: HTTPRequestParser.maxHeaderBytes + 1)
        XCTAssertEqual(rejectedStatus(HTTPRequestParser.parse(bytes("POST /mcp HTTP/1.1\r\nX: " + filler))), 431,
                       "headers that never end")
        XCTAssertEqual(
            rejectedStatus(HTTPRequestParser.parse(bytes("POST /mcp HTTP/1.1\r\nX: " + filler + "\r\n\r\n"))), 431)
        let tooLong = "POST /mcp HTTP/1.1\r\nContent-Length: \(HTTPRequestParser.maxBodyBytes + 1)\r\n\r\n"
        XCTAssertEqual(rejectedStatus(HTTPRequestParser.parse(bytes(tooLong))), 413,
                       "refused from the header, before any body is read")
    }

    func testRejectsChunkedAndMissingLength() {
        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        XCTAssertEqual(rejectedStatus(HTTPRequestParser.parse(bytes(chunked))), 411)
        XCTAssertEqual(rejectedStatus(HTTPRequestParser.parse(bytes("POST /mcp HTTP/1.1\r\n\r\n"))), 411)
    }

    func testRejectsAMalformedRequestLine() {
        for line in ["NONSENSE", "POST /mcp", "POST mcp HTTP/1.1", "POST /mcp SPDY/3", " /mcp HTTP/1.1"] {
            XCTAssertEqual(rejectedStatus(HTTPRequestParser.parse(bytes(line + "\r\n\r\n"))), 400, line)
        }
        XCTAssertEqual(
            rejectedStatus(HTTPRequestParser.parse(bytes("POST /mcp HTTP/1.1\r\nno colon here\r\n\r\n"))), 400)
        XCTAssertEqual(rejectedStatus(
            HTTPRequestParser.parse(bytes("POST /mcp HTTP/1.1\r\nContent-Length: minus\r\n\r\n"))), 400)
    }

    /// Forms no HTTP client sends, each of which would let a header be read two ways.
    func testRejectsHeadersThatCouldBeReadTwoWays() {
        let cases = [
            "Origin : http://evil.example": "a space before the colon",
            "X-A: 1\nOrigin: http://evil.example": "a bare line feed",
            "X-A: 1\rOrigin: http://evil.example": "a bare carriage return",
            "Ori gin: x": "a space in a name",
            "Content-Length: 1\r\nContent-Length: 2": "two lengths",
            "Origin: http://a.example\r\nOrigin: http://b.example": "two origins",
            "Authorization: Bearer a\r\nauthorization: Bearer b": "two tokens, whatever the case",
        ]
        for (headers, why) in cases {
            let raw = "POST /mcp HTTP/1.1\r\n\(headers)\r\n\r\n"
            XCTAssertEqual(rejectedStatus(HTTPRequestParser.parse(bytes(raw))), 400, why)
        }
        for length in ["+3", "-1", " 3 3", "0x10", "3.0", ""] {
            let raw = "POST /mcp HTTP/1.1\r\nContent-Length: \(length)\r\n\r\nabc"
            XCTAssertEqual(rejectedStatus(HTTPRequestParser.parse(bytes(raw))), 400, "length '\(length)'")
        }
    }

    func testAHeaderThatMayRepeatKeepsItsLastValue() {
        let raw = "GET /mcp HTTP/1.1\r\nAccept: a\r\nAccept: b\r\n\r\n"
        guard case .complete(let request) = HTTPRequestParser.parse(bytes(raw)) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.headers["accept"], "b")
    }

    /// The headers are available as soon as they end, with the body still to come.
    func testTheHeadIsParsedBeforeTheBodyArrives() {
        let raw = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer x\r\nContent-Length: 500\r\n\r\npartial"
        guard case .parsed(let head) = HTTPRequestParser.head(of: bytes(raw)) else {
            return XCTFail("expected parsed headers")
        }
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.headers["authorization"], "Bearer x")
        XCTAssertEqual(head.contentLength, 500)
        XCTAssertNil(HTTPRequestParser.body(of: head, in: bytes(raw)), "the body is not all there")
        XCTAssertEqual(HTTPRequestParser.head(of: bytes("POST /mcp HTTP/1.1\r\nA: b\r\n")), .incomplete)
    }

    /// A buffer that is a slice of a larger one does not start at index zero.
    func testParsesASliceOfALargerBuffer() {
        let padded = bytes("XXXXXXXXPOST /mcp HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc")
        guard case .complete(let request) = HTTPRequestParser.parse(padded.dropFirst(8)) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.body, bytes("abc"))
    }

    func testSerializedResponseCarriesLengthAndClose() {
        let response = HTTPResponse.json(200, bytes("{\"ok\":true}"))
        let text = String(decoding: response.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }

    func testEveryStatusTheServerSendsHasAReasonPhrase() {
        for status in [200, 202, 400, 401, 403, 404, 405, 411, 413, 415, 431, 500, 503] {
            XCTAssertNotNil(HTTPResponse.reasonPhrases[status], "\(status)")
        }
    }
}
