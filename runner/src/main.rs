// ABOUTME: Entry point for the mirroir-run binary — parses CLI args and dispatches to replay::.
// ABOUTME: Returns std::process::ExitCode; never panics, never uses anyhow!() or anyhow::Result.

//! `mirroir-run` is the cross-platform replayer for mirroir `SkillStep` YAML scenarios.
//!
//! It compiles web steps to Playwright `.spec.ts`, drives generic process and HTTP
//! targets natively in Rust, and evaluates LLM judge steps as a post-hook. See the
//! parent `AGENTS.md` for the Rust discipline this workspace enforces.

use std::env as std_env;
use std::error::Error as StdError;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::process::ExitCode;
use std::result::Result as StdResult;

use clap::{Parser, Subcommand, ValueEnum};
use tokio::runtime::Builder as TokioRuntimeBuilder;
use tracing::{error, info};
use tracing_subscriber::{EnvFilter, fmt};

mod accept;
mod baseline_coverage;
mod compile;
mod error;
mod mirroir;
mod oracle;
mod parser;
mod replay;
mod replay_cross_surface;
mod replay_dispatch;
mod replay_plan;
mod replay_sample;
mod replay_step;
mod replay_target;
mod scenario_set;
mod target;
mod verdict;

use crate::accept::{AcceptArgs, run_accept};
use crate::compile::emit::emit_playwright;
use crate::error::{Result, RunnerError};
use crate::mirroir::lock::LockfileMode;
use crate::mirroir::run::{MirroirRunOptions, run_mirroir, run_mirroir_autodiscover};
use crate::oracle::baseline::BaselineMode;
use crate::oracle::drift::{DriftVerdict, detect_drift};
use crate::parser::step::ResponseDriftConfig;
use crate::replay::{ReplayRoots, ScenarioSet, load_scenario, run_sample, run_scenario};
use crate::replay_plan::ScenarioPlan;
use crate::verdict::{EXIT_FAIL, RunVerdict};

/// Formats `--emit` can compile a scenario into.
#[derive(Copy, Clone, Debug, ValueEnum)]
enum EmitFormat {
    /// Playwright `.spec.ts` + `playwright.config.ts`, the pair `npx playwright
    /// test` consumes.
    Playwright,
}

/// Subcommands that are a mode of their own rather than a flag on a run.
#[derive(Subcommand, Debug)]
enum Command {
    /// Re-record every baseline from what this run observes, so a reviewed
    /// DRIFT becomes a `git diff` and the next run is green. Refuses to run
    /// in CI.
    Accept(AcceptArgs),
}

/// Cross-platform replayer for mirroir `SkillStep` YAML scenarios.
#[derive(Parser, Debug)]
#[command(name = "mirroir-run", version, about, long_about = None)]
#[command(args_conflicts_with_subcommands = true, subcommand_negates_reqs = true)]
struct Cli {
    /// The `accept` subcommand; absent for every ordinary run.
    #[command(subcommand)]
    command: Option<Command>,

    /// Path to a sample directory containing a `SAMPLE.md` contract.
    ///
    /// The runner loads `<dir>/SAMPLE.md`, picks the scenario set named by
    /// `--scenarios`, and runs each scenario YAML (resolved relative to the
    /// sample dir) through the full step dispatcher. Scenarios may use
    /// `spawn: { from: SAMPLE.md, ... }` to inherit boot defaults.
    #[arg(long, conflicts_with_all = ["validate", "run_scenario"])]
    sample: Option<PathBuf>,

    /// Validate a single scenario YAML file and exit.
    ///
    /// Loads the file, applies `${VAR}` substitution from the process
    /// environment, parses as a `Scenario`, builds its execution plan, and
    /// reports the step count. The plan is what rejects a scenario whose web
    /// steps are split by a runner-side step — that shape would need a second
    /// browser context and cannot replay as written. Useful for CI gating of
    /// scenarios authored by the recorder.
    #[arg(long, conflicts_with_all = ["sample", "run_scenario"])]
    validate: Option<PathBuf>,

    /// Execute a single scenario YAML file end-to-end (no sample context).
    ///
    /// Process, HTTP, web (via Playwright), judge, and report steps all
    /// dispatch; a scenario that evaluates none of them is a failure, not a
    /// pass. Scenarios that use `spawn: { from: SAMPLE.md }` are rejected —
    /// use `--sample` mode for those.
    #[arg(long, conflicts_with_all = ["sample", "validate", "emit"])]
    run_scenario: Option<PathBuf>,

    /// Compile to disk without running: `--emit playwright <path>` writes the
    /// spec + `playwright.config.ts` for every scenario `<path>` selects into
    /// `target/playwright/`.
    ///
    /// `<path>` is a sample directory (its `SAMPLE.md` picks the scenario list,
    /// narrowed by `--scenarios`) or a single scenario YAML. The directories it
    /// writes are the ones a run executes, so the reviewed spec is the spec
    /// that runs.
    #[arg(long, value_enum, value_name = "FORMAT", requires = "path",
          conflicts_with_all = ["sample", "validate", "run_scenario", "diff_text"])]
    emit: Option<EmitFormat>,

    /// Sample directory or scenario YAML to compile. Only meaningful with
    /// `--emit`.
    #[arg(value_name = "PATH", requires = "emit")]
    path: Option<PathBuf>,

    /// Compute drift between two text files. Prints fingerprint similarity
    /// and normalized Levenshtein distance, with a Drift / Match verdict at
    /// the threshold given by `--levenshtein-threshold` (default 0.2).
    ///
    /// Exits 0 on Match and 65 on Drift — the same code every drifted run
    /// returns. Takes two paths: baseline and current.
    #[arg(
        long,
        num_args = 2,
        value_names = ["BASELINE", "CURRENT"],
        conflicts_with_all = ["sample", "validate", "run_scenario", "emit"],
    )]
    diff_text: Option<Vec<PathBuf>>,

    /// Levenshtein threshold for `--diff-text` mode. Values above this are
    /// classified as Drift; values at or below are Match.
    #[arg(long, default_value_t = 0.2)]
    levenshtein_threshold: f64,

    /// Scenario set to run. When omitted, the `.mirroir/` pipeline honors the
    /// config's `default_set` (falling back to `must_pass`); the `--sample`
    /// path defaults to `must_pass`.
    #[arg(long, value_enum)]
    scenarios: Option<ScenarioSet>,

    /// Path to the JSON report artifact.
    #[arg(long, default_value = "mirroir-run-report.json")]
    report: PathBuf,

    /// Path to the mirroir-skills checkout.
    ///
    /// Supplies the global layer of the drift threshold hierarchy: the runner
    /// reads `<skills>/drift-defaults.yaml` when the sample directory does not
    /// carry one of its own.
    #[arg(long, env = "MIRROIR_SKILLS")]
    skills: Option<PathBuf>,

    /// Path to a `.mirroir/mirroir.yaml` file. Overrides cwd-based discovery.
    ///
    /// When unset, a bare `mirroir-run` invocation walks `cwd ↑` looking for
    /// `<ancestor>/.mirroir/mirroir.yaml` and drives the entire `.mirroir/`
    /// pipeline from that file: parse, archetype resolution against
    /// `~/.mirroir/skills/`, lockfile freshness check, compose into
    /// `.mirroir/.build/`, then replay each sample through the existing
    /// `run_sample` machinery.
    #[arg(long, conflicts_with_all = ["sample", "validate", "run_scenario", "emit", "diff_text"])]
    config: Option<PathBuf>,

    /// Skip loading `mirroir.local.yaml` (CI-friendly).
    #[arg(long)]
    no_local: bool,

    /// Compose `.mirroir/.build/` and exit without replaying.
    #[arg(long, conflicts_with = "no_compose")]
    compose_only: bool,

    /// Delete `.mirroir/.build/` and recompose from scratch before replaying.
    #[arg(long, conflicts_with = "no_compose")]
    recompose: bool,

    /// Skip compose; reuse the existing `.mirroir/.build/` tree as-is.
    #[arg(long)]
    no_compose: bool,

    /// CI gate: error when `mirroir.lock` is missing or stale vs `mirroir.yaml`.
    #[arg(long, conflicts_with = "frozen")]
    locked: bool,

    /// Like `--locked` plus forbid any network fetch (hermetic offline mode).
    #[arg(long)]
    frozen: bool,
}

fn main() -> ExitCode {
    if let Err(init_err) = init_tracing() {
        eprintln!("mirroir-run: failed to initialize tracing: {init_err}");
        return ExitCode::FAILURE;
    }

    let cli = Cli::parse();
    info!(
        sample = ?cli.sample,
        validate = ?cli.validate,
        run_scenario = ?cli.run_scenario,
        emit = ?cli.emit,
        scenarios = ?cli.scenarios,
        report = ?cli.report,
        skills = ?cli.skills,
        "mirroir-run starting"
    );

    let runtime = match TokioRuntimeBuilder::new_multi_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(err) => {
            eprintln!("mirroir-run: failed to build tokio runtime: {err}");
            return ExitCode::FAILURE;
        }
    };

    match runtime.block_on(run(&cli)) {
        Ok(verdict) => {
            info!(verdict = %verdict, exit_code = verdict.exit_code(), "mirroir-run finished");
            ExitCode::from(verdict.exit_code())
        }
        Err(e) => {
            error!(error = %e, "mirroir-run failed");
            ExitCode::from(EXIT_FAIL)
        }
    }
}

/// Top-level fallible entry point. All module-level dispatch hangs off this function
/// so the binary's `main()` only handles the verdict → `ExitCode` translation.
///
/// The three states are distinguishable from the shell: `Ok(RunVerdict::Pass)`
/// exits 0, `Ok(RunVerdict::Drift)` exits 65, and any `Err` exits 1.
async fn run(cli: &Cli) -> Result<RunVerdict> {
    if let Some(Command::Accept(args)) = &cli.command {
        return run_accept(args).await;
    }

    let roots = ReplayRoots {
        skills: cli.skills.as_deref(),
        baselines: BaselineMode::Compare,
    };
    if let Some(path) = &cli.validate {
        let scenario = load_scenario(path)?;
        let plan = ScenarioPlan::build(&scenario.steps)?;
        info!(
            file = %path.display(),
            name = %scenario.name,
            steps = scenario.steps.len(),
            pre_hooks = plan.pre().len(),
            web_block = ?plan.web(),
            post_hooks = plan.post().len(),
            tags = ?scenario.tags,
            "scenario validated"
        );
        return Ok(RunVerdict::Pass);
    }

    if let Some(path) = &cli.run_scenario {
        return run_scenario(path, roots).await;
    }

    if let Some(format) = cli.emit {
        return run_emit(cli, format).await;
    }

    if let Some(paths) = &cli.diff_text {
        return run_diff_text(paths, cli.levenshtein_threshold);
    }

    if let Some(dir) = &cli.sample {
        return run_sample(dir, cli.scenarios.unwrap_or(ScenarioSet::MustPass), roots).await;
    }

    // .mirroir/ pipeline — explicit --config OR bare invocation with autodiscovery.
    let mirroir_options = MirroirRunOptions {
        lockfile_mode: lockfile_mode_from_cli(cli),
        compose_only: cli.compose_only,
        recompose: cli.recompose,
        no_compose: cli.no_compose,
        no_local: cli.no_local,
    };
    if let Some(path) = &cli.config {
        return run_mirroir(path, cli.scenarios, mirroir_options, &cli.report, roots).await;
    }

    let cwd = std_env::current_dir().map_err(|source| RunnerError::Io {
        context: "read current working directory".to_owned(),
        source,
    })?;
    run_mirroir_autodiscover(&cwd, cli.scenarios, mirroir_options, &cli.report, roots).await
}

/// Implements `mirroir-run --emit <format> <path>`.
///
/// Prints one line per emitted spec so the paths are pipeable, and returns
/// [`RunVerdict::Pass`] — compiling is not a verdict about the system under
/// test, and a compile failure is an `Err` like any other.
async fn run_emit(cli: &Cli, format: EmitFormat) -> Result<RunVerdict> {
    let Some(target) = cli.path.as_deref() else {
        return Err(RunnerError::Io {
            context: "--emit needs a sample directory or scenario file".to_owned(),
            source: io::Error::new(io::ErrorKind::InvalidInput, "missing PATH"),
        });
    };
    let cwd = std_env::current_dir().map_err(|source| RunnerError::Io {
        context: "read current working directory".to_owned(),
        source,
    })?;
    let EmitFormat::Playwright = format;
    let emitted =
        emit_playwright(target, cli.scenarios.unwrap_or(ScenarioSet::MustPass), &cwd).await?;
    for scenario in &emitted {
        println!("{}", scenario.spec.display());
        println!("{}", scenario.config.display());
    }
    info!(
        target = %target.display(),
        scenarios = emitted.len(),
        "emitted playwright workspaces"
    );
    Ok(RunVerdict::Pass)
}

fn lockfile_mode_from_cli(cli: &Cli) -> LockfileMode {
    if cli.frozen {
        LockfileMode::Frozen
    } else if cli.locked {
        LockfileMode::Locked
    } else {
        LockfileMode::Default
    }
}

/// Implements `mirroir-run --diff-text <baseline> <current>`.
///
/// Reads both files, computes drift, prints a one-line verdict to stdout, and
/// returns [`RunVerdict::Drift`] when drift exceeded the configured threshold —
/// which the binary turns into exit code 65, the same code every drifted run
/// uses.
fn run_diff_text(paths: &[PathBuf], threshold: f64) -> Result<RunVerdict> {
    // Clap enforces num_args = 2; defensive read.
    let [baseline_path, current_path] = match paths {
        [b, c] => [b.as_path(), c.as_path()],
        _ => {
            return Err(RunnerError::Io {
                context: "--diff-text requires exactly two paths".to_owned(),
                source: io::Error::new(io::ErrorKind::InvalidInput, "expected two paths"),
            });
        }
    };
    let baseline = fs::read_to_string(baseline_path).map_err(|source| RunnerError::Io {
        context: format!("read baseline {}", baseline_path.display()),
        source,
    })?;
    let current = fs::read_to_string(current_path).map_err(|source| RunnerError::Io {
        context: format!("read current {}", current_path.display()),
        source,
    })?;
    let config = ResponseDriftConfig {
        max_levenshtein_pct: threshold,
    };
    let verdict = detect_drift(&baseline, &current, &config);
    match verdict {
        DriftVerdict::Match {
            fingerprint_similarity,
            levenshtein_pct,
        } => {
            println!(
                "MATCH fingerprint={fingerprint_similarity:.3} levenshtein={levenshtein_pct:.3}"
            );
            Ok(RunVerdict::Pass)
        }
        DriftVerdict::Drift {
            fingerprint_similarity,
            levenshtein_pct,
            reason,
        } => {
            println!(
                "DRIFT fingerprint={fingerprint_similarity:.3} levenshtein={levenshtein_pct:.3} reason={reason}"
            );
            Ok(RunVerdict::Drift)
        }
    }
}

fn init_tracing() -> StdResult<(), Box<dyn StdError + Send + Sync>> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    fmt::fmt().with_env_filter(filter).try_init()
}
