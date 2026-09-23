// ABOUTME: `mirroir-run accept` — re-records every baseline from what this run observes.
// ABOUTME: Structurally refuses to run under CI: blessing drift is a human's signature, not a job step.

use std::env;
use std::path::{Path, PathBuf};

use clap::Args;
use tracing::info;

use crate::error::{Result, RunnerError};
use crate::mirroir::discover::discover_mirroir_config;
use crate::mirroir::lock::{regenerate_lockfile, write_lockfile};
use crate::mirroir::run::{MirroirRunOptions, run_mirroir};
use crate::mirroir::run_io::{load_config, project_root_for_config, resolve_home_root};
use crate::oracle::baseline::BaselineMode;
use crate::oracle::drift_log::clear_drift_log;
use crate::replay::{ReplayRoots, ScenarioSet, run_sample, run_scenario};
use crate::verdict::RunVerdict;

/// Environment variables whose mere presence means "this is a CI job".
///
/// The list is the union of what the major hosted runners export. Any one of
/// them present is enough: accept is a person saying the new output is correct,
/// and a machine cannot make that statement about its own run.
const CI_MARKERS: &[&str] = &[
    "CI",
    "CONTINUOUS_INTEGRATION",
    "BUILD_NUMBER",
    "GITHUB_ACTIONS",
    "GITLAB_CI",
    "BITBUCKET_BUILD_NUMBER",
    "BUILDKITE",
    "CIRCLECI",
    "TRAVIS",
    "TEAMCITY_VERSION",
    "JENKINS_URL",
    "TF_BUILD",
];

/// Where `accept` gets its scenarios from. Mirrors the ordinary run modes so
/// the thing being accepted is the thing that ran.
#[derive(Args, Debug)]
pub struct AcceptArgs {
    /// Accept one scenario YAML, run standalone (no sample context).
    #[arg(long, conflicts_with_all = ["sample", "config"])]
    pub run_scenario: Option<PathBuf>,

    /// Accept every scenario a sample directory's `SAMPLE.md` selects.
    #[arg(long, conflicts_with_all = ["run_scenario", "config"])]
    pub sample: Option<PathBuf>,

    /// Accept the whole `.mirroir/` plan at this `mirroir.yaml`. When none of
    /// the three is given, the plan is discovered by walking `cwd ↑`.
    #[arg(long, conflicts_with_all = ["run_scenario", "sample"])]
    pub config: Option<PathBuf>,

    /// Scenario set to accept. Defaults to the config's `default_set`, or
    /// `must_pass` for a sample directory.
    #[arg(long, value_enum)]
    pub scenarios: Option<ScenarioSet>,

    /// Path to the JSON report artifact for a `.mirroir/` plan run.
    #[arg(long, default_value = "mirroir-run-report.json")]
    pub report: PathBuf,

    /// Path to the mirroir-skills checkout (`drift-defaults.yaml` layer).
    #[arg(long, env = "MIRROIR_SKILLS")]
    pub skills: Option<PathBuf>,

    /// Skip loading `mirroir.local.yaml` while accepting a plan.
    #[arg(long)]
    pub no_local: bool,
}

/// Run the selected scenarios with the baselines in write mode, so what this
/// run observes replaces what the previous one recorded.
///
/// Four artifacts move, and they are the four a DRIFT verdict can point at:
///
/// 1. `.harness/last-green.json` — every judge score, judged response, and
///    `measure:` latency this run saw.
/// 2. each `judge.drift_baseline_file` — rewritten with the text this run
///    judged.
/// 3. each `cross_surface.captures[].to` — rewritten from the web page's
///    scrape or the iOS block's final screen. The other files a
///    `cross_surface:` step compares are committed and are named, not
///    overwritten.
/// 4. `.mirroir/mirroir.lock` — re-resolved and re-checksummed, which is how a
///    deliberate edit inside an archetype tree gets blessed for `--locked` and
///    `--frozen`.
///
/// `.harness/drift-log.md` is removed first: its rows are the review queue this
/// command is the answer to.
///
/// The result is a `git diff`. Nothing here is authoritative until a human
/// reads that diff and commits it.
///
/// # Errors
///
/// * [`RunnerError::AcceptRefusedInCi`] when a CI environment variable is set.
/// * [`RunnerError::Io`] when the working directory cannot be read.
/// * Anything the underlying replay, compose, or lockfile layers return.
pub async fn run_accept(args: &AcceptArgs) -> Result<RunVerdict> {
    refuse_under_ci()?;

    let review_root = env::current_dir().map_err(|source| RunnerError::Io {
        context: "resolve the current directory for the .harness review artifacts".to_owned(),
        source,
    })?;
    clear_drift_log(&review_root)?;

    let roots = ReplayRoots {
        skills: args.skills.as_deref(),
        baselines: BaselineMode::Accept,
    };

    let verdict = if let Some(path) = &args.run_scenario {
        info!(scenario = %path.display(), "accepting one scenario");
        run_scenario(path, roots).await?
    } else if let Some(dir) = &args.sample {
        info!(sample = %dir.display(), "accepting a sample");
        run_sample(dir, args.scenarios.unwrap_or(ScenarioSet::MustPass), roots).await?
    } else {
        accept_plan(args, roots).await?
    };

    println!("accept: baselines re-recorded from this run.");
    println!("accept: review the result with `git diff` before committing it.");
    Ok(verdict)
}

/// Accept a whole `.mirroir/` plan: re-record the lockfile, then replay every
/// selected sample with the baselines in write mode.
async fn accept_plan(args: &AcceptArgs, roots: ReplayRoots<'_>) -> Result<RunVerdict> {
    let config_path = if let Some(path) = &args.config {
        path.clone()
    } else {
        let cwd = env::current_dir().map_err(|source| RunnerError::Io {
            context: "read current working directory".to_owned(),
            source,
        })?;
        discover_mirroir_config(&cwd)?
    };
    accept_lockfile(&config_path)?;

    let options = MirroirRunOptions {
        no_local: args.no_local,
        ..MirroirRunOptions::default()
    };
    run_mirroir(&config_path, args.scenarios, options, &args.report, roots).await
}

/// Re-resolve every archetype the plan references and rewrite `mirroir.lock`
/// with the versions and tree checksums on disk right now.
///
/// This is the counterpart to the checksum verification in
/// [`crate::mirroir::lock::enforce_freshness`]: an edit inside a project-local
/// archetype makes `--locked` / `--frozen` refuse, and this is the command that
/// says the edit was intended.
fn accept_lockfile(config_path: &Path) -> Result<()> {
    let config = load_config(config_path)?;
    let project_root = project_root_for_config(config_path)?;
    let home_root = resolve_home_root()?;
    let lockfile_path = config_path
        .parent()
        .map_or_else(|| PathBuf::from("mirroir.lock"), |p| p.join("mirroir.lock"));
    let regenerated = regenerate_lockfile(&config, &project_root, &home_root)?;
    write_lockfile(&lockfile_path, &regenerated)?;
    info!(
        path = %lockfile_path.display(),
        archetypes = regenerated.archetypes.len(),
        "re-recorded the lockfile"
    );
    Ok(())
}

/// Refuse when any [`CI_MARKERS`] variable is present.
///
/// # Errors
///
/// [`RunnerError::AcceptRefusedInCi`] naming the variable that was found.
fn refuse_under_ci() -> Result<()> {
    for marker in CI_MARKERS {
        if env::var_os(marker).is_some() {
            return Err(RunnerError::AcceptRefusedInCi {
                variable: (*marker).to_owned(),
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), String>;

    /// Every marker is a plain uppercase name — the refusal reads them out of
    /// the environment verbatim, so a typo here would silently stop guarding.
    #[test]
    fn every_ci_marker_is_a_plausible_environment_variable() -> TestResult {
        for marker in CI_MARKERS {
            if marker.is_empty()
                || !marker
                    .chars()
                    .all(|c| c.is_ascii_uppercase() || c == '_' || c.is_ascii_digit())
            {
                return Err(format!("`{marker}` is not an environment variable name"));
            }
        }
        Ok(())
    }

    /// The list must at least cover the runner this repository's own CI uses.
    #[test]
    fn the_markers_cover_github_actions() -> TestResult {
        for required in ["CI", "GITHUB_ACTIONS"] {
            if !CI_MARKERS.contains(&required) {
                return Err(format!("`{required}` is not guarded against"));
            }
        }
        Ok(())
    }
}
