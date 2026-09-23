// ABOUTME: Structured error type for the Playwright compile + invoke pipeline — emit, workspace, spawn.
// ABOUTME: Converts into RunnerError via #[from]; every variant carries the fields its message needs.

use std::io;

use thiserror::Error;

/// Errors raised while compiling a scenario to a Playwright spec or invoking
/// `npx playwright test`. Ingesting the report it writes is
/// [`crate::compile::report_error::ReportError`]'s.
///
/// The compile pipeline owns this enum so [`crate::error::RunnerError`] stays
/// the runner-wide surface. Every variant converts into
/// [`crate::error::RunnerError::Playwright`] through `#[from]`, so `?`
/// propagates them unchanged.
#[derive(Debug, Error)]
pub enum PlaywrightError {
    /// Scenario can't be compiled into a Playwright `.spec.ts` file.
    #[error("cannot compile scenario for Playwright: {reason}")]
    Unsupported {
        /// Why this scenario isn't web-compilable (missing target, wrong kind, …).
        reason: String,
    },

    /// Internal: failed to encode a TypeScript string literal during compilation.
    #[error("playwright compile: {context}")]
    Encode {
        /// What was being encoded (label, scenario name, URL, …).
        context: String,
        /// Underlying `serde_json` encode error.
        #[source]
        source: serde_json::Error,
    },

    /// Failed to set up the temporary workspace for a Playwright invocation.
    #[error("playwright workspace setup failed: {context}")]
    Workspace {
        /// What was being done (mkdir, write spec, write config, …).
        context: String,
        /// Underlying I/O error.
        #[source]
        source: io::Error,
    },

    /// `npx playwright test` exited non-zero without a parseable report.
    #[error(
        "playwright invocation failed (status: {status:?})\nstdout tail:\n{stdout_tail}\nstderr tail:\n{stderr_tail}"
    )]
    Invoke {
        /// Exit status of `npx`, `None` if killed by signal.
        status: Option<i32>,
        /// Stdout captured from the subprocess (truncated to ~4 KiB) — where
        /// Playwright prints its own failure summary.
        stdout_tail: String,
        /// Stderr captured from the subprocess (truncated to ~4 KiB).
        stderr_tail: String,
    },

    /// `npx` could not be found on `PATH` — Playwright cannot be invoked.
    #[error("`npx` is not on PATH; install Node + run `npm i -D @playwright/test`")]
    NotInstalled,
}
