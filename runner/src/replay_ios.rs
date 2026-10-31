// ABOUTME: Runs a scenario's `ios` block and owns its compiled screen reference — compare it, or record it.
// ABOUTME: A recorded reference is staged in the block workspace and promoted next to the scenario only on a green run.

use std::fs;
use std::ops::Range;
use std::path::{self, Path, PathBuf};

use tracing::info;

use crate::compile::mirroir_block::ios_block_yaml;
use crate::compile::report::RunCaptures;
use crate::error::{Result, RunnerError};
use crate::oracle::baseline::BaselineMode;
use crate::oracle::drift_session::DriftSession;
use crate::oracle::error::OracleError;
use crate::oracle::screen_drift::ScreenCheck;
use crate::parser::compiled::{CompiledSkill, compiled_path, load_compiled, sha256_hex};
use crate::parser::scenario::Scenario;
use crate::target::ios::{CompiledRecording, MirroirMcpRunner};

/// File `mirroir-mcp test --compiled-out` writes inside the block workspace.
///
/// Deliberately not `ios-block.compiled.json`: mirroir-mcp replays a compiled
/// file that sits next to the skill it runs, and the block must run live.
const STAGED_REFERENCE: &str = "screen-reference.compiled.json";

/// One `ios` block to run, and where its scenario lives.
#[derive(Debug, Clone)]
pub struct IosBlock<'a> {
    /// The scenario the block belongs to.
    pub scenario: &'a Scenario,
    /// Scenario indices of the block's steps, its `target:` first.
    pub block: Range<usize>,
    /// The block workspace (block file, report, staged reference).
    pub dir: &'a Path,
    /// The scenario file, whose `.compiled.json` sibling is the reference.
    pub scenario_path: &'a Path,
    /// Compare against the reference, or re-record it.
    pub mode: BaselineMode,
}

/// A compiled reference the block recorded, waiting for the run's verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingReference {
    staged: PathBuf,
    destination: PathBuf,
}

/// What the block does with the scenario's compiled reference.
enum ScreenReference {
    /// A reference exists and the run compares against it.
    Compare {
        reference: Box<CompiledSkill>,
        source_sha256: String,
    },
    /// No reference yet, or `accept`: the passing block records one.
    Record(PendingReference),
}

/// Write the block in mirroir-mcp's dialect, run it once with `mirroir-mcp
/// test`, and return what it attached — its final screen among it.
///
/// In compare mode, when `<scenario>.compiled.json` exists, every screen the
/// block left is compared against it and what moved lands in `drift`. In
/// accept mode, or when no reference exists yet, mirroir-mcp is told to record
/// one; it comes back as a [`PendingReference`] for [`promote_reference`].
///
/// # Errors
///
/// * Anything [`MirroirMcpRunner::run`] returns.
/// * [`OracleError::CompiledParse`] (or a version-gate error) for an existing
///   reference that does not load.
/// * [`OracleError::CompiledNotRecorded`] when a block asked to record passed
///   without writing the compiled skill.
/// * [`crate::oracle::error::OracleError::ThresholdUnspecified`] when screens
///   are compared and no layer declares `fingerprint_similarity`.
pub async fn run_ios_block(
    run: IosBlock<'_>,
    drift: &mut DriftSession,
) -> Result<(RunCaptures, Option<PendingReference>)> {
    let reference = screen_reference(&run)?;
    let recording = match &reference {
        ScreenReference::Record(pending) => {
            discard_stale(&pending.staged)?;
            Some(CompiledRecording {
                out: pending.staged.clone(),
                source: absolute(run.scenario_path)?,
            })
        }
        ScreenReference::Compare { .. } => None,
    };
    let yaml = ios_block_yaml(&run.scenario.name, &run.scenario.steps, run.block.clone())?;
    let runner = MirroirMcpRunner::from_env()?.with_recording(recording);
    info!(
        ios_steps = run.block.len(),
        workspace = %run.dir.display(),
        records_reference = matches!(reference, ScreenReference::Record(_)),
        "dispatching the scenario's ios block to mirroir-mcp"
    );
    let outcome = runner
        .run(&yaml, &run.scenario.steps[run.block.clone()], run.dir)
        .await?;
    info!(
        passed = outcome.verdict.passed,
        failed = outcome.verdict.failed,
        metrics = outcome.captures.metrics.len(),
        cross_surface_captures = outcome.captures.cross_surface.len(),
        screens = outcome.captures.screens.len(),
        workspace = %run.dir.display(),
        "mirroir-mcp invocation completed"
    );
    match reference {
        ScreenReference::Compare {
            reference,
            source_sha256,
        } => {
            drift.observe_screens(ScreenCheck {
                reference: &reference,
                source_sha256: &source_sha256,
                observed: &outcome.captures.screens,
                observed_device: outcome.captures.device.as_ref(),
                block_start: run.block.start,
            })?;
            Ok((outcome.captures, None))
        }
        ScreenReference::Record(pending) => {
            if !pending.staged.is_file() {
                return Err(OracleError::CompiledNotRecorded {
                    staged: pending.staged,
                    destination: pending.destination,
                }
                .into());
            }
            // Refuse what the next run could not load, before it is promoted.
            load_compiled(&pending.staged)?;
            Ok((outcome.captures, Some(pending)))
        }
    }
}

/// Copy a recorded reference next to its scenario. Called only for a run
/// whose verdict records baselines — a green run, or `accept`.
///
/// # Errors
///
/// [`RunnerError::Io`] when the reference cannot be copied into place.
pub fn promote_reference(pending: &PendingReference) -> Result<()> {
    fs::copy(&pending.staged, &pending.destination).map_err(|source| RunnerError::Io {
        context: format!(
            "record the compiled screen reference {} from {}",
            pending.destination.display(),
            pending.staged.display()
        ),
        source,
    })?;
    info!(reference = %pending.destination.display(), "recorded the compiled screen reference");
    Ok(())
}

fn screen_reference(run: &IosBlock<'_>) -> Result<ScreenReference> {
    let destination = compiled_path(&absolute(run.scenario_path)?);
    if run.mode == BaselineMode::Compare && destination.is_file() {
        let bytes = fs::read(run.scenario_path).map_err(|source| RunnerError::Io {
            context: format!("hash scenario file {}", run.scenario_path.display()),
            source,
        })?;
        return Ok(ScreenReference::Compare {
            reference: Box::new(load_compiled(&destination)?),
            source_sha256: sha256_hex(&bytes),
        });
    }
    Ok(ScreenReference::Record(PendingReference {
        staged: run.dir.join(STAGED_REFERENCE),
        destination,
    }))
}

/// A reference left by an earlier run must not stand in for this one.
fn discard_stale(staged: &Path) -> Result<()> {
    if !staged.exists() {
        return Ok(());
    }
    fs::remove_file(staged).map_err(|source| RunnerError::Io {
        context: format!("remove stale {}", staged.display()),
        source,
    })
}

/// `mirroir-mcp test` runs with the block workspace as its working directory,
/// so the paths it is handed are anchored first.
fn absolute(path: &Path) -> Result<PathBuf> {
    path::absolute(path).map_err(|source| RunnerError::Io {
        context: format!("resolve {}", path.display()),
        source,
    })
}
