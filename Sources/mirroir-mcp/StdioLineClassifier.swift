/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Sorts one line the stdio client sent: a request, a cancel, another notification, or an answer to our request.
// ABOUTME: A line that is not JSON, or not a JSON-RPC message, gets the error code it earns.

import Foundation
import HelperLib

/// What one line from the stdio client is.
enum StdioLine {
    /// A request (with an id) or a notification other than a cancel.
    case message(JSONRPCRequest)
    /// `notifications/cancelled` naming the request to stop.
    case cancel(RequestID, reason: String?)
    /// The client's answer to a request this server sent.
    case clientResponse(RequestID, [String: Any])
    /// A line to answer with a JSON-RPC error and no id.
    case malformed(code: Int, message: String)
    /// Nothing to act on: an empty line, or a cancel that names no request.
    case ignored
}

/// Sorts lines from the stdio client. Every line passes here first, so a reply
/// to a sampling request is told from a request before either is decoded.
enum StdioLineClassifier {
    static let parseErrorCode = -32700
    static let invalidRequestCode = -32600
    static let cancelledMethod = "notifications/cancelled"

    static func classify(_ line: Data, decoder: JSONDecoder = JSONDecoder()) -> StdioLine {
        guard !line.isEmpty else { return .ignored }
        guard let parsed = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) else {
            return .malformed(code: parseErrorCode, message: "Parse error: the line is not JSON")
        }
        if let object = parsed as? [String: Any], object["method"] == nil,
           object["result"] != nil || object["error"] != nil {
            guard let id = requestID(object["id"]) else { return .ignored }
            return .clientResponse(id, object)
        }
        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: line)
        } catch {
            return .malformed(code: invalidRequestCode, message: "Invalid request: \(error.localizedDescription)")
        }
        guard request.method == cancelledMethod, request.id == nil else { return .message(request) }
        guard let target = request.params?.member("requestId"), let id = requestID(target) else {
            return .ignored
        }
        return .cancel(id, reason: request.params?.member("reason")?.asString())
    }

    /// A request id from a parsed JSON value: an integer or a string.
    private static func requestID(_ value: Any?) -> RequestID? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let double = number.doubleValue
            return double.rounded() == double ? .number(Int(double)) : nil
        case let string as String:
            return .string(string)
        default:
            return nil
        }
    }

    /// A request id from a `JSONValue`, as `notifications/cancelled` carries it.
    private static func requestID(_ value: JSONValue) -> RequestID? {
        switch value {
        case .number(let double) where double.rounded() == double:
            return .number(Int(double))
        case .string(let string):
            return .string(string)
        default:
            return nil
        }
    }
}
