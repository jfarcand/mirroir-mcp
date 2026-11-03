// ABOUTME: Structured errors for HTTP: building the shared TLS config and reqwest client, and an `http:` step.
// ABOUTME: Converts into RunnerError via #[from]; every variant carries the fields its message needs.

use thiserror::Error;

/// Errors raised building an HTTP client or running an `http:` step.
#[derive(Debug, Error)]
pub enum HttpError {
    /// Building the underlying `reqwest::Client` failed (TLS, DNS resolver init, …).
    #[error("HTTP client initialization failed")]
    Client {
        /// Underlying `reqwest` error.
        #[source]
        source: reqwest::Error,
    },

    /// Building the rustls client config every HTTP client shares failed.
    #[error("TLS configuration failed")]
    Tls {
        /// Underlying `rustls` error.
        #[source]
        source: rustls::Error,
    },

    /// An `http:` step could not complete the request (DNS, refused connect, timeout, …).
    #[error("HTTP request to `{url}` failed")]
    Request {
        /// Target URL.
        url: String,
        /// Underlying `reqwest` error.
        #[source]
        source: reqwest::Error,
    },

    /// An `http:` step's response had a different status code than `expect_status:`.
    #[error("HTTP `{url}` returned status {actual}, expected {expected}")]
    StatusMismatch {
        /// Target URL.
        url: String,
        /// Status code declared in the YAML.
        expected: u16,
        /// Status code the server actually returned.
        actual: u16,
    },

    /// Reading an `http:` step's response body failed (connection drop, decode error, …).
    #[error("HTTP `{url}` body read failed")]
    BodyRead {
        /// Target URL.
        url: String,
        /// Underlying `reqwest` error.
        #[source]
        source: reqwest::Error,
    },

    /// An `http:` step's response body did not contain a required substring.
    #[error("HTTP `{url}` body missing required substring `{expected}`")]
    BodyMismatch {
        /// Target URL.
        url: String,
        /// The substring from `expect_body_contains:` that was missing.
        expected: String,
    },
}
