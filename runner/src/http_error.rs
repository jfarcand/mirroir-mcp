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
// ABOUTME: Structured errors for HTTP: building the shared TLS config and reqwest client, and an `http:` step.
// ABOUTME: Converts into RunnerError via #[from]; every variant carries the fields its message needs.

use std::io;
use std::path::PathBuf;

use thiserror::Error;

use crate::parser::step::HttpMethod;

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

    /// A `file://` URL in an `http:` step does not name a local path.
    #[error("`{url}` does not name a local file (a file:// URL needs an empty or localhost host)")]
    FileUrl {
        /// The URL from the step.
        url: String,
    },

    /// The file a `file://` URL names could not be read (missing, unreadable, not UTF-8).
    #[error("file `{}` could not be read", path.display())]
    FileRead {
        /// The local path the URL names.
        path: PathBuf,
        /// Underlying I/O error.
        #[source]
        source: io::Error,
    },

    /// A `file://` step declared `expect_status`; a file has no status code.
    #[error("`{url}` is a file: drop `expect_status: {expected}`, a file has no status code")]
    FileStatus {
        /// The URL from the step.
        url: String,
        /// The status the step declared.
        expected: u16,
    },

    /// A `file://` step used a verb other than GET.
    #[error("`{url}` is a file: only GET reads it, not {method:?}")]
    FileMethod {
        /// The URL from the step.
        url: String,
        /// The verb the step declared.
        method: HttpMethod,
    },
}
