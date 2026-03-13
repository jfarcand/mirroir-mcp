// ABOUTME: C header declaring the embacle Rust FFI surface for Swift interop.
// ABOUTME: These functions are implemented in libembacle_ffi.a (built from the embacle repo).

#ifndef EMBACLE_H
#define EMBACLE_H

#include <stddef.h>
#include <stdint.h>

/// Initialize the embacle runtime (copilot auth, token cache).
/// Returns 0 on success, non-zero on error.
int embacle_init(void);

/// Send a chat completion request.
/// `request_json` is the full OpenAI-compatible JSON request body (same format
/// as POST /v1/chat/completions). `timeout_seconds` is the max wait time.
/// Returns a malloc'd JSON string with the response, or NULL on error.
/// Caller MUST free the result with embacle_free_string().
char* embacle_chat_completion(const char* request_json, int timeout_seconds);

/// Free a string returned by embacle functions.
void embacle_free_string(char* ptr);

/// Shutdown the embacle runtime and release resources.
void embacle_shutdown(void);

#endif
