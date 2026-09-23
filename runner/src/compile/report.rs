// ABOUTME: Playwright JSON-reporter ingest — per-test verdicts, failure text, and mirroir-captures.
// ABOUTME: Owns the reporter deserialization shapes so invoke.rs only spawns npx and hands the body here.

use std::collections::BTreeMap;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Deserialize;

use crate::compile::report_error::{ReportEngine, ReportError};
use crate::error::Result;

/// Name of the attachment the emitted spec writes its captures to.
///
/// The compiled `.spec.ts` closes every test with
/// `test.info().attach('mirroir-captures', …)`; this is the Rust side of that
/// contract.
pub const CAPTURES_ATTACHMENT: &str = "mirroir-captures";

/// Per-scenario summary of Playwright test outcomes across all browser projects.
///
/// `passed + failed + skipped + flaky` equals the total result records the JSON
/// reporter wrote — one per (test × browser project × retry) tuple.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReporterVerdict {
    /// Number of result records with `status: "passed"`.
    pub passed: usize,
    /// Number of result records with `status: "failed"`.
    pub failed: usize,
    /// Number of result records with `status: "skipped"`.
    pub skipped: usize,
    /// Number of result records with `status: "flaky"` (passed on retry).
    pub flaky: usize,
}

impl ReporterVerdict {
    /// Total result records the reporter wrote.
    #[must_use]
    pub const fn total(&self) -> usize {
        self.passed + self.failed + self.skipped + self.flaky
    }
}

/// One failed Playwright test case, carrying the reporter's own error text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestFailure {
    /// Spec title the reporter recorded for the failing test.
    pub title: String,
    /// The reporter's error message — the locator text, timeout, or assertion
    /// diff Playwright produced, verbatim.
    pub message: String,
}

/// Values the emitted spec attached under [`CAPTURES_ATTACHMENT`].
///
/// `metrics` is keyed by the `measure:` step's `name` and holds milliseconds.
/// `judge` and `cross_surface` are keyed by the *step index* the capture was
/// emitted for, as the scenario file reads — a scenario may carry several of
/// each, and the index is the only collision-free key.
///
/// When a scenario runs across several browser projects each project attaches
/// its own captures; they merge in reporter order, so the last project's
/// values win for a key every project wrote.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct RunCaptures {
    /// `measure:` latencies in milliseconds, keyed by measure name.
    #[serde(default)]
    pub metrics: BTreeMap<String, f64>,
    /// `judge:` response text, keyed by step index.
    #[serde(default)]
    pub judge: BTreeMap<String, String>,
    /// `cross_surface:` capture text, keyed by step index.
    #[serde(default)]
    pub cross_surface: BTreeMap<String, String>,
    /// Uncaught exceptions the page raised during the run, newest last. The
    /// spec asserts this is empty, so a non-empty value here means the run
    /// already failed — it carries the detail.
    #[serde(default)]
    pub page_errors: Vec<String>,
    /// `<status> <method> <url>` for every failed response to a resource the
    /// page depends on.
    #[serde(default)]
    pub failed_requests: Vec<String>,
}

impl RunCaptures {
    /// Fold another block's captures in; a key both carry takes `other`'s.
    pub fn merge(&mut self, other: Self) {
        self.metrics.extend(other.metrics);
        self.judge.extend(other.judge);
        self.cross_surface.extend(other.cross_surface);
        self.page_errors.extend(other.page_errors);
        self.failed_requests.extend(other.failed_requests);
    }
}

/// Everything one Playwright invocation reported.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ReporterOutcome {
    /// Aggregate pass/fail/skip/flaky counts.
    pub verdict: ReporterVerdict,
    /// Values the spec attached for the Rust post-hooks to consume.
    pub captures: RunCaptures,
}

/// Parse a Playwright JSON reporter body into an outcome.
///
/// `path` names the report file in error messages only.
///
/// # Errors
///
/// * [`ReportError::Unparseable`] when the body isn't valid reporter JSON.
/// * [`ReportError::CaptureDecode`] when a `mirroir-captures` attachment
///   can't be base64-, UTF-8-, or JSON-decoded.
/// * [`ReportError::TestFailures`] when at least one result failed, with
///   each failure's title + reporter message attached.
/// * [`ReportError::Empty`] when the reporter recorded no results.
pub fn parse_report_body(engine: ReportEngine, path: &str, body: &str) -> Result<ReporterOutcome> {
    let parsed: ReporterRoot =
        serde_json::from_str(body).map_err(|source| ReportError::Unparseable {
            engine,
            path: path.to_owned(),
            source,
        })?;
    let mut ingest = Ingest {
        engine,
        outcome: ReporterOutcome::default(),
        failures: Vec::new(),
    };
    walk_suites(&parsed.suites, &mut ingest)?;

    let total = ingest.outcome.verdict.total();
    if ingest.outcome.verdict.failed > 0 {
        return Err(ReportError::TestFailures {
            engine,
            failed: ingest.outcome.verdict.failed,
            total,
            failures: ingest.failures,
        }
        .into());
    }
    if total == 0 {
        return Err(ReportError::Empty {
            engine,
            path: path.to_owned(),
        }
        .into());
    }
    Ok(ingest.outcome)
}

/// Accumulator threaded through [`walk_suites`].
#[derive(Debug)]
struct Ingest {
    engine: ReportEngine,
    outcome: ReporterOutcome,
    failures: Vec<TestFailure>,
}

fn walk_suites(suites: &[ReporterSuite], ingest: &mut Ingest) -> Result<()> {
    for suite in suites {
        for spec in &suite.specs {
            for test in &spec.tests {
                for result in &test.results {
                    ingest_result(&spec.title, result, ingest)?;
                }
            }
        }
        walk_suites(&suite.suites, ingest)?;
    }
    Ok(())
}

fn ingest_result(title: &str, result: &ReporterResult, ingest: &mut Ingest) -> Result<()> {
    // Every status Playwright can write is accounted for. `timedOut` and
    // `interrupted` are failures — a test that never finished asserted nothing
    // — and an unrecognized status is refused rather than dropped, because a
    // dropped result leaves the run looking like it had nothing to report.
    match result.status.as_str() {
        "passed" | "expected" => ingest.outcome.verdict.passed += 1,
        "failed" | "unexpected" | "timedOut" | "interrupted" => {
            ingest.outcome.verdict.failed += 1;
            ingest.failures.push(TestFailure {
                title: title.to_owned(),
                message: result.failure_message(),
            });
        }
        "skipped" => ingest.outcome.verdict.skipped += 1,
        "flaky" => ingest.outcome.verdict.flaky += 1,
        other => {
            return Err(ReportError::UnknownStatus {
                engine: ingest.engine,
                status: other.to_owned(),
                title: title.to_owned(),
            }
            .into());
        }
    }
    for attachment in &result.attachments {
        if attachment.name == CAPTURES_ATTACHMENT
            && let Some(encoded) = attachment.body.as_deref()
        {
            ingest.outcome.captures.merge(decode_captures(encoded)?);
        }
    }
    Ok(())
}

/// Decode one `mirroir-captures` attachment body. The JSON reporter
/// base64-encodes attachment bodies, so the transport is base64 → UTF-8 → JSON.
fn decode_captures(encoded: &str) -> Result<RunCaptures> {
    let raw = BASE64
        .decode(encoded)
        .map_err(|source| ReportError::CaptureDecode {
            reason: format!("attachment body is not base64: {source}"),
        })?;
    let text = String::from_utf8(raw).map_err(|source| ReportError::CaptureDecode {
        reason: format!("attachment body is not UTF-8: {source}"),
    })?;
    serde_json::from_str(&text)
        .map_err(|source| ReportError::CaptureDecode {
            reason: format!("attachment body is not a captures object: {source}"),
        })
        .map_err(Into::into)
}

#[derive(Deserialize)]
struct ReporterRoot {
    #[serde(default)]
    suites: Vec<ReporterSuite>,
}

#[derive(Deserialize)]
struct ReporterSuite {
    #[serde(default)]
    specs: Vec<ReporterSpec>,
    #[serde(default)]
    suites: Vec<Self>,
}

#[derive(Deserialize)]
struct ReporterSpec {
    #[serde(default)]
    title: String,
    #[serde(default)]
    tests: Vec<ReporterTest>,
}

#[derive(Deserialize)]
struct ReporterTest {
    #[serde(default)]
    results: Vec<ReporterResult>,
}

#[derive(Deserialize)]
struct ReporterResult {
    status: String,
    #[serde(default)]
    error: Option<ReporterMessage>,
    #[serde(default)]
    errors: Vec<ReporterMessage>,
    #[serde(default)]
    attachments: Vec<ReporterAttachment>,
}

impl ReporterResult {
    /// The reporter fills `error` with the primary failure and `errors` with
    /// every failure of the result; take the primary when present, otherwise
    /// join what `errors` carries.
    fn failure_message(&self) -> String {
        if let Some(message) = self.error.as_ref().and_then(|e| e.message.as_deref()) {
            return message.to_owned();
        }
        let joined: Vec<&str> = self
            .errors
            .iter()
            .filter_map(|e| e.message.as_deref())
            .collect();
        if joined.is_empty() {
            "playwright reported a failure with no message".to_owned()
        } else {
            joined.join("\n")
        }
    }
}

#[derive(Deserialize)]
struct ReporterMessage {
    #[serde(default)]
    message: Option<String>,
}

#[derive(Deserialize)]
struct ReporterAttachment {
    name: String,
    #[serde(default)]
    body: Option<String>,
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use super::{RunCaptures, parse_report_body};
    use crate::compile::report_error::{ReportEngine, ReportError};
    use crate::error::RunnerError;

    type TestResult = StdResult<(), String>;

    const STRICT_MODE_REPORT: &str = include_str!("fixtures/playwright-strict-mode.json");
    const CAPTURES_REPORT: &str = include_str!("fixtures/playwright-captures.json");

    #[test]
    fn strict_mode_violation_reaches_the_failure_message() -> TestResult {
        let res = parse_report_body(ReportEngine::Playwright, "report.json", STRICT_MODE_REPORT);
        let Err(RunnerError::Report(err @ ReportError::TestFailures { .. })) = res else {
            return Err(format!("expected TestFailures, got {res:?}"));
        };
        let ReportError::TestFailures {
            failed,
            total,
            ref failures,
            ..
        } = err
        else {
            return Err("matched variant changed".to_owned());
        };
        if failed != 1 || total != 1 {
            return Err(format!("wrong counts: failed={failed} total={total}"));
        }
        let Some(first) = failures.first() else {
            return Err("no failure detail captured".to_owned());
        };
        if first.title != "web-fixture — order button resolves uniquely" {
            return Err(format!("wrong title: {}", first.title));
        }
        if !first
            .message
            .contains("strict mode violation: resolved to 3 elements")
        {
            return Err(format!("locator text lost: {}", first.message));
        }
        if !err
            .to_string()
            .contains("strict mode violation: resolved to 3 elements")
        {
            return Err(format!("locator text lost in Display: {err}"));
        }
        Ok(())
    }

    #[test]
    fn captures_attachment_is_base64_decoded_into_the_outcome() -> TestResult {
        let outcome = parse_report_body(ReportEngine::Playwright, "report.json", CAPTURES_REPORT)
            .map_err(|e| format!("parse: {e}"))?;
        if outcome.verdict.passed != 1 {
            return Err(format!("wrong verdict: {:?}", outcome.verdict));
        }
        let captures = &outcome.captures;
        match captures.metrics.get("first_token_latency") {
            Some(ms) if (ms - 1234.5).abs() < f64::EPSILON => {}
            other => return Err(format!("metric lost: {other:?}")),
        }
        if captures.judge.get("6").map(String::as_str)
            != Some("The reply mentions WebSocket and SSE.")
        {
            return Err(format!("judge capture lost: {:?}", captures.judge));
        }
        if captures.cross_surface.get("2").map(String::as_str) != Some("the shared answer text") {
            return Err(format!(
                "cross_surface capture lost: {:?}",
                captures.cross_surface
            ));
        }
        Ok(())
    }

    /// A test Playwright timed out asserted nothing. Counting it as neither a
    /// pass nor a failure used to leave the report empty, which reported "no
    /// results" and threw away the locator that actually timed out.
    #[test]
    fn a_timed_out_test_is_a_failure_that_keeps_its_message() -> TestResult {
        let json = r#"{"suites":[{"title":"s","specs":[{"title":"order flow","tests":[{"results":[
            {"status":"timedOut","error":{"message":"locator.click: Test timeout of 30000ms exceeded.\nwaiting for locator('[data-test=place-order]')"}}
        ]}]}],"suites":[]}]}"#;
        match parse_report_body(ReportEngine::Playwright, "report.json", json) {
            Err(RunnerError::Report(ReportError::TestFailures {
                failed, failures, ..
            })) => {
                if failed != 1 {
                    return Err(format!("timed-out result not counted: failed={failed}"));
                }
                let Some(first) = failures.first() else {
                    return Err("no failure detail captured".to_owned());
                };
                if !first.message.contains("data-test=place-order") {
                    return Err(format!("locator lost: {}", first.message));
                }
                Ok(())
            }
            other => Err(format!("expected TestFailures, got {other:?}")),
        }
    }

    /// A status the ingest does not know must stop the run, not vanish from
    /// every count.
    #[test]
    fn an_unknown_status_is_refused() -> TestResult {
        let json = r#"{"suites":[{"title":"s","specs":[{"title":"t","tests":[{"results":[
            {"status":"quantum"}
        ]}]}],"suites":[]}]}"#;
        match parse_report_body(ReportEngine::Playwright, "report.json", json) {
            Err(RunnerError::Report(ReportError::UnknownStatus { status, title, .. }))
                if status == "quantum" && title == "t" =>
            {
                Ok(())
            }
            other => Err(format!("expected UnknownStatus, got {other:?}")),
        }
    }

    #[test]
    fn empty_report_is_not_a_pass() -> TestResult {
        let res = parse_report_body(ReportEngine::Playwright, "report.json", r#"{"suites":[]}"#);
        match res {
            Err(RunnerError::Report(ReportError::Empty { path, .. })) if path == "report.json" => {
                Ok(())
            }
            other => Err(format!("expected ReportEmpty, got {other:?}")),
        }
    }

    #[test]
    fn nested_suites_are_counted_and_captures_merge_last_write_wins() -> TestResult {
        let json = r#"{
            "suites": [
              {
                "title": "outer",
                "specs": [{"title": "a", "tests": [{"results": [{"status": "passed"}]}]}],
                "suites": [
                  {"title": "inner", "specs": [{"title": "b", "tests": [{"results": [{"status": "flaky"}, {"status": "skipped"}]}]}], "suites": []}
                ]
              }
            ]
        }"#;
        let outcome = parse_report_body(ReportEngine::Playwright, "report.json", json)
            .map_err(|e| format!("parse: {e}"))?;
        if outcome.verdict.passed != 1 || outcome.verdict.flaky != 1 || outcome.verdict.skipped != 1
        {
            return Err(format!("wrong counts: {:?}", outcome.verdict));
        }
        if outcome.captures != RunCaptures::default() {
            return Err("captures should be empty".to_owned());
        }
        Ok(())
    }

    #[test]
    fn undecodable_capture_body_is_an_error() -> TestResult {
        let json = r#"{"suites":[{"title":"s","specs":[{"title":"t","tests":[{"results":[
            {"status":"passed","attachments":[{"name":"mirroir-captures","body":"!!!not-base64!!!"}]}
        ]}]}],"suites":[]}]}"#;
        match parse_report_body(ReportEngine::Playwright, "report.json", json) {
            Err(RunnerError::Report(ReportError::CaptureDecode { reason })) => {
                if reason.contains("base64") {
                    Ok(())
                } else {
                    Err(format!("wrong reason: {reason}"))
                }
            }
            other => Err(format!("expected CaptureDecode, got {other:?}")),
        }
    }
}
