// ABOUTME: Structured error type for the mirroir-run binary — no anyhow!(), no untyped errors.
// ABOUTME: Every fallible operation returns Result<T, RunnerError> built from thiserror variants.

use std::fmt;
use std::io;
use std::ops::RangeInclusive;
use std::path::PathBuf;
use std::result::Result as StdResult;

use thiserror::Error;

use crate::compile::error::PlaywrightError;
use crate::mirroir::error::MirroirError;
use crate::oracle::error::OracleError;
use crate::parser::step::TargetKind;

/// `Result` alias used throughout the `mirroir-run` binary.
///
/// All fallible operations propagate [`RunnerError`] via `?`. No `anyhow!()`
/// macros, no `anyhow::Result`, no ad-hoc string errors.
pub type Result<T> = StdResult<T, RunnerError>;

/// All errors the runner produces.
///
/// Each variant carries enough context for both human-readable display via
/// [`std::fmt::Display`] and downstream programmatic handling (e.g. CLI exit
/// codes, structured logging fields). Every variant is constructed somewhere in
/// the crate — there is no blanket `dead_code` allow masking unused variants.
#[derive(Debug, Error)]
pub enum RunnerError {
    /// A regex pattern failed to compile.
    #[error("regex compilation failed for `{pattern}`")]
    RegexCompile {
        /// Short identifier for the pattern that failed (e.g. `"env-substitution"`).
        pattern: String,
        /// Underlying error from the `regex` crate.
        #[source]
        source: regex::Error,
    },

    /// YAML deserialization failed.
    #[error("YAML parse failed for {file}")]
    YamlParse {
        /// Path or label of the YAML document that failed.
        file: String,
        /// Underlying error from `serde_yaml`.
        #[source]
        source: serde_yaml::Error,
    },

    /// Filesystem or other I/O operation failed.
    #[error("I/O error: {context}")]
    Io {
        /// What the runner was attempting when the I/O failed.
        context: String,
        /// Underlying [`std::io::Error`].
        #[source]
        source: io::Error,
    },

    /// An artifact (`SAMPLE.md` / scenario YAML / `APP.md` / `profiles.yaml`) declares
    /// a `version` field outside the range the running binary supports.
    #[error("unsupported {artifact} version {found} (supported range: {expected:?})")]
    UnsupportedVersion {
        /// Artifact kind (e.g. `"SAMPLE.md"`, `"scenario.yaml"`).
        artifact: String,
        /// Version found in the artifact header.
        found: u32,
        /// Inclusive range of major versions the binary supports.
        expected: RangeInclusive<u32>,
    },

    /// `mirroir-run accept` was invoked in a CI environment.
    ///
    /// Accept re-records every baseline from what the run observed — it is a
    /// person saying the new output is correct. A CI job that could do that
    /// would bless its own regressions, so the refusal is structural rather
    /// than a documented convention.
    #[error(
        "`mirroir-run accept` refuses to run in CI ({variable} is set): accepting a baseline is a human review, and a job that accepts its own drift reports green forever"
    )]
    AcceptRefusedInCi {
        /// The CI environment variable that was found set.
        variable: String,
    },

    /// `spawn` step could not start the requested subprocess.
    #[error("spawn `{id}` failed: command `{command}`")]
    ProcessSpawn {
        /// Scenario-supplied identifier for the subprocess.
        id: String,
        /// The command line that was attempted (already env-substituted).
        command: String,
        /// Underlying I/O error from `tokio::process::Command::spawn`.
        #[source]
        source: io::Error,
    },

    /// `kill` / `wait` against a previously-spawned subprocess failed.
    #[error("kill/wait on `{id}` failed: {context}")]
    ProcessControl {
        /// Subprocess identifier.
        id: String,
        /// Short phrase describing which control operation tripped.
        context: String,
        /// Underlying I/O error.
        #[source]
        source: io::Error,
    },

    /// Step referenced a subprocess id that the registry has never seen.
    #[error("no spawned process registered under id `{id}`")]
    UnknownProcess {
        /// The unknown identifier.
        id: String,
    },

    /// `spawn` step asked for an id that is already live in the registry.
    #[error("subprocess id `{id}` is already registered (call `kill` first)")]
    DuplicateProcessId {
        /// The conflicting identifier.
        id: String,
    },

    /// `spawn` step declared neither a `command:` nor a `from: SAMPLE.md` source.
    #[error("spawn `{id}` declared no command and no `from:` source")]
    SpawnMissingSource {
        /// The subprocess identifier whose spawn args were under-specified.
        id: String,
    },

    /// `wait_port` step did not see the expected port state before its deadline.
    #[error("wait_port {port} (expect {expect}) timed out after {timeout_s}s")]
    WaitPortTimeout {
        /// TCP port that was being probed.
        port: u16,
        /// Configured timeout in seconds.
        timeout_s: u32,
        /// Expected state at the deadline (`open` or `closed`).
        expect: &'static str,
    },

    /// `assert_log` / `assert_log_clean` step found the log in the wrong shape.
    #[error("log assertion on `{id}` failed: {reason}")]
    LogAssertion {
        /// Subprocess identifier whose log was being inspected.
        id: String,
        /// Why the assertion failed (e.g. "pattern not found", "deny matched").
        reason: String,
    },

    /// A regex flag string from the YAML used unsupported characters.
    #[error("invalid regex flags `{flags}`: {reason}")]
    RegexFlags {
        /// The offending flag string.
        flags: String,
        /// What was wrong with it.
        reason: String,
    },

    /// Building the underlying `reqwest::Client` failed (TLS, DNS resolver init, …).
    #[error("HTTP client initialization failed")]
    HttpClient {
        /// Underlying `reqwest` error.
        #[source]
        source: reqwest::Error,
    },

    /// An `http:` step could not complete the request (DNS, refused connect, timeout, …).
    #[error("HTTP request to `{url}` failed")]
    HttpRequest {
        /// Target URL.
        url: String,
        /// Underlying `reqwest` error.
        #[source]
        source: reqwest::Error,
    },

    /// An `http:` step's response had a different status code than `expect_status:`.
    #[error("HTTP `{url}` returned status {actual}, expected {expected}")]
    HttpStatusMismatch {
        /// Target URL.
        url: String,
        /// Status code declared in the YAML.
        expected: u16,
        /// Status code the server actually returned.
        actual: u16,
    },

    /// Reading an `http:` step's response body failed (connection drop, decode error, …).
    #[error("HTTP `{url}` body read failed")]
    HttpBodyRead {
        /// Target URL.
        url: String,
        /// Underlying `reqwest` error.
        #[source]
        source: reqwest::Error,
    },

    /// An `http:` step's response body did not contain a required substring.
    #[error("HTTP `{url}` body missing required substring `{expected}`")]
    HttpBodyMismatch {
        /// Target URL.
        url: String,
        /// The substring from `expect_body_contains:` that was missing.
        expected: String,
    },

    /// `SAMPLE.md` had no fenced `yaml` code block to parse as the manifest.
    #[error("SAMPLE.md at `{path}` has no fenced yaml block")]
    SampleMissingYaml {
        /// Filesystem path of the offending `SAMPLE.md`.
        path: String,
    },

    /// A scenario used `spawn: { from: SAMPLE.md }` in a mode where no sample
    /// context is available (typically `--run-scenario`, which is single-file).
    #[error(
        "spawn `{id}` requested `from: SAMPLE.md` but no sample context is active (use `--sample` mode)"
    )]
    SpawnFromSampleNoContext {
        /// The subprocess id whose spawn args needed manifest resolution.
        id: String,
    },

    /// A `- report: fail` step declared the scenario a failure. The verdict is
    /// the scenario author's, and the runner honors it rather than walking past
    /// the step.
    #[error("scenario `{scenario}` declared the `fail` verdict via a report: step")]
    ScenarioReportedFailure {
        /// Name of the scenario that declared the failure.
        scenario: String,
    },

    /// The scenario finished without the runner evaluating anything: every step
    /// was lifecycle-only, buffered, or of a kind that has no replay dispatch.
    /// A run that checked nothing about the system under test is not a pass.
    #[error(
        "scenario `{scenario}` evaluated nothing ({steps} steps, {skipped} skipped for want of a replay dispatch)"
    )]
    ScenarioNothingEvaluated {
        /// Name of the scenario.
        scenario: String,
        /// How many steps the scenario declared.
        steps: usize,
        /// How many of those the runner skipped.
        skipped: usize,
    },

    /// At least one `must_pass` scenario in a `--sample` run reported FAIL.
    ///
    /// `first_error` carries the first failing scenario's own message so the
    /// locator, status code, or judge score that actually failed reaches the
    /// run summary instead of a bare count.
    #[error("sample run: {failed} of {total} scenarios failed; first failure: {first_error}")]
    SampleScenarioFailures {
        /// Number of scenarios that returned `Err`.
        failed: usize,
        /// Total scenarios attempted in the run.
        total: usize,
        /// Display text of the first scenario failure, verbatim.
        first_error: String,
    },

    /// The scenario set in effect names none of the sample's scenarios, while
    /// other tiers of its `SAMPLE.md` do declare some. The sample declares
    /// work; the invocation filtered all of it out, so nothing would replay
    /// and there is nothing to call a pass.
    #[error(
        "sample `{sample_dir}`: scenario set `{selected}` selected 0 of the SAMPLE.md's {total} scenarios; they are declared under: {populated}. Name a set that covers them — `--scenarios` on the command line, or `default_set:` in mirroir.yaml"
    )]
    SampleSetMatchedNothing {
        /// Directory whose `SAMPLE.md` was read.
        sample_dir: PathBuf,
        /// The set that was in effect: `must_pass`, `nice_to_pass`, or `all`.
        selected: String,
        /// Scenarios the manifest declares across every tier.
        total: usize,
        /// Comma-separated tiers that do declare scenarios.
        populated: String,
    },

    /// The sample's `SAMPLE.md` declares no scenario in any tier. Unlike
    /// [`Self::SampleSetMatchedNothing`] no scenario set can rescue this run —
    /// the manifest itself declares no work.
    #[error(
        "sample `{sample_dir}`: SAMPLE.md declares no scenarios in any tier; a sample that replays nothing is not a pass"
    )]
    SampleDeclaresNoScenarios {
        /// Directory whose `SAMPLE.md` was read.
        sample_dir: PathBuf,
    },

    /// A `baselines/*.ios.txt` the sample commits that no scenario its
    /// `SAMPLE.md` declares names in `cross_surface.response_files`. That
    /// suffix marks a capture from a surface this binary drives no executor
    /// for, so the only thing that ever reads one is the step comparing it:
    /// unnamed, it is read by nothing and the sample reports green with the
    /// parity gate it was captured for absent. A baseline a declared scenario
    /// names, on a run whose scenario set left that scenario out, is logged
    /// rather than refused — the tier is the invocation's choice.
    #[error(
        "sample `{sample_dir}`: `{baseline}` is compared by none of the {scenarios} scenario(s) `SAMPLE.md` declares; a captured surface no scenario names is read by nothing"
    )]
    SampleBaselineUnreferenced {
        /// Directory whose `baselines/` holds the file.
        sample_dir: PathBuf,
        /// The unreferenced baseline, as `baselines/<file>`.
        baseline: String,
        /// How many scenarios the manifest declares across both tiers.
        scenarios: usize,
    },

    /// A scenario's web steps are split by a runner-side step. Every scenario
    /// compiles to exactly one Playwright invocation, so a second run of web
    /// steps would execute out of the order the file reads.
    #[error(
        "scenario splits its web steps: step {index} (`{kind}`) resumes web work after step {block_end} ended the web block and step `{separator_kind}` ran on the runner side. A scenario compiles to one Playwright invocation — move every web step into a single adjacent run"
    )]
    WebBlockNotContiguous {
        /// Index of the offending web step (0-based, as the file reads).
        index: usize,
        /// Step kind at `index`.
        kind: &'static str,
        /// Index of the last web step in the scenario's first web run.
        block_end: usize,
        /// Kind of the runner-side step that ended the web run.
        separator_kind: &'static str,
    },

    /// A `target:` step names a surface this binary has no executor for. Only
    /// `web` opens one here; `ios` and `macos` belong to mirroir-mcp, which
    /// talks to the device from Swift, and `process` / `http` work is carried
    /// by the steps themselves rather than by a surface declaration.
    #[error(
        "step {index} declares `target: {{ kind: {kind} }}`, which mirroir-run has no executor for. Only `target: {{ kind: web }}` runs here — it compiles to one Playwright invocation. `ios` and `macos` surfaces are driven by mirroir-mcp, the Swift MCP server; subprocess and REST work needs no `target:` at all, because `spawn:`, `kill:` and `http:` steps dispatch in Rust on their own"
    )]
    NoExecutorForTargetKind {
        /// Index of the `target:` step, as the file reads.
        index: usize,
        /// The surface kind it declared.
        kind: TargetKind,
    },

    /// A scenario declares its surface twice. The compiler consumes the
    /// declaration the web block opens with and emits nothing for any other,
    /// so a second `target:` is a declaration nothing executes — including one
    /// that switches surface mid-file, whose steps would compile into the
    /// first surface's run.
    #[error(
        "step {index} declares a second `target:`; step {first} already declared this scenario's surface. One scenario runs on one surface: a later `target:` executes nothing, and a second Playwright invocation would start a fresh context, silently discarding the first one's cookies, storage and in-memory state"
    )]
    SecondTargetDeclared {
        /// Index of the `target:` step that already declared the surface.
        first: usize,
        /// Index of the second declaration, as the file reads.
        index: usize,
    },

    /// A scenario's web steps have no browser to run in. They compile to one
    /// Playwright invocation, and the `target: { kind: web, ... }` step that
    /// opens the web block is what tells that invocation which browsers to
    /// start and where to navigate.
    #[error(
        "scenario has no `target: {{ kind: web, ... }}` step opening its web block (first step is `{first_step}`, declared target kind: {declared}). Web steps compile to a Playwright invocation and need a browser to run in"
    )]
    NoWebTarget {
        /// Kind of the scenario's first step, as the file reads.
        first_step: &'static str,
        /// The surface the scenario did declare, spelled as the file spells
        /// it, or `none` when it declared no `target:` at all.
        declared: &'static str,
    },

    /// A web step reached the runner-side dispatcher. Web steps belong to the
    /// scenario's single Playwright invocation and are never dispatched one by
    /// one; reaching this means the execution plan and the dispatcher disagree.
    #[error("step {index} (`{kind}`) is a web step and cannot be dispatched outside the web block")]
    WebStepOutsideBlock {
        /// Index of the step, as the file reads.
        index: usize,
        /// Step kind at `index`.
        kind: &'static str,
    },

    /// A `measure:` step declared a `max_seconds` budget the observed latency
    /// exceeded.
    #[error("measure `{name}` took {observed_s:.3}s, over its {max_seconds:.3}s budget")]
    MeasureBudgetExceeded {
        /// The measure step's `name`.
        name: String,
        /// Observed latency in seconds, from the Playwright attachment.
        observed_s: f64,
        /// Declared ceiling in seconds.
        max_seconds: f64,
    },

    /// A `measure:` step ran inside the web block but the invocation's
    /// `mirroir-captures` attachment carried no timing for it.
    #[error("measure `{name}` recorded no timing in the `mirroir-captures` attachment")]
    MeasureNotCaptured {
        /// The measure step's `name`.
        name: String,
    },

    /// A `cross_surface.capture` was declared but the invocation's
    /// `mirroir-captures` attachment carried no text for it — its `to` file
    /// would be compared stale, or not at all.
    #[error(
        "cross_surface step {index} declared a capture into `{to}` but the `mirroir-captures` attachment carried no text for it"
    )]
    CrossSurfaceNotCaptured {
        /// Index of the `cross_surface` step, as the file reads.
        index: usize,
        /// The capture's `to` path.
        to: String,
    },

    /// `std::fmt::Write` failure while building emitter output. Theoretically
    /// unreachable when writing to `String`, but typed for `?`-propagation.
    #[error("internal formatting error")]
    Format(#[from] fmt::Error),

    /// `cross_surface:` step found a pair of responses whose fingerprint
    /// similarity dropped below the configured threshold.
    #[error("cross_surface mismatch: `{a}` vs `{b}` similarity {observed:.3} < min {threshold:.3}")]
    CrossSurfaceMismatch {
        /// First file path of the mismatching pair.
        a: String,
        /// Second file path of the mismatching pair.
        b: String,
        /// Jaccard similarity actually observed for that pair.
        observed: f64,
        /// Minimum similarity required.
        threshold: f64,
    },

    /// `cross_surface:` step requires at least two response files to compare.
    #[error("cross_surface: need at least 2 response files, got {count}")]
    CrossSurfaceTooFewFiles {
        /// How many were supplied.
        count: usize,
    },

    /// A `cross_surface:` response file fingerprinted to no tokens. Jaccard
    /// calls two empty token sets identical — the documented answer for drift
    /// against a recorded baseline — so a blank surface would clear any
    /// threshold against another blank one and prove nothing. `generate_skill`
    /// writes a lone newline when a screen yielded no OCR text, which is how an
    /// empty surface reaches the check in practice.
    #[error(
        "cross_surface response file `{path}` has no comparable text: an empty surface cannot substantiate an equivalence check"
    )]
    CrossSurfaceEmptySurface {
        /// The response file whose fingerprint held no tokens.
        path: String,
    },

    /// `cross_surface:` capture writes somewhere the step never reads. The
    /// capture produces one of the compared baselines, so a `to` outside
    /// `response_files` — a typo, usually — would leave the scraped text
    /// unread and compare a stale or missing file in its place.
    #[error(
        "cross_surface capture writes to `{to}`, which is not one of response_files {response_files:?}"
    )]
    CrossSurfaceCaptureTargetNotListed {
        /// Path the capture would have written.
        to: String,
        /// The files the step actually compares.
        response_files: Vec<String>,
    },

    /// A judge-scoring or drift-threshold failure.
    #[error(transparent)]
    Oracle(#[from] OracleError),

    /// A Playwright compile / invoke / report-ingest failure.
    #[error(transparent)]
    Playwright(#[from] PlaywrightError),

    /// A `.mirroir/` pipeline failure — config discovery, archetype
    /// resolution, lockfile freshness, compose, or plan aggregation.
    #[error(transparent)]
    Mirroir(#[from] MirroirError),
}
