// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Typed errors and response decoding for the WebDriverAgent HTTP API (W3C and legacy JSON shapes).
// ABOUTME: Pure parsing of session ids, viewport size, and /status, used by WebDriverAgentClient.

import CoreGraphics
import Foundation

/// A WebDriverAgent request that did not produce the expected answer.
enum WebDriverAgentError: Error, Equatable, CustomStringConvertible {
    /// No HTTP answer at all: connection refused, host unreachable, TLS, DNS.
    case unreachable(url: String, reason: String)
    /// No answer within the request's timeout.
    case timedOut(url: String, seconds: Double)
    /// WebDriverAgent answered with an error: the HTTP status, and the W3C
    /// `error` code and `message` when the body carried them.
    case http(endpoint: String, status: Int, error: String?, message: String?)
    /// An answer that is not the JSON this endpoint returns.
    case malformedResponse(endpoint: String, reason: String)
    /// The gesture could not be serialized to a request body.
    case encodingFailed(reason: String)

    /// The W3C error code of a request made with a session WebDriverAgent no
    /// longer knows (it restarted, or another client replaced the session).
    static let invalidSessionCode = "invalid session id"

    /// Whether the request failed only because its session is gone, so a new
    /// session can retry it.
    var isInvalidSession: Bool {
        if case .http(_, _, let error, _) = self { return error == Self.invalidSessionCode }
        return false
    }

    var description: String {
        switch self {
        case .unreachable(let url, let reason):
            return "WebDriverAgent at \(url) is unreachable (\(reason)). Check that "
                + "WebDriverAgentRunner is running on the iPhone, that the phone and this Mac "
                + "share a network, and that the URL uses the phone's current IP and port 8100."
        case .timedOut(let url, let seconds):
            return "WebDriverAgent at \(url) did not answer within \(Int(seconds))s."
        case .http(let endpoint, let status, let error, let message):
            let code = error.map { " \($0)" } ?? ""
            let detail = message.map { ": \($0)" } ?? ""
            return "WebDriverAgent \(endpoint) failed (HTTP \(status)\(code))\(detail)"
        case .malformedResponse(let endpoint, let reason):
            return "WebDriverAgent \(endpoint) returned an unexpected answer: \(reason)"
        case .encodingFailed(let reason):
            return "The gesture could not be encoded as W3C actions: \(reason)"
        }
    }
}

/// A decoded WebDriverAgent answer: the `value` payload and the top-level
/// `sessionId`, when present and not null.
struct WebDriverAgentReply {
    let value: Any?
    let sessionID: String?
}

/// Decodes WebDriverAgent answers. Current WebDriverAgent answers in the W3C
/// shape (`{"value": …, "sessionId": …}`, errors as `value.error` and
/// `value.message` with a non-2xx status); older builds answer in the legacy
/// JSON Wire shape (`{"status": n, "value": …, "sessionId": …}`, where a
/// non-zero `status` is an error and 6 means the session is gone).
enum WebDriverAgentResponse {
    /// Legacy JSON Wire status of a successful command.
    static let legacySuccessStatus = 0
    /// Legacy JSON Wire status of a command sent with an unknown session.
    static let legacyNoSuchSessionStatus = 6
    /// Longest slice of a non-JSON body quoted in an error.
    static let bodyExcerptLength = 200

    /// Decode `data`, answered with `httpStatus` by `endpoint`, throwing the
    /// error it carries.
    static func reply(from data: Data, httpStatus: Int,
                      endpoint: String) throws(WebDriverAgentError) -> WebDriverAgentReply {
        let succeeded = (200..<300).contains(httpStatus)
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            let excerpt = String(decoding: data.prefix(bodyExcerptLength), as: UTF8.self)
            if !succeeded {
                throw .http(endpoint: endpoint, status: httpStatus, error: nil,
                            message: excerpt.isEmpty ? nil : excerpt)
            }
            throw .malformedResponse(endpoint: endpoint, reason: "not a JSON object: \(excerpt)")
        }
        let value = object["value"]
        if let payload = value as? [String: Any], let code = payload["error"] as? String {
            throw .http(endpoint: endpoint, status: httpStatus, error: code,
                        message: payload["message"] as? String)
        }
        if let legacy = object["status"] as? Int, legacy != legacySuccessStatus {
            let code = legacy == legacyNoSuchSessionStatus
                ? WebDriverAgentError.invalidSessionCode : "status \(legacy)"
            throw .http(endpoint: endpoint, status: httpStatus, error: code,
                        message: value as? String)
        }
        guard succeeded else {
            throw .http(endpoint: endpoint, status: httpStatus, error: nil, message: nil)
        }
        return WebDriverAgentReply(value: value, sessionID: object["sessionId"] as? String)
    }

    /// The id of a session `POST /session` created: top-level `sessionId`
    /// (both shapes), or `value.sessionId` (W3C).
    static func sessionID(from reply: WebDriverAgentReply) throws(WebDriverAgentError) -> String {
        let nested = (reply.value as? [String: Any])?["sessionId"] as? String
        guard let id = reply.sessionID ?? nested, !id.isEmpty else {
            throw .malformedResponse(endpoint: "POST /session", reason: "no sessionId in the answer")
        }
        return id
    }

    /// The viewport `GET /window/size` reported, in points.
    static func windowSize(from reply: WebDriverAgentReply,
                           endpoint: String) throws(WebDriverAgentError) -> CGSize {
        guard let size = reply.value as? [String: Any],
              let width = (size["width"] as? NSNumber)?.doubleValue,
              let height = (size["height"] as? NSNumber)?.doubleValue else {
            throw .malformedResponse(endpoint: endpoint, reason: "no numeric width and height")
        }
        return CGSize(width: width, height: height)
    }

    /// Readiness and OS from `GET /status`.
    static func status(from reply: WebDriverAgentReply) throws(WebDriverAgentError) -> MultiTouchBackendStatus {
        guard let payload = reply.value as? [String: Any] else {
            throw .malformedResponse(endpoint: "GET /status", reason: "no status object")
        }
        let os = payload["os"] as? [String: Any]
        let osVersion = [os?["name"] as? String, os?["version"] as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        return MultiTouchBackendStatus(
            ready: payload["ready"] as? Bool ?? false,
            message: payload["message"] as? String,
            osVersion: osVersion.isEmpty ? nil : osVersion)
    }
}
