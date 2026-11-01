// ABOUTME: Runs a scenario's `ios` block through `mirroir-mcp test` and ingests the report it writes.
// ABOUTME: The report is Playwright's JSON-reporter shape, so it lands in the same ingest as a web block.

use std::env;
use std::ffi::OsString;
use std::path::{self, Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use tokio::fs;
use tokio::process::Command;
use tokio::time::{Instant, timeout};
use tracing::{debug, info, warn};

use crate::compile::invoke::{tail, which_in};
use crate::compile::report::{ReporterOutcome, parse_report_body};
use crate::compile::report_error::ReportEngine;
use crate::error::Result;
use crate::ios_error::IosError;
use crate::parser::step::SkillStep;
use crate::replay_cross_surface::IOS_CAPTURE_KEY;
use crate::target::ios_budget::{
    DEFAULT_IOS_STEP_ALLOWANCE, IOS_STEP_ALLOWANCE_ENV, block_budget, step_allowance,
};
use crate::target::process_log::{drain, joined, send_group_sigkill};

/// Environment variable naming the `mirroir-mcp` binary, ahead of `PATH`.
pub const MIRROIR_MCP_BIN_ENV: &str = "MIRROIR_MCP_BIN";

/// Environment variable the spawned `mirroir-mcp test` reads its
/// mirroir-skills checkout from: the block runs in its scratch workspace,
/// where no working-directory-relative path reaches the checkout.
pub const MIRROIR_SKILLS_ENV: &str = "MIRROIR_SKILLS";

/// Name of the binary looked up on `PATH`.
const MIRROIR_MCP: &str = "mirroir-mcp";

/// File the block is written to inside the scenario's workspace.
const BLOCK_FILE: &str = "ios-block.yaml";

/// File `mirroir-mcp test` writes its report to inside the workspace.
const REPORT_FILE: &str = "ios-report.json";

/// Where `mirroir-mcp test --compiled-out` writes the compiled skill a
/// passing block records, and the file whose digest it stamps on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompiledRecording {
    /// `--compiled-out`: the path the compiled skill is written to.
    pub out: PathBuf,
    /// `--compiled-source`: the scenario file the block was rendered from.
    pub source: PathBuf,
}

/// Driver for one `mirroir-mcp test` invocation per `ios` block.
pub struct MirroirMcpRunner {
    binary: PathBuf,
    /// What each step of a block earns toward its run budget.
    step_allowance: Duration,
    /// Set when the block's passing run records the scenario's screen reference.
    recording: Option<CompiledRecording>,
    /// The mirroir-skills checkout handed to the child as
    /// [`MIRROIR_SKILLS_ENV`], absolute so the block workspace resolves it.
    skills: Option<PathBuf>,
}

impl MirroirMcpRunner {
    /// Resolve `mirroir-mcp`: [`MIRROIR_MCP_BIN_ENV`] when set, else `PATH`;
    /// the per-step allowance from [`IOS_STEP_ALLOWANCE_ENV`] when set.
    ///
    /// # Errors
    ///
    /// * [`IosError::NotInstalled`] when neither names an executable file.
    /// * [`IosError::InvalidStepAllowance`] when the allowance override is not
    ///   a whole number of seconds.
    pub fn from_env() -> Result<Self> {
        let allowance = step_allowance(env::var_os(IOS_STEP_ALLOWANCE_ENV))?;
        Ok(Self::resolve(
            env::var_os(MIRROIR_MCP_BIN_ENV),
            &env::var_os("PATH").unwrap_or_default(),
        )?
        .with_step_allowance(allowance))
    }

    /// Have a passing block record its compiled skill per `recording`.
    #[must_use]
    pub fn with_recording(mut self, recording: Option<CompiledRecording>) -> Self {
        self.recording = recording;
        self
    }

    /// Hand `skills`, the invocation's mirroir-skills checkout, to every
    /// block as [`MIRROIR_SKILLS_ENV`], so its pattern loaders read the same
    /// checkout as the runner's threshold layers.
    ///
    /// # Errors
    ///
    /// [`IosError::Workspace`] when a relative `skills` cannot be made absolute.
    pub fn with_skills(mut self, skills: Option<&Path>) -> Result<Self> {
        self.skills = skills
            .map(|dir| {
                path::absolute(dir).map_err(|source| IosError::Workspace {
                    context: format!("resolve {}", dir.display()),
                    source,
                })
            })
            .transpose()?;
        Ok(self)
    }

    /// Grant each step of a block `allowance` toward its run budget.
    #[must_use]
    pub fn with_step_allowance(mut self, allowance: Duration) -> Self {
        self.step_allowance = allowance;
        self
    }

    /// Resolve from an explicit override and search path, without touching the
    /// process environment. Steps earn [`DEFAULT_IOS_STEP_ALLOWANCE`].
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
            return Ok(Self {
                binary,
                step_allowance: DEFAULT_IOS_STEP_ALLOWANCE,
                recording: None,
                skills: None,
            });
        }
        which_in(path, MIRROIR_MCP)
            .map(|binary| Self {
                binary,
                step_allowance: DEFAULT_IOS_STEP_ALLOWANCE,
                recording: None,
                skills: None,
            })
            .ok_or_else(|| IosError::NotInstalled.into())
    }

    /// Write `block_yaml` (the dialect rendering of `steps`) into `workspace`,
    /// run it, and ingest the report.
    ///
    /// The block's final screen is always captured under
    /// [`IOS_CAPTURE_KEY`]: a `cross_surface` capture reads it, and a block no
    /// capture reads costs one OCR pass. The workspace is left in place so the
    /// block file and the report are there to read after a failure.
    ///
    /// The child runs inside the budget [`block_budget`] derives from `steps`;
    /// past it, its whole process group is killed.
    ///
    /// # Errors
    ///
    /// * [`IosError::Workspace`] when the block can't be written or the report
    ///   can't be read.
    /// * [`IosError::BlockTimeout`] when `mirroir-mcp test` outlives the budget.
    /// * [`IosError::NoReport`] when `mirroir-mcp test` exits without writing
    ///   the report — it refused the block, or could not reach the device.
    /// * Anything [`parse_report_body`] returns — including per-test failures,
    ///   which name the failing step.
    pub async fn run(
        &self,
        block_yaml: &str,
        steps: &[SkillStep],
        workspace: &Path,
    ) -> Result<ReporterOutcome> {
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
            .arg(&block);
        // After the block path, so the positional layout before it is stable.
        if let Some(recording) = &self.recording {
            cmd.arg("--compiled-out")
                .arg(&recording.out)
                .arg("--compiled-source")
                .arg(&recording.source);
        }
        if let Some(skills) = &self.skills {
            cmd.env(MIRROIR_SKILLS_ENV, skills);
        }
        cmd.current_dir(workspace)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        // The child leads its own process group, so a kill reaches whatever it
        // spawned too — and with them every holder of the stderr pipe.
        #[cfg(unix)]
        cmd.process_group(0);
        let budget = block_budget(steps, self.step_allowance);
        debug!(binary = %self.binary.display(), block = %block.display(), ?budget, "spawning mirroir-mcp test");
        let mut child = cmd.spawn().map_err(|source| IosError::Workspace {
            context: format!("spawn {} test", self.binary.display()),
            source,
        })?;
        let stdout = drain(child.stdout.take());
        let stderr = drain(child.stderr.take());
        let started = Instant::now();
        let waited = timeout(budget, child.wait()).await;
        let Ok(waited) = waited else {
            send_group_sigkill(MIRROIR_MCP, &child);
            if let Err(error) = child.kill().await {
                warn!(%error, "mirroir-mcp test did not die on SIGKILL");
            }
            let elapsed = started.elapsed();
            let stderr_tail = tail(&joined(stderr).await);
            warn!(?elapsed, ?budget, stderr = %stderr_tail, "mirroir-mcp test outlived its budget; killed");
            return Err(IosError::BlockTimeout {
                elapsed,
                budget,
                steps: steps.len(),
                stderr_tail,
            }
            .into());
        };
        let status = waited.map_err(|source| IosError::Workspace {
            context: format!("wait for {} test", self.binary.display()),
            source,
        })?;
        joined(stdout).await;
        // mirroir-mcp narrates every step on stderr; keep it for the reader.
        let stderr_tail = tail(&joined(stderr).await);
        if status.success() {
            info!(status = ?status.code(), "mirroir-mcp test finished");
            debug!(stderr = %stderr_tail, "mirroir-mcp output");
        } else {
            warn!(status = ?status.code(), stderr = %stderr_tail, "mirroir-mcp test exited non-zero");
        }
        if !report.exists() {
            return Err(IosError::NoReport {
                status: status.code(),
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
#[path = "ios_tests.rs"]
mod tests;
