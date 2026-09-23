// ABOUTME: Structured errors for ingesting a Playwright JSON-reporter document, whichever engine wrote it.
// ABOUTME: Playwright writes one for a web block and mirroir-mcp writes one for an iOS block; both land here.

use std::fmt;

use thiserror::Error;

use crate::compile::report::TestFailure;

/// Which engine wrote the reporter document being ingested.
///
/// The web block's report comes from `npx playwright test`; the iOS block's
/// from `mirroir-mcp test --report-json`. Both use the Playwright JSON-reporter
/// shape, so one ingest reads them — the engine only names who to blame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportEngine {
    /// `npx playwright test`, for a `target: { kind: web }` block.
    Playwright,
    /// `mirroir-mcp test`, for a `target: { kind: ios }` block.
    MirroirMcp,
}

impl fmt::Display for ReportEngine {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Playwright => "playwright",
            Self::MirroirMcp => "mirroir-mcp",
        })
    }
}

/// Errors raised while ingesting a reporter document.
///
/// Every variant converts into [`crate::error::RunnerError::Report`] through
/// `#[from]`, so `?` propagates them unchanged.
#[derive(Debug, Error)]
pub enum ReportError {
    /// The reporter document is missing or unparseable.
    #[error("could not parse the {engine} report at `{path}`")]
    Unparseable {
        /// Engine that wrote the document.
        engine: ReportEngine,
        /// Path to the reporter document we tried to read.
        path: String,
        /// Underlying parse error.
        #[source]
        source: serde_json::Error,
    },

    /// The reporter recorded a status the ingest does not know. Walking past
    /// it would drop the result from every count, which turns an unrecognized
    /// outcome into a silent pass.
    #[error("{engine} reported the unknown status `{status}` for `{title}`")]
    UnknownStatus {
        /// Engine that wrote the document.
        engine: ReportEngine,
        /// The status string the reporter wrote.
        status: String,
        /// Title of the spec that carried it.
        title: String,
    },

    /// The reporter parsed but recorded no test results at all — the spec was
    /// filtered out, the config selected no project, or the engine aborted
    /// before running anything. Nothing was asserted, so this is not a pass.
    #[error("{engine} wrote no test results to `{path}`; nothing was asserted")]
    Empty {
        /// Engine that wrote the document.
        engine: ReportEngine,
        /// Path to the reporter document.
        path: String,
    },

    /// The engine completed and reported per-test failures. Each failure
    /// carries the reporter's own title + error text, so the locator or step
    /// that actually failed reaches the run summary instead of a bare count.
    #[error("{engine}: {failed} of {total} test cases failed{}", render_failures(.failures))]
    TestFailures {
        /// Engine that wrote the document.
        engine: ReportEngine,
        /// Number of test cases the reporter marked failed.
        failed: usize,
        /// Total test cases recorded by the reporter.
        total: usize,
        /// Title + message of each failed test case, in reporter order.
        failures: Vec<TestFailure>,
    },

    /// A `mirroir-captures` attachment was present but its body could not be
    /// decoded. The reporter base64-encodes attachment bodies.
    #[error("could not decode the `mirroir-captures` attachment: {reason}")]
    CaptureDecode {
        /// What failed — base64 decoding, UTF-8 decoding, or JSON parsing.
        reason: String,
    },
}

/// Render the per-test failure detail appended to the `TestFailures` message.
fn render_failures(failures: &[TestFailure]) -> String {
    let mut out = String::new();
    for failure in failures {
        out.push_str("\n  - ");
        out.push_str(&failure.title);
        out.push_str(": ");
        out.push_str(&failure.message);
    }
    out
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use super::{ReportEngine, ReportError, render_failures};
    use crate::compile::report::TestFailure;

    type TestResult = StdResult<(), String>;

    #[test]
    fn test_failures_message_carries_every_locator_text() -> TestResult {
        let err = ReportError::TestFailures {
            engine: ReportEngine::Playwright,
            failed: 2,
            total: 3,
            failures: vec![
                TestFailure {
                    title: "checkout".to_owned(),
                    message: "strict mode violation: resolved to 3 elements".to_owned(),
                },
                TestFailure {
                    title: "login".to_owned(),
                    message: "Timeout 5000ms exceeded".to_owned(),
                },
            ],
        };
        let rendered = err.to_string();
        for needle in [
            "playwright: 2 of 3 test cases failed",
            "checkout: strict mode violation: resolved to 3 elements",
            "login: Timeout 5000ms exceeded",
        ] {
            if !rendered.contains(needle) {
                return Err(format!("`{needle}` missing from:\n{rendered}"));
            }
        }
        Ok(())
    }

    /// An iOS block's failure names mirroir-mcp, not Playwright.
    #[test]
    fn an_ios_failure_names_mirroir_mcp() -> TestResult {
        let err = ReportError::TestFailures {
            engine: ReportEngine::MirroirMcp,
            failed: 1,
            total: 1,
            failures: vec![TestFailure {
                title: "check-alarms".to_owned(),
                message: "step 2 (tap: \"Alarmes\"): not found".to_owned(),
            }],
        };
        let rendered = err.to_string();
        if !rendered.starts_with("mirroir-mcp: 1 of 1 test cases failed") {
            return Err(format!("wrong engine in: {rendered}"));
        }
        Ok(())
    }

    #[test]
    fn render_failures_is_empty_for_no_failures() {
        assert_eq!(render_failures(&[]), String::new());
    }
}
