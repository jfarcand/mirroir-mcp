// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The HTTP/1.1 request and response values `mirroir-mcp serve` exchanges, and the request parser.
// ABOUTME: One request per connection with a Content-Length body: the least HTTP an MCP endpoint needs.

import Foundation

/// One HTTP request, as far as the MCP endpoint reads it.
struct HTTPRequest: Sendable, Equatable {
    /// The request method, as sent (`POST`).
    let method: String
    /// The request target without its query string.
    let path: String
    /// Header values by lower-cased name.
    let headers: [String: String]
    let body: Data
}

/// One HTTP response. `serialized()` adds `Content-Length` and `Connection: close`.
struct HTTPResponse: Sendable, Equatable {
    let status: Int
    var headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A response whose body is a line of plain text.
    static func text(_ status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
        var all = headers
        all["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: all, body: Data((message + "\n").utf8))
    }

    /// A response whose body is JSON already encoded.
    static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    /// The reason phrases of the statuses the server sends.
    static let reasonPhrases: [Int: String] = [
        200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 411: "Length Required",
        413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large",
        500: "Internal Server Error", 503: "Service Unavailable",
    ]

    /// The bytes to write: status line, headers, blank line, body. Every
    /// response closes its connection, so a client never waits on a second one.
    func serialized() -> Data {
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        let reason = Self.reasonPhrases[status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for name in all.keys.sorted() {
            head += "\(name): \(all[name] ?? "")\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// How a listener answers what it reads.
struct HTTPResponder: Sendable {
    /// Called once, when the headers are in and before any body is read, with
    /// an empty body. A response here refuses the request and closes.
    let refuse: @Sendable (HTTPRequest) -> HTTPResponse?
    /// Called with the whole request. `isAbandoned` turns true once the client
    /// has closed its connection, so work it no longer waits for can be skipped.
    let respond: @Sendable (HTTPRequest, _ isAbandoned: @escaping @Sendable () -> Bool) -> HTTPResponse
}

/// The request line and headers of a request, and where its body lies.
struct HTTPRequestHead: Sendable, Equatable {
    let method: String
    let path: String
    let headers: [String: String]
    /// Bytes from the start of the buffer to the first byte of the body.
    let bodyOffset: Int
    let contentLength: Int

    /// The request with `body`.
    func request(body: Data) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

/// Parses one HTTP/1.1 request out of the bytes read so far. It accepts the
/// plain form every HTTP client sends and refuses the rest: a header the
/// endpoint decides on must never be readable two ways.
enum HTTPRequestParser {

    /// Largest request line plus headers accepted.
    static let maxHeaderBytes = 16 * 1024
    /// Largest body accepted. A tool call is a few hundred bytes; this leaves
    /// room for a long `run_steps` list and nothing more.
    static let maxBodyBytes = 4 * 1024 * 1024

    /// Methods that carry a body, so must state its length.
    static let methodsWithBody: Set<String> = ["POST", "PUT", "PATCH"]

    /// Headers the endpoint decides on. Sent twice, the request is refused
    /// instead of one of the two values being picked.
    static let singleValuedHeaders: Set<String> = [
        "content-length", "content-type", "authorization", "origin", "host",
        "mcp-protocol-version", "mcp-method", "mcp-name",
    ]

    /// The characters a header name may hold (RFC 9110 `token`).
    private static let headerNameCharacters = CharacterSet(charactersIn:
        "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// The blank line that ends the headers.
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    enum HeadOutcome: Equatable {
        /// The headers have not ended yet.
        case incomplete
        case parsed(HTTPRequestHead)
        /// The request is refused; send this and close.
        case rejected(HTTPResponse)
    }

    enum Outcome: Equatable {
        /// More bytes are needed.
        case incomplete
        case complete(HTTPRequest)
        /// The request is refused; send this and close.
        case rejected(HTTPResponse)
    }

    /// Parse one request with a `Content-Length` body. A chunked upload, or a
    /// body with no stated length, is refused with 411.
    static func parse(_ buffer: Data) -> Outcome {
        switch head(of: buffer) {
        case .incomplete: return .incomplete
        case .rejected(let response): return .rejected(response)
        case .parsed(let head):
            guard let body = body(of: head, in: buffer) else { return .incomplete }
            return .complete(head.request(body: body))
        }
    }

    /// The body `head` announces, once `buffer` holds all of it.
    static func body(of head: HTTPRequestHead, in buffer: Data) -> Data? {
        let start = buffer.startIndex + head.bodyOffset
        guard buffer.endIndex - start >= head.contentLength else { return nil }
        return buffer.subdata(in: start..<(start + head.contentLength))
    }

    /// Parse the request line and headers, as soon as the blank line that ends
    /// them has arrived. The body's length is checked here, so an oversized
    /// body is refused before any of it is read.
    static func head(of buffer: Data) -> HeadOutcome {
        guard let terminator = buffer.range(of: headerTerminator) else {
            return buffer.count > maxHeaderBytes
                ? .rejected(.text(431, "Request headers exceed \(maxHeaderBytes) bytes."))
                : .incomplete
        }
        let headBytes = buffer.subdata(in: buffer.startIndex..<terminator.lowerBound)
        guard headBytes.count <= maxHeaderBytes else {
            return .rejected(.text(431, "Request headers exceed \(maxHeaderBytes) bytes."))
        }
        guard let head = String(data: headBytes, encoding: .utf8) else {
            return .rejected(.text(400, "Request headers are not UTF-8."))
        }
        var lines = head.components(separatedBy: "\r\n")
        // A lone CR or LF inside a line is how one header is hidden in another's value.
        guard !lines.contains(where: { $0.contains("\r") || $0.contains("\n") }) else {
            return .rejected(.text(400, "Malformed line ending in the request headers."))
        }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[1].hasPrefix("/"),
              requestLine[2].hasPrefix("HTTP/1.") else {
            return .rejected(.text(400, "Malformed request line."))
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].unicodeScalars.allSatisfy(headerNameCharacters.contains) else {
                return .rejected(.text(400, "Malformed header line."))
            }
            let name = line[..<colon].lowercased()
            if headers[name] != nil, singleValuedHeaders.contains(name) {
                return .rejected(.text(400, "The header \(name) was sent more than once."))
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let method = String(requestLine[0])
        let target = requestLine[1]
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let bodyOffset = terminator.upperBound - buffer.startIndex

        if headers["transfer-encoding"] != nil {
            return .rejected(.text(411, "Chunked uploads are not accepted; send Content-Length."))
        }
        guard let lengthText = headers["content-length"] else {
            if methodsWithBody.contains(method) {
                return .rejected(.text(411, "Content-Length is required."))
            }
            return .parsed(HTTPRequestHead(
                method: method, path: path, headers: headers, bodyOffset: bodyOffset, contentLength: 0))
        }
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let length = Int(lengthText) else {
            return .rejected(.text(400, "Content-Length is not a number."))
        }
        guard length <= maxBodyBytes else {
            return .rejected(.text(413, "Request body exceeds \(maxBodyBytes) bytes."))
        }
        return .parsed(HTTPRequestHead(
            method: method, path: path, headers: headers, bodyOffset: bodyOffset, contentLength: length))
    }
}
