// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for ChatCompletionUsage — parsing the `usage` block of chat-completion responses.
// ABOUTME: Covers the embacle FFI response shape with and without usage, plus malformed bodies.

import XCTest
@testable import mirroir_mcp

final class ChatCompletionUsageTests: XCTestCase {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testParsesUsageFromEmbacleFFIShape() {
        // The shape embacle's FFI emits when the runner reports usage.
        let data = body("""
        {"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":1662,"completion_tokens":48,"total_tokens":1710}}
        """)
        XCTAssertEqual(
            ChatCompletionUsage.parse(from: data),
            ChatCompletionUsage(promptTokens: 1662, completionTokens: 48, totalTokens: 1710))
    }

    func testNilWhenProviderReportsNoUsage() {
        // copilot_headless never reports usage; the FFI omits the field.
        let data = body("""
        {"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
        """)
        XCTAssertNil(ChatCompletionUsage.parse(from: data))
    }

    func testTotalFallsBackToSumWhenOmitted() {
        let data = body(#"{"usage":{"prompt_tokens":100,"completion_tokens":20}}"#)
        XCTAssertEqual(ChatCompletionUsage.parse(from: data)?.totalTokens, 120)
    }

    func testNilWhenCountsMissing() {
        let data = body(#"{"usage":{"total_tokens":50}}"#)
        XCTAssertNil(ChatCompletionUsage.parse(from: data))
    }

    func testNilForNonJSONBody() {
        XCTAssertNil(ChatCompletionUsage.parse(from: body("not json")))
    }
}
