// ABOUTME: Structured error type for the mirroir-run binary — no anyhow!(), no untyped errors.
// ABOUTME: Every fallible operation returns Result<T, RunnerError> built from thiserror variants.

use std::fmt;
use std::io;
use std::ops::RangeInclusive;
use std::path::PathBuf;
use std::result::Result as StdResult;

use thiserror::Error;

use crate::compile::error::PlaywrightError;
use crate::compile::report_error::ReportError;
use crate::cross_surface_error::CrossSurfaceError;
use crate::ios_error::IosError;
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

    /// A device step sits outside the block its surface opened. Each block
    /// compiles to exactly one invocation — Playwright for `web`, mirroir-mcp
    /// for `ios` — so a second run of device steps would execute out of the
    /// order the file reads, in a fresh session.
    #[error(
        "scenario splits its {surface} steps: step {index} (`{kind}`) resumes {surface} work after step {block_end} ended the {surface} block and step `{separator_kind}` ran on the runner side. Each block runs as one invocation — move every {surface} step into a single adjacent run"
    )]
    BlockNotContiguous {
        /// Index of the offending device step (0-based, as the file reads).
        index: usize,
        /// Step kind at `index`.
        kind: &'static str,
        /// The surface of the block that already ended.
        surface: TargetKind,
        /// Index of the last step of that block.
        block_end: usize,
        /// Kind of the runner-side step that ended the block.
        separator_kind: &'static str,
    },

    /// A `target:` step names a surface this binary has no executor for.
    /// `web` runs through Playwright and `ios` through mirroir-mcp; `macos`
    /// windows are driven by `mirroir-mcp test` directly, and `process` /
    /// `http` work is carried by the steps themselves rather than by a
    /// surface declaration.
    #[error(
        "step {index} declares `target: {{ kind: {kind} }}`, which mirroir-run has no executor for. `web` blocks run through Playwright and `ios` blocks through mirroir-mcp; a `macos` window is driven by `mirroir-mcp test` directly, and subprocess and REST work needs no `target:` at all, because `spawn:`, `kill:` and `http:` steps dispatch in Rust on their own"
    )]
    NoExecutorForTargetKind {
        /// Index of the `target:` step, as the file reads.
        index: usize,
        /// The surface kind it declared.
        kind: TargetKind,
    },

    /// An `ios` block runs through mirroir-mcp, which drives iPhone Mirroring
    /// — a macOS application. On any other host the block cannot run, and it
    /// is refused rather than skipped: a skipped block is a silent pass.
    #[error(
        "step {index} declares `target: {{ kind: ios }}`, which runs through mirroir-mcp and iPhone Mirroring on a macOS host; this host is not macOS"
    )]
    IosNeedsMacosHost {
        /// Index of the `target:` step, as the file reads.
        index: usize,
    },

    /// A scenario declares the same surface twice. Each surface runs as one
    /// invocation; a second block of it would start a fresh session, silently
    /// discarding the first one's state.
    #[error(
        "step {index} declares a second `target: {{ kind: {surface} }}`; step {first} already opened this scenario's {surface} block. A second invocation would start a fresh session, silently discarding the first one's state"
    )]
    SurfaceDeclaredTwice {
        /// The surface declared twice.
        surface: TargetKind,
        /// Index of the `target:` step that already opened it.
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

    /// `std::fmt::Write` failure while building emitter output. Theoretically
    /// unreachable when writing to `String`, but typed for `?`-propagation.
    #[error("internal formatting error")]
    Format(#[from] fmt::Error),

    /// A `cross_surface:` parity-gate failure — its captures, files, or verdict.
    #[error(transparent)]
    CrossSurface(#[from] CrossSurfaceError),

    /// An `ios` block that could not be written in mirroir-mcp's dialect or run.
    #[error(transparent)]
    Ios(#[from] IosError),

    /// A judge-scoring or drift-threshold failure.
    #[error(transparent)]
    Oracle(#[from] OracleError),

    /// A Playwright compile / invoke failure.
    #[error(transparent)]
    Playwright(#[from] PlaywrightError),

    /// A reporter document — Playwright's or mirroir-mcp's — that could not be
    /// ingested, or that recorded failures.
    #[error(transparent)]
    Report(#[from] ReportError),

    /// A `.mirroir/` pipeline failure — config discovery, archetype
    /// resolution, lockfile freshness, compose, or plan aggregation.
    #[error(transparent)]
    Mirroir(#[from] MirroirError),
}
