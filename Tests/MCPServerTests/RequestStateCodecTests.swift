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
// ABOUTME: Tests for the MRTR requestState codec — signing, binding, and expiry.
// ABOUTME: The state crosses an untrusted client, so every rejection path is covered.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class RequestStateCodecTests: XCTestCase {

    private let method = "tools/call"
    private let payload: [String: JSONValue] = [
        "screen": .string("home"),
        "elementCount": .number(12),
    ]

    func testRoundTripPreservesPayload() {
        guard let state = RequestStateCodec.encode(payload, method: method) else {
            return XCTFail("encoding failed")
        }
        guard let decoded = RequestStateCodec.decode(state, method: method) else {
            return XCTFail("decoding failed")
        }
        XCTAssertEqual(decoded["screen"], .string("home"))
        XCTAssertEqual(decoded["elementCount"], .number(12))
    }

    /// The client is an untrusted channel: an edited payload must not decode,
    /// even though the client can read and rewrite the base64 freely.
    func testTamperedPayloadIsRejected() {
        guard let state = RequestStateCodec.encode(payload, method: method) else {
            return XCTFail("encoding failed")
        }
        let parts = state.components(separatedBy: ".")
        guard parts.count == 2, let data = Data(base64Encoded: parts[0]),
              var json = String(data: data, encoding: .utf8) else {
            return XCTFail("unexpected encoding shape")
        }
        json = json.replacingOccurrences(of: "\"home\"", with: "\"admin\"")
        let forged = Data(json.utf8).base64EncodedString() + "." + parts[1]

        XCTAssertNil(RequestStateCodec.decode(forged, method: method),
            "a payload edited in flight must not verify")
    }

    func testTamperedSignatureIsRejected() {
        guard let state = RequestStateCodec.encode(payload, method: method) else {
            return XCTFail("encoding failed")
        }
        let parts = state.components(separatedBy: ".")
        let forged = parts[0] + "." + Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertNil(RequestStateCodec.decode(forged, method: method))
    }

    /// State issued for one method must not be replayed onto another.
    func testStateBoundToIssuingMethod() {
        guard let state = RequestStateCodec.encode(payload, method: "tools/call") else {
            return XCTFail("encoding failed")
        }
        XCTAssertNil(RequestStateCodec.decode(state, method: "prompts/get"),
            "state must not carry across methods")
        XCTAssertNotNil(RequestStateCodec.decode(state, method: "tools/call"))
    }

    func testExpiredStateIsRejected() {
        let issued = Date()
        guard let state = RequestStateCodec.encode(payload, method: method, now: issued) else {
            return XCTFail("encoding failed")
        }
        let afterExpiry = issued.addingTimeInterval(RequestStateCodec.lifetimeSeconds + 1)
        XCTAssertNil(RequestStateCodec.decode(state, method: method, now: afterExpiry),
            "state must lapse")
        let beforeExpiry = issued.addingTimeInterval(RequestStateCodec.lifetimeSeconds - 1)
        XCTAssertNotNil(RequestStateCodec.decode(state, method: method, now: beforeExpiry))
    }

    func testMalformedStateIsRejected() {
        for malformed in ["", ".", "not-base64.not-base64", "onlyonepart"] {
            XCTAssertNil(RequestStateCodec.decode(malformed, method: method),
                "\(malformed.isEmpty ? "<empty>" : malformed) must not decode")
        }
    }
}
