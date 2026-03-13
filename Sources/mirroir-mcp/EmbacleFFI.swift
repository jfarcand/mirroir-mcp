// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Swift wrapper around the embacle Rust FFI for embedded agent transport.
// ABOUTME: When CEmbacle is linked, calls Rust directly; otherwise provides a no-op stub.

import Foundation

#if canImport(CEmbacle)
import CEmbacle

/// Thin Swift wrapper around the embacle C FFI (pure transformation pattern).
/// Converts between Swift types and C strings, manages memory via embacle_free_string().
enum EmbacleFFI {

    /// Whether the embedded embacle Rust FFI is linked into this binary.
    static let isAvailable = true

    /// Initialize the embedded embacle runtime. Call once at startup.
    /// Returns true on success, false on error.
    static func initialize() -> Bool {
        let result = embacle_init()
        return result == 0
    }

    /// Send an OpenAI-compatible chat completion request via the embedded runtime.
    /// Accepts the same JSON body as HTTP POST /v1/chat/completions.
    /// Returns the response Data, or nil on error.
    static func chatCompletion(requestJSON: Data, timeoutSeconds: Int) -> Data? {
        guard let jsonString = String(data: requestJSON, encoding: .utf8) else {
            fputs("Warning: EmbacleFFI: request body is not valid UTF-8\n", stderr)
            return nil
        }

        guard let resultPtr = jsonString.withCString({ cStr in
            embacle_chat_completion(cStr, Int32(timeoutSeconds))
        }) else {
            fputs("Warning: EmbacleFFI: chat completion returned NULL\n", stderr)
            return nil
        }

        let responseString = String(cString: resultPtr)
        embacle_free_string(resultPtr)

        guard let responseData = responseString.data(using: .utf8) else {
            fputs("Warning: EmbacleFFI: response is not valid UTF-8\n", stderr)
            return nil
        }

        return responseData
    }

    /// Shutdown the embedded runtime. Call at process exit.
    static func shutdown() {
        embacle_shutdown()
    }
}

#else

/// Stub when the embacle Rust FFI library is not linked.
/// All operations return failure so the server falls back gracefully.
enum EmbacleFFI {

    /// Whether the embedded embacle Rust FFI is linked into this binary.
    static let isAvailable = false

    static func initialize() -> Bool {
        fputs("Warning: Embedded embacle not available (CEmbacle not linked)\n", stderr)
        return false
    }

    static func chatCompletion(requestJSON: Data, timeoutSeconds: Int) -> Data? {
        fputs("Warning: Embedded embacle not available (CEmbacle not linked)\n", stderr)
        return nil
    }

    static func shutdown() {}
}

#endif
