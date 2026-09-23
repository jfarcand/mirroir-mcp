// ABOUTME: Invoke `npx playwright test` against a compiled spec, ingest JSON reporter, return outcome.
// ABOUTME: The workspace persists under target/playwright/, so trace/video/screenshot outlive the run.

use std::env;
use std::ffi::OsStr;
use std::io;
use std::path::PathBuf;
use std::process::Stdio;

use tokio::fs;
use tokio::process::Command;
use tracing::{debug, info, warn};

use crate::compile::error::PlaywrightError;
use crate::compile::playwright::PlaywrightSpec;
use crate::compile::report::{ReporterOutcome, parse_report_body};
use crate::compile::report_error::ReportEngine;
use crate::compile::workspace::PlaywrightWorkspace;
use crate::error::Result;

/// Maximum bytes of subprocess output kept for diagnostics.
const OUTPUT_TAIL_BYTES: usize = 4096;

/// Driver for spawning a Playwright invocation.
///
/// Constructed once per scenario — the whole scenario compiles to a single
/// spec, so a scenario is exactly one [`Self::run`]. Reuses no state across
/// calls; every run owns the workspace directory it is handed.
pub struct PlaywrightRunner {
    npx: PathBuf,
}

impl PlaywrightRunner {
    /// Resolve `npx` from the process's `PATH` environment variable.
    ///
    /// # Errors
    ///
    /// [`PlaywrightError::NotInstalled`] when no `npx` is on `PATH`.
    pub fn from_env() -> Result<Self> {
        let path = env::var_os("PATH").unwrap_or_default();
        Self::from_path(&path)
    }

    /// Resolve `npx` from an explicit `PATH` string. Lets callers (and tests)
    /// supply a controlled search path without mutating the process env.
    ///
    /// # Errors
    ///
    /// [`PlaywrightError::NotInstalled`] when no `npx` is on `path`.
    pub fn from_path(path: &OsStr) -> Result<Self> {
        which_in(path, "npx")
            .map(|npx| Self { npx })
            .ok_or_else(|| PlaywrightError::NotInstalled.into())
    }

    /// Override the binary used as `npx`. Test-only — production callers go
    /// through [`Self::from_env`] / [`Self::from_path`].
    #[cfg(test)]
    pub fn with_npx(npx: PathBuf) -> Self {
        Self { npx }
    }

    /// Write the workspace at `root`, invoke Playwright, and ingest the JSON
    /// reporter.
    ///
    /// The workspace directory is recreated empty on every call and left in
    /// place afterwards:
    /// the trace, video, screenshot, and HTML report Playwright writes for a
    /// failing test are the whole point of running it, and a tempdir would
    /// delete them at exactly the moment they became useful.
    ///
    /// # Errors
    ///
    /// * [`PlaywrightError::Workspace`] on workspace setup failure.
    /// * [`PlaywrightError::Invoke`] when npx exits non-zero AND no
    ///   `playwright-report.json` was produced.
    /// * Anything [`parse_report_body`] returns — a parse failure, per-test
    ///   failures, an empty report, or an undecodable captures attachment.
    pub async fn run(
        &self,
        spec: &PlaywrightSpec,
        target: &PlaywrightWorkspace,
    ) -> Result<ReporterOutcome> {
        target.materialize(&spec.spec_ts, &spec.browsers).await?;
        self.spawn_npx(target).await?;
        let report_path = target.report_path();
        let path = report_path.display().to_string();
        let body = fs::read_to_string(&report_path).await.map_err(|source| {
            PlaywrightError::Workspace {
                context: format!("read {path}"),
                source,
            }
        })?;
        parse_report_body(ReportEngine::Playwright, &path, &body)
    }

    async fn spawn_npx(&self, workspace: &PlaywrightWorkspace) -> Result<()> {
        let mut cmd = Command::new(&self.npx);
        cmd.arg("-p")
            .arg("@playwright/test")
            .arg("playwright")
            .arg("test")
            .arg("--config")
            .arg(workspace.config_path())
            .arg(workspace.spec_path())
            .current_dir(&workspace.dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        debug!(npx = %self.npx.display(), workspace = %workspace.dir.display(), "spawning playwright");

        let output = match cmd.output().await {
            Ok(out) => out,
            Err(err) if err.kind() == io::ErrorKind::NotFound => {
                return Err(PlaywrightError::NotInstalled.into());
            }
            Err(source) => {
                return Err(PlaywrightError::Workspace {
                    context: "spawn npx playwright test".to_owned(),
                    source,
                }
                .into());
            }
        };

        // Playwright narrates itself on stdout and reports config / install
        // failures on stderr. Both are kept, not counted: a byte count tells a
        // reader nothing about why the invocation went the way it did.
        let stdout_tail = tail(&output.stdout);
        let stderr_tail = tail(&output.stderr);
        if output.status.success() {
            info!(status = ?output.status.code(), "playwright invocation finished");
            debug!(stdout = %stdout_tail, stderr = %stderr_tail, "playwright output");
        } else {
            warn!(
                status = ?output.status.code(),
                stdout = %stdout_tail,
                stderr = %stderr_tail,
                "playwright invocation exited non-zero"
            );
        }

        // Defer exit-code interpretation to the reporter ingest: when the JSON
        // report has structured failure detail, `TestFailures` names the
        // locator that failed and the raw exit code adds nothing. The ingest
        // still errors on an empty report, which catches config errors and
        // other non-test failure paths.
        if !output.status.success() && !workspace.report_path().exists() {
            return Err(PlaywrightError::Invoke {
                status: output.status.code(),
                stdout_tail,
                stderr_tail,
            }
            .into());
        }
        Ok(())
    }
}

/// Keep the last [`OUTPUT_TAIL_BYTES`] of a subprocess stream, lossily decoded.
pub fn tail(buf: &[u8]) -> String {
    let slice = if buf.len() <= OUTPUT_TAIL_BYTES {
        buf
    } else {
        &buf[buf.len() - OUTPUT_TAIL_BYTES..]
    };
    String::from_utf8_lossy(slice).into_owned()
}

/// Minimal `which` — walk `path`, return the first directory containing an
/// executable of `name`. Returns `None` when no such file exists.
pub fn which_in(path: &OsStr, name: &str) -> Option<PathBuf> {
    for dir in env::split_paths(path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::os::unix::fs::PermissionsExt;
    use std::result::Result as StdResult;

    use std::path::Path;

    use tempfile::TempDir;

    use super::*;
    use crate::compile::report_error::ReportError;
    use crate::error::RunnerError;
    use crate::parser::step::Browser;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn workspace(scratch: &Path) -> PlaywrightWorkspace {
        PlaywrightWorkspace::for_scenario(scratch, None, "unit")
    }

    fn sample_spec() -> PlaywrightSpec {
        PlaywrightSpec {
            spec_ts: "// stub\ntest('s', async () => {});\n".to_owned(),
            browsers: vec![Browser::Chrome],
        }
    }

    /// Build a stub `npx` shell script that writes a canned JSON report to
    /// the workspace's expected path and returns the requested exit code.
    async fn make_stub_npx(
        dir: &Path,
        canned_json: &str,
        exit_code: i32,
    ) -> StdResult<PathBuf, Box<dyn StdError>> {
        let json_path = dir.join("canned-report.json");
        fs::write(&json_path, canned_json).await?;
        let script_path = dir.join("fake-npx");
        // We don't know the workspace cwd at script-write time; the script
        // shells out via $PWD which Command sets via current_dir().
        let script = format!(
            "#!/bin/sh\n\
             cp '{}' \"$PWD/playwright-report.json\"\n\
             exit {}\n",
            json_path.display(),
            exit_code
        );
        fs::write(&script_path, script).await?;
        let mut perms = fs::metadata(&script_path).await?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&script_path, perms).await?;
        Ok(script_path)
    }

    #[tokio::test]
    async fn run_returns_outcome_on_all_passing_report() -> TestResult {
        let scratch = TempDir::new()?;
        let canned = r#"{"suites":[{"title":"s","specs":[{"title":"t","tests":[{"results":[{"status":"passed"}]}]}],"suites":[]}]}"#;
        let stub = make_stub_npx(scratch.path(), canned, 0).await?;
        let runner = PlaywrightRunner::with_npx(stub);
        let outcome = runner
            .run(&sample_spec(), &workspace(scratch.path()))
            .await?;
        assert_eq!(outcome.verdict.passed, 1);
        assert_eq!(outcome.verdict.failed, 0);
        Ok(())
    }

    #[tokio::test]
    async fn run_carries_captures_out_of_the_attachment() -> TestResult {
        let scratch = TempDir::new()?;
        let canned = include_str!("fixtures/playwright-captures.json");
        let stub = make_stub_npx(scratch.path(), canned, 0).await?;
        let runner = PlaywrightRunner::with_npx(stub);
        let outcome = runner
            .run(&sample_spec(), &workspace(scratch.path()))
            .await?;
        assert_eq!(
            outcome.captures.judge.get("6").map(String::as_str),
            Some("The reply mentions WebSocket and SSE.")
        );
        Ok(())
    }

    #[tokio::test]
    async fn run_returns_failure_when_report_has_failed_test() -> TestResult {
        let scratch = TempDir::new()?;
        let canned = include_str!("fixtures/playwright-strict-mode.json");
        let stub = make_stub_npx(scratch.path(), canned, 1).await?;
        let runner = PlaywrightRunner::with_npx(stub);
        let res = runner.run(&sample_spec(), &workspace(scratch.path())).await;
        let Err(RunnerError::Report(ReportError::TestFailures {
            failed,
            total,
            failures,
            ..
        })) = res
        else {
            return Err(format!("expected TestFailures, got {res:?}").into());
        };
        if failed != 1 || total != 1 {
            return Err(format!("wrong counts: failed={failed} total={total}").into());
        }
        let Some(first) = failures.first() else {
            return Err("no failure detail captured".into());
        };
        if !first
            .message
            .contains("strict mode violation: resolved to 3 elements")
        {
            return Err(format!("locator text lost: {}", first.message).into());
        }
        Ok(())
    }

    #[tokio::test]
    async fn invoke_error_when_no_report_and_nonzero_exit() -> TestResult {
        let scratch = TempDir::new()?;
        // Stub that exits non-zero and does NOT write any report.json.
        let script_path = scratch.path().join("fake-npx");
        let script = "#!/bin/sh\necho 'stdout detail' \necho 'simulated failure' >&2\nexit 17\n";
        fs::write(&script_path, script).await?;
        let mut perms = fs::metadata(&script_path).await?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&script_path, perms).await?;

        let runner = PlaywrightRunner::with_npx(script_path);
        let res = runner.run(&sample_spec(), &workspace(scratch.path())).await;
        let Err(RunnerError::Playwright(PlaywrightError::Invoke {
            status,
            stdout_tail,
            stderr_tail,
        })) = res
        else {
            return Err(format!("expected Invoke, got {res:?}").into());
        };
        if status != Some(17) {
            return Err(format!("expected status 17, got {status:?}").into());
        }
        if !stderr_tail.contains("simulated failure") {
            return Err(format!("stderr_tail missing message: {stderr_tail}").into());
        }
        if !stdout_tail.contains("stdout detail") {
            return Err(format!("stdout_tail missing message: {stdout_tail}").into());
        }
        Ok(())
    }

    /// A tempdir workspace deleted the trace, video, and screenshot at the
    /// exact moment they became useful. The workspace is a real directory now
    /// and everything Playwright wrote into it is still there afterwards.
    #[tokio::test]
    async fn the_workspace_and_its_artifacts_survive_the_run() -> TestResult {
        let scratch = TempDir::new()?;
        let canned = r#"{"suites":[{"title":"s","specs":[{"title":"t","tests":[{"results":[{"status":"passed"}]}]}],"suites":[]}]}"#;
        let stub = make_stub_npx(scratch.path(), canned, 0).await?;
        let runner = PlaywrightRunner::with_npx(stub);
        let target = workspace(scratch.path());
        runner.run(&sample_spec(), &target).await?;

        for path in [
            target.spec_path(),
            target.config_path(),
            target.report_path(),
        ] {
            if !path.exists() {
                return Err(format!("{} did not survive the run", path.display()).into());
            }
        }
        Ok(())
    }

    /// A second run of the same scenario must not read as carrying the first
    /// run's evidence, so the workspace is recreated empty each time.
    #[tokio::test]
    async fn a_rerun_clears_the_previous_run_artifacts() -> TestResult {
        let scratch = TempDir::new()?;
        let canned = r#"{"suites":[{"title":"s","specs":[{"title":"t","tests":[{"results":[{"status":"passed"}]}]}],"suites":[]}]}"#;
        let stub = make_stub_npx(scratch.path(), canned, 0).await?;
        let runner = PlaywrightRunner::with_npx(stub);
        let target = workspace(scratch.path());
        runner.run(&sample_spec(), &target).await?;

        let stale = target.dir.join("test-results").join("trace.zip");
        fs::create_dir_all(target.dir.join("test-results")).await?;
        fs::write(&stale, "stale").await?;
        runner.run(&sample_spec(), &target).await?;
        if stale.exists() {
            return Err("a previous run's artifact survived into the next run".into());
        }
        Ok(())
    }

    #[test]
    fn from_path_returns_not_installed_when_npx_absent() -> TestResult {
        // An empty path string yields no candidate directories.
        let res = PlaywrightRunner::from_path(OsStr::new(""));
        if !matches!(
            res,
            Err(RunnerError::Playwright(PlaywrightError::NotInstalled))
        ) {
            return Err(format!("expected NotInstalled, got {:?}", res.err()).into());
        }
        // A path pointing at a directory with no `npx` also yields the error.
        let empty_dir = TempDir::new()?;
        let res2 = PlaywrightRunner::from_path(empty_dir.path().as_os_str());
        if !matches!(
            res2,
            Err(RunnerError::Playwright(PlaywrightError::NotInstalled))
        ) {
            return Err(format!("expected NotInstalled, got {:?}", res2.err()).into());
        }
        Ok(())
    }

    #[tokio::test]
    async fn from_path_resolves_stub_npx_when_present() -> TestResult {
        let dir = TempDir::new()?;
        // Plant a stub binary named `npx`.
        let stub = make_stub_npx(dir.path(), "{}", 0).await?;
        let renamed = dir.path().join("npx");
        fs::rename(&stub, &renamed).await?;
        // If from_path errored we'd never get here; that itself is the assertion.
        let _runner = PlaywrightRunner::from_path(dir.path().as_os_str())?;
        Ok(())
    }
}
