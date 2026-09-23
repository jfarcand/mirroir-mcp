// ABOUTME: `run_mirroir` orchestrator — ties discovery + resolve + lockfile + compose + run_sample.
// ABOUTME: Top-level entry point for bare `mirroir-run` and `mirroir-run --config <PATH>`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use tracing::{info, warn};

use crate::error::Result;
use crate::mirroir::compose::{ComposedSample, build_dir_for, compose_needed, compose_sample};
use crate::mirroir::discover::discover_mirroir_config;
use crate::mirroir::error::MirroirError;
use crate::mirroir::lock::{
    FreshnessVerdict, LockfileMode, check_lockfile_fresh, enforce_freshness, read_lockfile,
    regenerate_lockfile, write_lockfile,
};
use crate::mirroir::resolve::{ResolvedArchetype, resolve_archetype};
use crate::mirroir::run_io::{
    RunTotals, SampleStatus, SampleVerdict, load_and_apply_local_overrides, load_config,
    project_root_for_config, resolve_home_root, write_summary_full,
};
use crate::mirroir::run_selection::{
    ensure_selection_runs_something, select_set, set_filtered_entries,
};
use crate::parser::lockfile::Lockfile;
use crate::parser::mirroir::{
    ArchetypeRef, ArchetypeRefKind, MirroirConfig, PlanEntry, PlanEntrySource,
};
use crate::replay::{ReplayRoots, ScenarioSet, run_sample};
use crate::verdict::RunVerdict;

/// Knobs passed from the CLI into [`run_mirroir`].
#[derive(Debug, Clone, Copy)]
pub struct MirroirRunOptions {
    /// Lockfile freshness mode.
    pub lockfile_mode: LockfileMode,
    /// When true, compose into `.build/` and exit without replaying.
    pub compose_only: bool,
    /// When true, delete `.build/` before composing.
    pub recompose: bool,
    /// When true, skip compose (assume `.build/` is current).
    pub no_compose: bool,
    /// When true, skip loading `mirroir.local.yaml`.
    pub no_local: bool,
}

impl Default for MirroirRunOptions {
    fn default() -> Self {
        Self {
            lockfile_mode: LockfileMode::Default,
            compose_only: false,
            recompose: false,
            no_compose: false,
            no_local: false,
        }
    }
}

/// Run the full `.mirroir/` pipeline against `config_path`.
///
/// Behavior:
/// 1. Load `mirroir.yaml` + optional `mirroir.local.yaml`.
/// 2. Load `mirroir.lock` if present; otherwise treat as missing.
/// 3. Determine freshness; enforce per `options.lockfile_mode`. Auto-regenerate
///    in `Default` mode if stale.
/// 4. Resolve archetype references against `$HOME/.mirroir/skills/` and the
///    project's `.mirroir/archetypes/`.
/// 5. Resolve the scenario set and refuse the run outright when it would
///    replay nothing — see [`ensure_selection_runs_something`].
/// 6. Compose each selected plan entry (per archetype source files + plan
///    vars/boot) into `<repo>/.mirroir/.build/<entry.name>/`. Local entries
///    pass through; entries the set filtered out are recorded as `skipped`.
/// 7. For each composed sample (unless `--compose-only`): invoke
///    [`run_sample`] using the existing `ScenarioSet::MustPass` (or as
///    selected) machinery.
/// 8. Emit the summary JSON to `summary_path` and return
///    [`MirroirError::PlanFailures`] when any sample failed,
///    [`MirroirError::NothingReplayed`] when every selected entry was skipped,
///    or [`RunVerdict::Drift`] when none failed and at least one drifted.
///
/// # Errors
///
/// Returns any error from the underlying discovery / parse / resolve /
/// compose / replay layers, plus the lockfile-mode enforcement variants and
/// the selection refusals, [`MirroirError::SelectionMatchedNothing`],
/// [`MirroirError::PlanEmpty`], and [`MirroirError::NothingReplayed`].
pub async fn run_mirroir(
    config_path: &Path,
    set: Option<ScenarioSet>,
    options: MirroirRunOptions,
    summary_path: &Path,
    roots: ReplayRoots<'_>,
) -> Result<RunVerdict> {
    info!(config = %config_path.display(), "loading mirroir config");
    let mut config = load_config(config_path)?;
    let project_root = project_root_for_config(config_path)?;

    if !options.no_local {
        load_and_apply_local_overrides(&project_root, &mut config)?;
    }

    let home_root = resolve_home_root()?;

    let lockfile_path = config_path
        .parent()
        .map_or_else(|| PathBuf::from("mirroir.lock"), |p| p.join("mirroir.lock"));
    let lockfile_opt = ensure_lockfile(
        &lockfile_path,
        &config,
        &project_root,
        &home_root,
        options.lockfile_mode,
    )?;

    let resolved_archetypes =
        resolve_all_archetypes(&config, &project_root, &home_root, lockfile_opt.as_ref())?;

    let selected_set = select_set(config.default_set, set);
    ensure_selection_runs_something(config_path, &config.plan, selected_set)?;
    let composed = build_composed_samples(
        &config,
        &resolved_archetypes,
        &project_root,
        options.recompose,
        options.no_compose,
        selected_set.includes_nice_to_pass(),
    )?;

    // Entries the scenario set left out never reach compose or replay. They
    // are still the plan's, so they are reported as `skipped` rather than
    // dropped: a summary that lists fewer samples than the plan declares
    // cannot be read as an account of the plan. They sit in the plan's
    // `nice_to_pass` tier, so appending them after the composed entries is
    // plan order.
    let filtered: Vec<SampleVerdict> = set_filtered_entries(&config.plan, selected_set)
        .iter()
        .map(|entry| SampleVerdict {
            name: entry.name.clone(),
            verdict: SampleStatus::Skipped,
            error: Some(format!(
                "not selected by scenario set `{}`",
                selected_set.label()
            )),
        })
        .collect();
    let mut totals = RunTotals {
        skipped: filtered.len(),
        ..RunTotals::default()
    };
    let mut verdicts: Vec<SampleVerdict> = Vec::with_capacity(composed.len() + filtered.len());

    if options.compose_only {
        info!(
            samples = composed.len(),
            "compose-only mode; nothing replayed, so nothing passed"
        );
        // Every composed sample is `composed`, and the pass / fail / drift
        // counts are all zero: --compose-only builds the tree and stops, so no
        // scenario has a verdict yet. Counting the composed samples as passed
        // would report a green run for work that never executed. The
        // set-filtered entries are appended after them, still `skipped`.
        verdicts.extend(composed.iter().map(|(entry, _)| SampleVerdict {
            name: entry.name.clone(),
            verdict: SampleStatus::Composed,
            error: None,
        }));
        verdicts.extend(filtered);
        write_summary_full(summary_path, config_path, verdicts, totals)?;
        return Ok(RunVerdict::Pass);
    }

    for (entry, sample) in composed {
        if entry.skip {
            totals.skipped += 1;
            verdicts.push(SampleVerdict {
                name: entry.name.clone(),
                verdict: SampleStatus::Skipped,
                error: None,
            });
            continue;
        }
        info!(sample = %entry.name, dir = %sample.directory.display(), set = ?selected_set, "running sample");
        match run_sample(&sample.directory, selected_set, roots).await {
            Ok(RunVerdict::Pass) => {
                totals.passed += 1;
                verdicts.push(SampleVerdict {
                    name: entry.name.clone(),
                    verdict: SampleStatus::Pass,
                    error: None,
                });
            }
            Ok(RunVerdict::Drift) => {
                totals.drifted += 1;
                warn!(sample = %entry.name, "sample drifted; see .harness/drift-log.md");
                verdicts.push(SampleVerdict {
                    name: entry.name.clone(),
                    verdict: SampleStatus::Drift,
                    error: Some(
                        "structurally green; at least one drift metric moved past its threshold — see .harness/drift-log.md"
                            .to_owned(),
                    ),
                });
            }
            Err(err) => {
                totals.failed += 1;
                let msg = err.to_string();
                tracing::error!(sample = %entry.name, error = %msg, "sample failed");
                verdicts.push(SampleVerdict {
                    name: entry.name.clone(),
                    verdict: SampleStatus::Fail,
                    error: Some(msg),
                });
            }
        }
    }

    verdicts.extend(filtered);
    let total = verdicts.len();
    let failed = totals.failed;
    let drifted = totals.drifted;
    let replayed = totals.passed + failed + drifted;
    write_summary_full(summary_path, config_path, verdicts, totals)?;

    if failed > 0 {
        return Err(MirroirError::PlanFailures { failed, total }.into());
    }
    // The selection guard counts entries the set *selects*; an entry marked
    // `skip: true` is selected and then never replayed. When that covers every
    // selected entry, the run replayed nothing, and nothing is not a pass.
    if replayed == 0 {
        return Err(MirroirError::NothingReplayed { total }.into());
    }
    if drifted > 0 {
        return Ok(RunVerdict::Drift);
    }
    Ok(RunVerdict::Pass)
}

fn ensure_lockfile(
    lockfile_path: &Path,
    config: &MirroirConfig,
    project_root: &Path,
    home_root: &Path,
    mode: LockfileMode,
) -> Result<Option<Lockfile>> {
    if !lockfile_path.is_file() {
        match mode {
            // Frozen specifically guarantees a hermetic, network-free run, which
            // requires a committed lockfile — surface that distinctly from the
            // plain locked-but-missing case.
            LockfileMode::Frozen => {
                return Err(MirroirError::FrozenViolation {
                    reason: format!(
                        "lockfile {} is absent; --frozen requires a committed mirroir.lock (no regeneration, no network fetch)",
                        lockfile_path.display()
                    ),
                }.into());
            }
            LockfileMode::Locked => {
                return Err(MirroirError::LockfileMissing {
                    path: lockfile_path.to_path_buf(),
                }
                .into());
            }
            LockfileMode::Default => {
                let regenerated = regenerate_lockfile(config, project_root, home_root)?;
                write_lockfile(lockfile_path, &regenerated)?;
                warn!(
                    path = %lockfile_path.display(),
                    "lockfile was missing; wrote a fresh one"
                );
                return Ok(Some(regenerated));
            }
        }
    }
    let lockfile = read_lockfile(lockfile_path)?;
    let verdict = check_lockfile_fresh(config, &lockfile);
    if matches!(verdict, FreshnessVerdict::Stale { .. }) && matches!(mode, LockfileMode::Default) {
        let reasons = match &verdict {
            FreshnessVerdict::Stale { reasons } => reasons.join("; "),
            FreshnessVerdict::Fresh => String::new(),
        };
        let regenerated = regenerate_lockfile(config, project_root, home_root)?;
        write_lockfile(lockfile_path, &regenerated)?;
        warn!(reasons = %reasons, "regenerated stale lockfile");
        return Ok(Some(regenerated));
    }
    enforce_freshness(&verdict, mode, &lockfile, project_root, home_root)?;
    Ok(Some(lockfile))
}

fn resolve_all_archetypes(
    config: &MirroirConfig,
    project_root: &Path,
    home_root: &Path,
    lockfile: Option<&Lockfile>,
) -> Result<HashMap<String, ResolvedArchetype>> {
    let mut out = HashMap::new();
    for entry in config
        .plan
        .must_pass
        .iter()
        .chain(config.plan.nice_to_pass.iter())
    {
        if let PlanEntrySource::Archetypes { references } = &entry.source {
            // v1 enforces exactly one reference per entry (parser layer).
            if let Some(first) = references.first() {
                let ref_str = format_ref_display(first);
                let locked_version = lockfile
                    .and_then(|l| l.archetypes.iter().find(|a| a.reference == ref_str))
                    .and_then(|a| a.resolved.version.clone());
                let resolved =
                    resolve_archetype(first, project_root, home_root, locked_version.as_deref())?;
                out.insert(entry.name.clone(), resolved);
            }
        }
    }
    Ok(out)
}

fn format_ref_display(r: &ArchetypeRef) -> String {
    let base = match (&r.pack, r.kind) {
        (Some(p), _) => format!("{p}/{}", r.name),
        (None, ArchetypeRefKind::UserGlobal) => format!("user/{}", r.name),
        (None, ArchetypeRefKind::Pack | ArchetypeRefKind::ProjectLocal) => r.name.clone(),
    };
    match &r.version {
        Some(v) => format!("{base}@{v}"),
        None => base,
    }
}

fn build_composed_samples<'a>(
    config: &'a MirroirConfig,
    resolved_archetypes: &HashMap<String, ResolvedArchetype>,
    project_root: &Path,
    recompose: bool,
    no_compose: bool,
    include_nice_to_pass: bool,
) -> Result<Vec<(&'a PlanEntry, ComposedSample)>> {
    let mut out = Vec::new();
    let tiers: Vec<&[PlanEntry]> = if include_nice_to_pass {
        vec![
            config.plan.must_pass.as_slice(),
            config.plan.nice_to_pass.as_slice(),
        ]
    } else {
        vec![config.plan.must_pass.as_slice()]
    };
    for tier in tiers {
        for entry in tier {
            let resolved = resolved_archetypes.get(&entry.name);
            let composed =
                if no_compose && matches!(entry.source, PlanEntrySource::Archetypes { .. }) {
                    // Reuse existing .build/<entry.name>/ as-is.
                    let dir = build_dir_for(entry, project_root);
                    ComposedSample {
                        directory: dir,
                        local: false,
                    }
                } else if recompose {
                    compose_sample(entry, &config.env, resolved, project_root)?
                } else if let Some(res) = resolved {
                    if compose_needed(entry, res, project_root)? {
                        compose_sample(entry, &config.env, resolved, project_root)?
                    } else {
                        ComposedSample {
                            directory: build_dir_for(entry, project_root),
                            local: false,
                        }
                    }
                } else {
                    compose_sample(entry, &config.env, resolved, project_root)?
                };
            out.push((entry, composed));
        }
    }
    Ok(out)
}

/// Convenience: discover + run. Used by bare `mirroir-run` invocation.
///
/// # Errors
///
/// Propagates [`MirroirError::ConfigNotFound`] when discovery fails,
/// plus anything [`run_mirroir`] returns.
pub async fn run_mirroir_autodiscover(
    cwd: &Path,
    set: Option<ScenarioSet>,
    options: MirroirRunOptions,
    summary_path: &Path,
    roots: ReplayRoots<'_>,
) -> Result<RunVerdict> {
    let config_path = discover_mirroir_config(cwd)?;
    run_mirroir(&config_path, set, options, summary_path, roots).await
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::path::Path;
    use std::result::Result as StdResult;

    use super::ensure_lockfile;
    use crate::error::RunnerError;
    use crate::mirroir::error::MirroirError;
    use crate::mirroir::lock::LockfileMode;
    use crate::parser::mirroir::parse_mirroir_config;

    #[test]
    fn frozen_missing_lockfile_is_frozen_violation() -> StdResult<(), Box<dyn StdError>> {
        let cfg = parse_mirroir_config("test", "version: 1\nplan:\n  must_pass: []\n")?;
        let res = ensure_lockfile(
            Path::new("/nonexistent/mirroir.lock"),
            &cfg,
            Path::new("/tmp"),
            Path::new("/tmp"),
            LockfileMode::Frozen,
        );
        assert!(
            matches!(
                res,
                Err(RunnerError::Mirroir(MirroirError::FrozenViolation { .. }))
            ),
            "frozen + missing lockfile must be a frozen violation, got {res:?}"
        );
        Ok(())
    }

    #[test]
    fn locked_missing_lockfile_is_plain_missing() -> StdResult<(), Box<dyn StdError>> {
        let cfg = parse_mirroir_config("test", "version: 1\nplan:\n  must_pass: []\n")?;
        let res = ensure_lockfile(
            Path::new("/nonexistent/mirroir.lock"),
            &cfg,
            Path::new("/tmp"),
            Path::new("/tmp"),
            LockfileMode::Locked,
        );
        assert!(
            matches!(
                res,
                Err(RunnerError::Mirroir(MirroirError::LockfileMissing { .. }))
            ),
            "locked + missing lockfile must be MirroirLockfileMissing, got {res:?}"
        );
        Ok(())
    }
}
