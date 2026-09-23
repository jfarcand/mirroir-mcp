// ABOUTME: Runs a scenario's `ios` block through `mirroir-mcp test` and ingests the report it writes.
// ABOUTME: The report is Playwright's JSON-reporter shape, so it lands in the same ingest as a web block.

use std::env;
use std::ffi::OsString;
use std::path::{self, Path, PathBuf};
use std::process::Stdio;

use tokio::fs;
use tokio::process::Command;
use tracing::{debug, info, warn};

use crate::compile::invoke::{tail, which_in};
use crate::compile::report::{ReporterOutcome, parse_report_body};
use crate::compile::report_error::ReportEngine;
use crate::error::Result;
use crate::ios_error::IosError;
use crate::replay_cross_surface::IOS_CAPTURE_KEY;

/// Environment variable naming the `mirroir-mcp` binary, ahead of `PATH`.
pub const MIRROIR_MCP_BIN_ENV: &str = "MIRROIR_MCP_BIN";

/// Name of the binary looked up on `PATH`.
const MIRROIR_MCP: &str = "mirroir-mcp";

/// File the block is written to inside the scenario's workspace.
const BLOCK_FILE: &str = "ios-block.yaml";

/// File `mirroir-mcp test` writes its report to inside the workspace.
const REPORT_FILE: &str = "ios-report.json";

/// Driver for one `mirroir-mcp test` invocation per `ios` block.
pub struct MirroirMcpRunner {
    binary: PathBuf,
}

impl MirroirMcpRunner {
    /// Resolve `mirroir-mcp`: [`MIRROIR_MCP_BIN_ENV`] when set, else `PATH`.
    ///
    /// # Errors
    ///
    /// [`IosError::NotInstalled`] when neither names an executable file.
    pub fn from_env() -> Result<Self> {
        Self::resolve(
            env::var_os(MIRROIR_MCP_BIN_ENV),
            &env::var_os("PATH").unwrap_or_default(),
        )
    }

    /// Resolve from an explicit override and search path, without touching the
    /// process environment.
    ///
    /// # Errors
    ///
    /// [`IosError::NotInstalled`] when neither names an executable file.
    pub fn resolve(override_bin: Option<OsString>, path: &OsString) -> Result<Self> {
        if let Some(bin) = override_bin.map(PathBuf::from) {
            if !bin.is_file() {
                return Err(IosError::NotInstalled.into());
            }
            // The block runs with its workspace as the working directory, so a
            // relative override is anchored here, where it was checked.
            let binary = path::absolute(&bin).map_err(|source| IosError::Workspace {
                context: format!("resolve {}", bin.display()),
                source,
            })?;
            return Ok(Self { binary });
        }
        which_in(path, MIRROIR_MCP)
            .map(|binary| Self { binary })
            .ok_or_else(|| IosError::NotInstalled.into())
    }

    /// Write `block_yaml` into `workspace`, run it, and ingest the report.
    ///
    /// The block's final screen is always captured under
    /// [`IOS_CAPTURE_KEY`]: a `cross_surface` capture reads it, and a block no
    /// capture reads costs one OCR pass. The workspace is left in place so the
    /// block file and the report are there to read after a failure.
    ///
    /// # Errors
    ///
    /// * [`IosError::Workspace`] when the block can't be written or the report
    ///   can't be read.
    /// * [`IosError::NoReport`] when `mirroir-mcp test` exits without writing
    ///   the report — it refused the block, or could not reach the device.
    /// * Anything [`parse_report_body`] returns — including per-test failures,
    ///   which name the failing step.
    pub async fn run(&self, block_yaml: &str, workspace: &Path) -> Result<ReporterOutcome> {
        fs::create_dir_all(workspace)
            .await
            .map_err(|source| IosError::Workspace {
                context: format!("create {}", workspace.display()),
                source,
            })?;
        let block = workspace.join(BLOCK_FILE);
        let report = workspace.join(REPORT_FILE);
        fs::write(&block, block_yaml)
            .await
            .map_err(|source| IosError::Workspace {
                context: format!("write {}", block.display()),
                source,
            })?;
        // A report left by an earlier run must not stand in for this one.
        if report.exists() {
            fs::remove_file(&report)
                .await
                .map_err(|source| IosError::Workspace {
                    context: format!("remove stale {}", report.display()),
                    source,
                })?;
        }

        let mut cmd = Command::new(&self.binary);
        cmd.arg("test")
            .arg("--report-json")
            .arg(&report)
            .arg("--capture")
            .arg(IOS_CAPTURE_KEY)
            .arg(&block)
            .current_dir(workspace)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        debug!(binary = %self.binary.display(), block = %block.display(), "spawning mirroir-mcp test");
        let output = cmd.output().await.map_err(|source| IosError::Workspace {
            context: format!("spawn {} test", self.binary.display()),
            source,
        })?;
        // mirroir-mcp narrates every step on stderr; keep it for the reader.
        let stderr_tail = tail(&output.stderr);
        if output.status.success() {
            info!(status = ?output.status.code(), "mirroir-mcp test finished");
            debug!(stderr = %stderr_tail, "mirroir-mcp output");
        } else {
            warn!(status = ?output.status.code(), stderr = %stderr_tail, "mirroir-mcp test exited non-zero");
        }
        if !report.exists() {
            return Err(IosError::NoReport {
                status: output.status.code(),
                report,
                stderr_tail,
            }
            .into());
        }
        let body = fs::read_to_string(&report)
            .await
            .map_err(|source| IosError::Workspace {
                context: format!("read {}", report.display()),
                source,
            })?;
        parse_report_body(
            ReportEngine::MirroirMcp,
            &report.display().to_string(),
            &body,
        )
    }
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::error::Error as StdError;
    use std::ffi::OsString;
    use std::fs as std_fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::result::Result as StdResult;

    use tempfile::TempDir;

    use super::MirroirMcpRunner;
    use crate::compile::report_error::ReportError;
    use crate::error::RunnerError;
    use crate::ios_error::IosError;
    use crate::replay_cross_surface::IOS_CAPTURE_KEY;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    /// The report `mirroir-mcp test --report-json` writes for one passing skill
    /// with a final-screen capture — the exact document `PlaywrightReportWriter`
    /// produces on the Swift side.
    const PASSING_REPORT: &str = include_str!("fixtures/mirroir-mcp-report.json");

    /// A stand-in `mirroir-mcp` that records its arguments and writes `report`
    /// (or nothing) to the `--report-json` path, then exits `status`.
    fn stub(
        dir: &Path,
        report: Option<&str>,
        status: i32,
    ) -> StdResult<OsString, Box<dyn StdError>> {
        let bin = dir.join("mirroir-mcp");
        let write = match report {
            Some(body) => {
                let fixture = dir.join("report.fixture.json");
                std_fs::write(&fixture, body)?;
                format!("cp '{}' \"$3\"\n", fixture.display())
            }
            None => String::new(),
        };
        std_fs::write(
            &bin,
            format!(
                "#!/bin/sh\necho \"$@\" > '{}'\n{write}exit {status}\n",
                dir.join("args").display()
            ),
        )?;
        std_fs::set_permissions(&bin, std_fs::Permissions::from_mode(0o755))?;
        Ok(bin.into_os_string())
    }

    #[tokio::test]
    async fn a_passing_block_returns_its_final_screen_capture() -> TestResult {
        let dir = TempDir::new()?;
        let runner = MirroirMcpRunner::resolve(
            Some(stub(dir.path(), Some(PASSING_REPORT), 0)?),
            &OsString::new(),
        )?;
        let outcome = runner
            .run(
                "version: 1\nname: \"flow\"\nsteps:\n",
                &dir.path().join("ws"),
            )
            .await?;
        assert_eq!(outcome.verdict.passed, 1);
        assert_eq!(
            outcome
                .captures
                .cross_surface
                .get(IOS_CAPTURE_KEY)
                .map(String::as_str),
            Some("Alarmes Aucune alarme\n")
        );
        let args = std_fs::read_to_string(dir.path().join("args"))?;
        assert!(
            args.starts_with("test --report-json "),
            "unexpected argv: {args}"
        );
        assert!(
            args.contains(&format!("--capture {IOS_CAPTURE_KEY} ")),
            "no capture key: {args}"
        );
        Ok(())
    }

    /// Exiting without a report — a refused block, an unreachable device — is
    /// an error naming the report it never wrote, never a pass.
    #[tokio::test]
    async fn exiting_without_a_report_is_an_error() -> TestResult {
        let dir = TempDir::new()?;
        let runner = MirroirMcpRunner::resolve(Some(stub(dir.path(), None, 1)?), &OsString::new())?;
        match runner.run("version: 1\n", &dir.path().join("ws")).await {
            Err(RunnerError::Ios(IosError::NoReport {
                status: Some(1), ..
            })) => Ok(()),
            other => Err(format!("expected NoReport, got {:?}", other.map(|_| ())).into()),
        }
    }

    /// A failing step reaches the error through the shared ingest, named as
    /// mirroir-mcp's failure.
    #[tokio::test]
    async fn a_failing_block_names_the_step() -> TestResult {
        let dir = TempDir::new()?;
        let failing = PASSING_REPORT
            .replace("\"status\" : \"passed\"", "\"status\" : \"failed\", \"error\" : { \"message\" : \"step 2 (tap: \\\"Alarmes\\\"): not found\" }");
        let runner = MirroirMcpRunner::resolve(
            Some(stub(dir.path(), Some(&failing), 1)?),
            &OsString::new(),
        )?;
        match runner.run("version: 1\n", &dir.path().join("ws")).await {
            Err(RunnerError::Report(error @ ReportError::TestFailures { .. })) => {
                let text = error.to_string();
                assert!(text.starts_with("mirroir-mcp: 1 of 1"), "{text}");
                assert!(
                    text.contains("step 2 (tap: \"Alarmes\"): not found"),
                    "{text}"
                );
                Ok(())
            }
            other => Err(format!("expected TestFailures, got {:?}", other.map(|_| ())).into()),
        }
    }

    /// A relative override is checked from the caller's directory but spawned
    /// from the block's workspace; it has to be anchored before that move.
    #[tokio::test]
    async fn a_relative_override_still_runs_from_the_block_workspace() -> TestResult {
        let dir = TempDir::new()?;
        stub(dir.path(), Some(PASSING_REPORT), 0)?;
        let relative = pathdiff_from_cwd(&dir.path().join("mirroir-mcp"))?;
        let runner = MirroirMcpRunner::resolve(Some(relative), &OsString::new())?;
        let outcome = runner.run("version: 1\n", &dir.path().join("ws")).await?;
        assert_eq!(outcome.verdict.passed, 1);
        Ok(())
    }

    /// `target` spelled relative to the current directory: `../` up to the
    /// root, then the absolute path — relative however deep the cwd sits.
    fn pathdiff_from_cwd(target: &Path) -> StdResult<OsString, Box<dyn StdError>> {
        let cwd = env::current_dir()?;
        let ups = cwd.components().count().saturating_sub(1);
        let mut relative = PathBuf::new();
        for _ in 0..ups {
            relative.push("..");
        }
        relative.push(target.strip_prefix("/")?);
        Ok(relative.into_os_string())
    }

    #[test]
    fn an_override_naming_no_file_is_not_installed() -> TestResult {
        match MirroirMcpRunner::resolve(
            Some(OsString::from("/nonexistent/mirroir-mcp")),
            &OsString::new(),
        ) {
            Err(RunnerError::Ios(IosError::NotInstalled)) => Ok(()),
            Err(other) => Err(format!("wrong error: {other}").into()),
            Ok(_) => Err("a missing binary resolved".into()),
        }
    }
}
