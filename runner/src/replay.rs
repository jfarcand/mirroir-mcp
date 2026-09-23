// ABOUTME: Scenario replay orchestration — loads scenarios, dispatches steps, aggregates verdicts.
// ABOUTME: Both `--run-scenario <file>` and `--sample <dir>` modes funnel through `run_scenario_with_context`.

use std::collections::HashMap;
use std::env;
use std::fs;
use std::ops::Range;
use std::path::{Path, PathBuf};

use tracing::{info, warn};

use crate::compile::invoke::PlaywrightRunner;
use crate::compile::mirroir_block::ios_block_yaml;
use crate::compile::playwright::compile_scenario;
use crate::compile::playwright_prelude::ScenarioSource;
use crate::compile::report::RunCaptures;
use crate::compile::workspace::{PlaywrightWorkspace, path_stem};
use crate::error::{Result, RunnerError};
use crate::oracle::baseline::{BaselineMode, load_baseline, record_baseline};
use crate::oracle::drift_log::append_findings;
use crate::oracle::drift_session::DriftSession;
use crate::oracle::thresholds::{ThresholdSearch, load_policy};
use crate::parser::env::substitute;
use crate::parser::sample::{SAMPLE_SCHEMA_VERSION, SampleManifest, extract_yaml_block};
use crate::parser::scenario::{SCHEMA_VERSION, Scenario};
use crate::parser::step::TargetKind;
use crate::parser::surface::step_kind;
use crate::replay_dispatch::verify_measures;
use crate::replay_plan::{ScenarioPlan, Segment};
use crate::replay_step::{StepDispatch, StepVerdict, dispatch_step};
use crate::target::http::HttpClient;
use crate::target::ios::MirroirMcpRunner;
use crate::target::process::ProcessRegistry;
use crate::verdict::RunVerdict;

pub use crate::replay_sample::run_sample;
pub use crate::scenario_set::ScenarioSet;

/// Read + env-substitute + parse a scenario YAML file with `version` gating.
///
/// `extras` is merged on top of the process environment before substitution
/// — `--sample` mode uses this to expose `${MIRROIR_SAMPLE_DIR}` without
/// touching the global process env (which would require `unsafe`).
///
/// # Errors
///
/// * [`RunnerError::Io`] when the file can't be read.
/// * [`RunnerError::RegexCompile`] when env substitution fails.
/// * [`RunnerError::YamlParse`] when YAML deserialization fails.
/// * [`RunnerError::UnsupportedVersion`] when the `version:` field is out of range.
pub fn load_scenario_with_extras(path: &Path, extras: &[(&str, String)]) -> Result<Scenario> {
    let raw = fs::read_to_string(path).map_err(|source| RunnerError::Io {
        context: format!("read scenario file {}", path.display()),
        source,
    })?;

    let mut environment: HashMap<String, String> = env::vars().collect();
    for (k, v) in extras {
        environment.insert((*k).to_owned(), v.clone());
    }
    let substituted = substitute(&raw, &environment)?;

    let scenario: Scenario =
        serde_yaml::from_str(&substituted).map_err(|source| RunnerError::YamlParse {
            file: path.display().to_string(),
            source,
        })?;

    if scenario.version != SCHEMA_VERSION {
        return Err(RunnerError::UnsupportedVersion {
            artifact: "scenario.yaml".to_owned(),
            found: scenario.version,
            expected: SCHEMA_VERSION..=SCHEMA_VERSION,
        });
    }
    Ok(scenario)
}

/// Convenience wrapper for [`load_scenario_with_extras`] with no extras —
/// used by `--validate` / `--run-scenario` / `--emit` modes.
///
/// # Errors
///
/// Same as [`load_scenario_with_extras`].
pub fn load_scenario(path: &Path) -> Result<Scenario> {
    load_scenario_with_extras(path, &[])
}

/// Read + env-substitute + parse a `SAMPLE.md` manifest, gating on its `version` field.
///
/// `extras` is merged on top of the process environment before substitution,
/// mirroring [`load_scenario_with_extras`]. The substitution runs on the
/// extracted yaml body only — markdown prose around the fenced block is left
/// untouched. This lets a SAMPLE.md declare `cwd: "${ATMOSPHERE_HOME}"` and
/// resolve it from the caller's environment at load time.
///
/// # Errors
///
/// * [`RunnerError::Io`] when the file can't be read.
/// * [`RunnerError::SampleMissingYaml`] when no fenced yaml block is present.
/// * [`RunnerError::RegexCompile`] when env substitution fails.
/// * [`RunnerError::YamlParse`] when the YAML body fails deserialization.
/// * [`RunnerError::UnsupportedVersion`] when the manifest's `version:` is out of range.
pub fn load_sample_manifest_with_extras(
    path: &Path,
    extras: &[(&str, String)],
) -> Result<SampleManifest> {
    let raw = fs::read_to_string(path).map_err(|source| RunnerError::Io {
        context: format!("read SAMPLE.md at {}", path.display()),
        source,
    })?;
    let body = extract_yaml_block(&raw).ok_or_else(|| RunnerError::SampleMissingYaml {
        path: path.display().to_string(),
    })?;

    let mut environment: HashMap<String, String> = env::vars().collect();
    for (k, v) in extras {
        environment.insert((*k).to_owned(), v.clone());
    }
    let substituted = substitute(&body, &environment)?;

    let manifest: SampleManifest =
        serde_yaml::from_str(&substituted).map_err(|source| RunnerError::YamlParse {
            file: path.display().to_string(),
            source,
        })?;
    if manifest.version != SAMPLE_SCHEMA_VERSION {
        return Err(RunnerError::UnsupportedVersion {
            artifact: "SAMPLE.md".to_owned(),
            found: manifest.version,
            expected: SAMPLE_SCHEMA_VERSION..=SAMPLE_SCHEMA_VERSION,
        });
    }
    Ok(manifest)
}

/// Convenience wrapper for [`load_sample_manifest_with_extras`] with no extras —
/// used by `--sample` mode and the `--atmosphere` dispatcher.
///
/// # Errors
///
/// Same as [`load_sample_manifest_with_extras`].
pub fn load_sample_manifest(path: &Path) -> Result<SampleManifest> {
    load_sample_manifest_with_extras(path, &[])
}

/// Bundle of the SAMPLE.md manifest + the directory it was loaded from.
///
/// Carried by [`run_scenario_with_context`] when running a sample-driven
/// replay so `from: SAMPLE.md` on a `spawn:` step can fill in defaults.
#[derive(Debug, Clone, Copy)]
pub struct SampleContext<'a> {
    /// Directory `SAMPLE.md` lives in. `cwd:` overrides resolve relative to this.
    pub sample_dir: &'a Path,
    /// Parsed manifest.
    pub manifest: &'a SampleManifest,
}

/// Where a replay looks for the artifacts it is not handed inline — the
/// `mirroir-skills` checkout named by `--skills` / `MIRROIR_SKILLS`, which
/// supplies the global `drift-defaults.yaml` layer — and what it does with the
/// baselines it finds.
#[derive(Debug, Clone, Copy, Default)]
pub struct ReplayRoots<'a> {
    /// The `mirroir-skills` checkout, when the invocation named one. Supplies
    /// the global `drift-defaults.yaml` layer.
    pub skills: Option<&'a Path>,
    /// Compare against the recorded baselines, or re-record them from what
    /// this run observes. `mirroir-run accept` is the only caller that passes
    /// [`BaselineMode::Accept`].
    pub baselines: BaselineMode,
}

/// Execute one scenario end-to-end.
///
/// The scenario's [`ScenarioPlan`] runs in file order:
/// - runner-side steps run as **hooks** in Rust (`spawn:`, `http:`, `judge:`,
///   `kill:`, …);
/// - a `web` block compiles into one spec and runs in one `npx playwright
///   test`; an `ios` block is written in mirroir-mcp's dialect and runs in one
///   `mirroir-mcp test`. Each attaches the values only its surface has
///   (`measure:` latencies, `judge:` response text, `cross_surface:` captures);
/// - a hook after a block reads everything the blocks before it attached.
///
/// A scenario in which no step ever reports [`StepVerdict::Evaluated`]
/// checked nothing about the system under test and fails with
/// [`RunnerError::ScenarioNothingEvaluated`] — a run that evaluated nothing is
/// not a pass, whatever the individual steps logged.
///
/// Every judge score, judged response, and `measure:` latency the run observes
/// is compared against `.harness/last-green.json`. A run whose assertions all
/// held but whose observations moved past their resolved thresholds returns
/// [`RunVerdict::Drift`], appends its candidates to `.harness/drift-log.md`,
/// and leaves the baseline untouched for a human to review. A clean run
/// records what it saw as the next baseline.
///
/// # Errors
///
/// Any error returned by the dispatched step variants propagates verbatim,
/// plus [`RunnerError::BlockNotContiguous`] for a scenario whose device steps
/// are split, [`RunnerError::ScenarioNothingEvaluated`] for a scenario that
/// evaluated nothing, and
/// [`crate::oracle::error::OracleError::ThresholdUnspecified`] when a drift
/// comparison is due and no layer declares that metric's threshold.
pub async fn run_scenario_with_context(
    path: &Path,
    context: Option<SampleContext<'_>>,
    shared_processes: Option<&mut ProcessRegistry>,
    roots: ReplayRoots<'_>,
) -> Result<RunVerdict> {
    let extras: Vec<(&str, String)> = context.map_or_else(Vec::new, |ctx| {
        vec![("MIRROIR_SAMPLE_DIR", ctx.sample_dir.display().to_string())]
    });
    let scenario = load_scenario_with_extras(path, &extras)?;
    let plan = ScenarioPlan::build(&scenario.steps)?;
    let review_root = review_root()?;
    let policy = load_policy(
        scenario.drift,
        &ThresholdSearch {
            sample_dir: context.map(|ctx| ctx.sample_dir),
            skills_root: roots.skills,
            cwd: Some(&review_root),
            home: env::var_os("HOME").map(PathBuf::from).as_deref(),
        },
    )?;
    // In accept mode nothing is loaded to compare against: the run's own
    // observations become the baseline, so there is no comparison to make and
    // no threshold to resolve.
    let previous = match roots.baselines {
        BaselineMode::Compare => load_baseline(&review_root, &scenario.name)?,
        BaselineMode::Accept => None,
    };
    let mut drift = DriftSession::new(policy, previous);

    let mut local_processes = ProcessRegistry::default();
    let http = HttpClient::new()?;
    let session_shared = shared_processes.is_some();
    let processes: &mut ProcessRegistry = shared_processes.unwrap_or(&mut local_processes);
    let dispatch = StepDispatch {
        scenario_name: &scenario.name,
        context,
        session_shared,
        baselines: roots.baselines,
    };
    let mut counters = Counters::default();

    info!(
        file = %path.display(),
        name = %scenario.name,
        steps = scenario.steps.len(),
        with_sample = context.is_some(),
        session_shared,
        "scenario run starting"
    );

    let sample_name = context.map(|ctx| path_stem(ctx.sample_dir));
    let mut captures = RunCaptures::default();
    for segment in plan.segments() {
        let (kind, range) = match segment {
            Segment::Hook(index) => {
                run_hooks(
                    &[*index],
                    &scenario,
                    &dispatch,
                    processes,
                    &http,
                    &captures,
                    &mut counters,
                    &mut drift,
                )
                .await?;
                continue;
            }
            Segment::Block { kind, range } => (*kind, range.clone()),
        };
        let block_captures = match kind {
            TargetKind::Web => {
                let workspace = PlaywrightWorkspace::for_scenario(
                    &review_root,
                    sample_name.as_deref(),
                    &path_stem(path),
                );
                let source = ScenarioSource::read(path)?;
                run_web_block(&scenario, &plan, &source, range.len(), &workspace).await?
            }
            TargetKind::Ios => {
                let dir = PlaywrightWorkspace::ios_block_dir(
                    &review_root,
                    sample_name.as_deref(),
                    &path_stem(path),
                );
                run_ios_block(&scenario, range.clone(), &dir).await?
            }
            // The plan admits only surfaces with an executor on this host.
            TargetKind::Process | TargetKind::Http | TargetKind::Macos => {
                return Err(RunnerError::NoExecutorForTargetKind {
                    index: range.start,
                    kind,
                });
            }
        };
        counters.evaluated += range.len();
        verify_measures(&scenario.steps[range], &block_captures, &mut drift)?;
        captures.merge(block_captures);
    }

    if counters.evaluated == 0 {
        return Err(RunnerError::ScenarioNothingEvaluated {
            scenario: scenario.name.clone(),
            steps: scenario.steps.len(),
            skipped: counters.skipped,
        });
    }

    let verdict = drift.verdict();
    match (verdict, roots.baselines) {
        // A drifted run leaves the baseline alone: moving it is a human's call,
        // and `mirroir-run accept` is where that call is made.
        (RunVerdict::Drift, BaselineMode::Compare) => {
            append_findings(&review_root, &scenario.name, drift.findings())?;
            for finding in drift.findings() {
                warn!(scenario = %scenario.name, drift = %finding.summary(), "drift candidate");
            }
        }
        (RunVerdict::Pass | RunVerdict::Drift, BaselineMode::Accept)
        | (RunVerdict::Pass, BaselineMode::Compare) => {
            record_baseline(&review_root, &scenario.name, drift.into_observed())?;
        }
    }

    info!(
        file = %path.display(),
        name = %scenario.name,
        evaluated = counters.evaluated,
        skipped = counters.skipped,
        verdict = %verdict,
        "scenario run completed"
    );
    Ok(verdict)
}

/// The directory the runner keeps `.harness/` under: where it was invoked from.
fn review_root() -> Result<PathBuf> {
    env::current_dir().map_err(|source| RunnerError::Io {
        context: "resolve the current directory for the .harness review artifacts".to_owned(),
        source,
    })
}

/// Convenience: run a single scenario with no sample context. Used by
/// `mirroir-run --run-scenario <file>`.
///
/// # Errors
///
/// Same as [`run_scenario_with_context`].
pub async fn run_scenario(path: &Path, roots: ReplayRoots<'_>) -> Result<RunVerdict> {
    run_scenario_with_context(path, None, None, roots).await
}

/// What the scenario's steps contributed to its verdict.
#[derive(Debug, Default, Clone, Copy)]
struct Counters {
    evaluated: usize,
    skipped: usize,
}

/// Dispatch the runner-side steps at `indices`, in order, accumulating what
/// each contributed to the scenario verdict.
#[allow(clippy::too_many_arguments)]
async fn run_hooks(
    indices: &[usize],
    scenario: &Scenario,
    dispatch: &StepDispatch<'_>,
    processes: &mut ProcessRegistry,
    http: &HttpClient,
    captures: &RunCaptures,
    counters: &mut Counters,
    drift: &mut DriftSession,
) -> Result<()> {
    for &index in indices {
        let Some(step) = scenario.steps.get(index) else {
            continue;
        };
        info!(index, kind = step_kind(step), "dispatching step");
        match dispatch_step(index, step, dispatch, processes, http, captures, drift).await? {
            StepVerdict::Evaluated => counters.evaluated += 1,
            StepVerdict::NoVerdict => {}
            StepVerdict::Skipped => {
                counters.skipped += 1;
                info!(
                    index,
                    kind = step_kind(step),
                    "no replay dispatch for this step kind; skipping"
                );
            }
        }
    }
    Ok(())
}

/// Compile the scenario to a single Playwright spec, invoke it once in
/// `workspace`, and return what the run attached for the post-hooks.
///
/// The workspace survives the call: the trace, video, screenshot, and HTML
/// report a failing test leaves behind are the artifacts the debugging loop
/// opens, and the path is logged so a reader can find them.
async fn run_web_block(
    scenario: &Scenario,
    plan: &ScenarioPlan,
    source: &ScenarioSource,
    web_steps: usize,
    workspace: &PlaywrightWorkspace,
) -> Result<RunCaptures> {
    let spec = compile_scenario(scenario, plan, source)?;
    let runner = PlaywrightRunner::from_env()?;
    info!(
        web_steps,
        browsers = ?spec.browsers,
        workspace = %workspace.dir.display(),
        "dispatching the scenario's web block to Playwright"
    );
    let outcome = runner.run(&spec, workspace).await?;
    if !outcome.captures.page_errors.is_empty() || !outcome.captures.failed_requests.is_empty() {
        warn!(
            page_errors = ?outcome.captures.page_errors,
            failed_requests = ?outcome.captures.failed_requests,
            "the page reported errors during the run"
        );
    }
    info!(
        passed = outcome.verdict.passed,
        failed = outcome.verdict.failed,
        skipped = outcome.verdict.skipped,
        flaky = outcome.verdict.flaky,
        metrics = outcome.captures.metrics.len(),
        judge_captures = outcome.captures.judge.len(),
        cross_surface_captures = outcome.captures.cross_surface.len(),
        workspace = %workspace.dir.display(),
        "playwright invocation completed"
    );
    Ok(outcome.captures)
}

/// Write the scenario's `ios` block in mirroir-mcp's dialect, run it once with
/// `mirroir-mcp test` in `dir`, and return what the run attached — the block's
/// final screen among it — for the hooks that follow.
async fn run_ios_block(
    scenario: &Scenario,
    block: Range<usize>,
    dir: &Path,
) -> Result<RunCaptures> {
    let yaml = ios_block_yaml(&scenario.name, &scenario.steps, block.clone())?;
    let runner = MirroirMcpRunner::from_env()?;
    info!(
        ios_steps = block.len(),
        workspace = %dir.display(),
        "dispatching the scenario's ios block to mirroir-mcp"
    );
    let outcome = runner.run(&yaml, dir).await?;
    info!(
        passed = outcome.verdict.passed,
        failed = outcome.verdict.failed,
        metrics = outcome.captures.metrics.len(),
        cross_surface_captures = outcome.captures.cross_surface.len(),
        workspace = %dir.display(),
        "mirroir-mcp invocation completed"
    );
    Ok(outcome.captures)
}
