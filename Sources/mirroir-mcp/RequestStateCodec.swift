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
// ABOUTME: Signs and verifies the opaque requestState carried across an MRTR round trip.
// ABOUTME: HMAC-SHA256 over the payload, bound to the issuing method and a short expiry.

import CryptoKit
import Foundation
import HelperLib

/// Encodes the state a tool needs to resume after asking the client for input,
/// and rejects anything that comes back altered.
///
/// The state travels through the client, which the specification requires be
/// treated as an attacker-controlled channel: a client may modify it, replay it
/// onto a different request, or present it long after it was issued. Each is
/// covered here — the payload is authenticated with HMAC-SHA256, bound to the
/// method that issued it, and expires.
///
/// The signing key is generated per process, so state does not survive a server
/// restart. For a stdio server, whose client shares its lifetime, that costs
/// nothing: a state that outlives the process belongs to a conversation that is
/// already over, and failing it is the correct outcome.
enum RequestStateCodec {
    /// How long an issued state stays valid. Long enough for a user to answer an
    /// elicitation prompt, short enough to bound replay.
    static let lifetimeSeconds: TimeInterval = 300

    /// Per-process signing key. Never leaves this process and is never logged.
    private static let key = SymmetricKey(size: .bits256)

    /// Separator between payload and signature in the encoded form.
    private static let separator = "."

    /// Sign `payload` for a retry of `method`.
    ///
    /// - Returns: The opaque string to hand the client, or nil if the payload
    ///   cannot be serialised.
    static func encode(
        _ payload: [String: JSONValue], method: String, now: Date = Date()
    ) -> String? {
        let envelope: JSONValue = .object([
            "method": .string(method),
            "expiresAt": .number(now.addingTimeInterval(lifetimeSeconds).timeIntervalSince1970),
            "payload": .object(payload),
        ])
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return data.base64EncodedString() + separator + Data(signature).base64EncodedString()
    }

    /// Verify `state` and return the payload it carries.
    ///
    /// - Returns: The payload when the signature verifies, the method matches,
    ///   and the state has not expired; nil otherwise. A nil result means the
    ///   state is unusable — the caller should ask for the input again rather
    ///   than trust anything inside it.
    static func decode(
        _ state: String, method: String, now: Date = Date()
    ) -> [String: JSONValue]? {
        let parts = state.components(separatedBy: separator)
        guard parts.count == 2,
              let data = Data(base64Encoded: parts[0]),
              let signature = Data(base64Encoded: parts[1]) else { return nil }

        // Constant-time comparison, and the payload is not parsed until it verifies.
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: data, using: key)
        else { return nil }

        guard let envelope = try? JSONDecoder().decode(JSONValue.self, from: data),
              envelope.member("method")?.asString() == method,
              let expiresAt = envelope.member("expiresAt")?.asNumber(),
              now.timeIntervalSince1970 < expiresAt,
              case .object(let payload)? = envelope.member("payload") else { return nil }

        return payload
    }
}
