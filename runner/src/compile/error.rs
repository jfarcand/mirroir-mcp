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

    /// A scenario runs in more than one browser and declares a step whose
    /// captured value the runner evaluates once. Each browser would capture
    /// its own value and all but one would be dropped, so it is refused.
    #[error(
        "scenario `{scenario}` runs in {browsers} but step {index} (`{step}`) captures one value per run; run it in one browser, or split it into one scenario per browser"
    )]
    MultiBrowserCapture {
        /// Scenario name.
        scenario: String,
        /// The browsers the scenario declares, comma-separated.
        browsers: String,
        /// Index of the capturing step in the scenario.
        index: usize,
        /// Kind of the capturing step (`judge`, `cross_surface`, `measure`).
        step: &'static str,
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
