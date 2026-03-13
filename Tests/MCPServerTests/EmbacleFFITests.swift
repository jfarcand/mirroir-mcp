// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for EmbacleFFI embedded agent transport.
// ABOUTME: Tests adapt to whether CEmbacle is linked via #if canImport.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class EmbacleFFITests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // Shutdown after each test to leave the runtime in a clean state
        EmbacleFFI.shutdown()
    }

    // MARK: - Runtime Lifecycle

    #if canImport(CEmbacle)

    func testInitializeSucceeds() {
        let result = EmbacleFFI.initialize()
        XCTAssertTrue(result, "EmbacleFFI.initialize() should succeed when CEmbacle is linked")
    }

    func testChatCompletionRequiresInit() {
        // Calling chatCompletion without initialize should return nil
        let body = try! JSONSerialization.data(withJSONObject: [
            "model": "copilot",
            "messages": [["role": "user", "content": "hello"]],
        ] as [String: Any])

        let result = EmbacleFFI.chatCompletion(requestJSON: body, timeoutSeconds: 5)
        XCTAssertNil(result, "chatCompletion should return nil when runtime is not initialized")
    }

    func testShutdownDoesNotCrash() {
        _ = EmbacleFFI.initialize()
        EmbacleFFI.shutdown()
    }

    #else

    func testInitializeReturnsFalseWhenNotLinked() {
        let result = EmbacleFFI.initialize()
        XCTAssertFalse(result, "EmbacleFFI.initialize() should return false when CEmbacle is not linked")
    }

    func testChatCompletionReturnsNilWhenNotLinked() {
        let body = try! JSONSerialization.data(withJSONObject: [
            "model": "copilot",
            "messages": [["role": "user", "content": "hello"]],
        ] as [String: Any])

        let result = EmbacleFFI.chatCompletion(requestJSON: body, timeoutSeconds: 5)
        XCTAssertNil(result, "chatCompletion should return nil when CEmbacle is not linked")
    }

    func testShutdownDoesNotCrashWhenNotLinked() {
        EmbacleFFI.shutdown()
    }

    #endif

    // MARK: - Transport Config

    func testAgentTransportDefaultsToAuto() {
        XCTAssertEqual(EnvConfig.agentTransport, "auto")
    }
}
