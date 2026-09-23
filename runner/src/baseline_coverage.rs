// ABOUTME: The sample-level guard that every committed iOS baseline is compared by a scenario the SAMPLE.md declares.
// ABOUTME: An orphan `baselines/*.ios.txt` is read by nothing, so the sample reports green with its parity gate absent.

use std::collections::HashSet;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use tracing::{info, warn};

use crate::error::{Result, RunnerError};
use crate::parser::sample::SampleManifest;
use crate::parser::step::SkillStep;
use crate::replay::load_scenario_with_extras;
use crate::scenario_set::ScenarioSet;

/// Directory a sample keeps its baselines in. Read flat: the layout a
/// `SAMPLE.md` declares is `baselines/<flow>.ios.txt`, so a capture filed in a
/// subdirectory of it is not the artifact this guard accounts for.
const BASELINES_DIR: &str = "baselines";

/// Suffix marking a baseline captured on a surface this binary drives no
/// executor for: mirroir-mcp's `generate_skill` writes it against a connected
/// iPhone, and the runner can only ever read it. Nothing in a run produces or
/// refreshes such a file, so the single thing that gives it an effect is a
/// `cross_surface:` step naming it.
///
/// One spelling, everywhere — the samples, the docs and this constant name the
/// same artifact class the same way, so a capture cannot land outside the guard
/// by being spelled differently.
const IOS_BASELINE_SUFFIX: &str = ".ios.txt";

/// Refuse a sample that commits an iOS baseline no scenario it declares
/// compares.
///
/// Two separate questions live here, and only one of them is the sample's
/// fault. A `.ios.txt` that no scenario in any tier of `manifest` names is an
/// orphan: nothing in the sample ever reads it, and no invocation can change
/// that — it is refused. A baseline a declared scenario does name, on a run
/// whose `set` left that scenario out, is checked by the sample and not by this
/// run: that is the tier the invocation chose, so it is logged and the run
/// proceeds. Refusing it instead would make `--scenarios nice-to-pass`
/// unrunnable against every app carrying a `must_pass` parity flow.
///
/// `selected` is the scenario list the run will drive, relative to
/// `sample_dir`, as [`crate::scenario_set::select_scenarios`] returned it — a
/// subset of what `manifest` declares.
///
/// A sample with no `baselines/` directory — every sample that declares no
/// cross-surface parity — costs one failed directory read and loads no
/// scenario at all.
///
/// The web half of a parity gate is written by the run that checks it, so a
/// stale one cannot go unnoticed; `.ios.txt` is the class of file that can.
///
/// # Errors
///
/// * [`RunnerError::SampleBaselineUnreferenced`] when a `baselines/*.ios.txt`
///   is named in no declared scenario's `cross_surface.response_files`.
/// * [`RunnerError::Io`] when `baselines/` exists and cannot be read.
/// * Anything [`load_scenario_with_extras`] returns for a *selected* scenario —
///   a scenario that will not parse cannot vouch for a baseline either. A
///   declared scenario the set leaves out is read here and nowhere else, so one
///   that will not parse vouches for nothing rather than failing a run that was
///   never going to read it.
pub fn ensure_ios_baselines_are_referenced(
    sample_dir: &Path,
    manifest: &SampleManifest,
    set: ScenarioSet,
    selected: &[PathBuf],
) -> Result<()> {
    let baselines = ios_baselines(&sample_dir.join(BASELINES_DIR))?;
    if baselines.is_empty() {
        return Ok(());
    }

    let declared = declared_scenarios(manifest);
    let compared = compared_files(sample_dir, &declared, selected)?;
    for baseline in &baselines {
        let key = resolve(baseline);
        if compared.by_selected.contains(&key) {
            continue;
        }
        if compared.by_declared.contains(&key) {
            warn!(
                dir = %sample_dir.display(),
                baseline = %relative_name(baseline),
                selected = set.label(),
                "iOS baseline is compared only by scenarios this set leaves out; this run does not check that parity gate"
            );
            continue;
        }
        return Err(RunnerError::SampleBaselineUnreferenced {
            sample_dir: sample_dir.to_path_buf(),
            baseline: relative_name(baseline),
            scenarios: declared.len(),
        });
    }
    info!(
        dir = %sample_dir.display(),
        baselines = baselines.len(),
        scenarios = declared.len(),
        "every iOS baseline in the sample is compared by a scenario the SAMPLE.md declares"
    );
    Ok(())
}

/// Every scenario the manifest declares, `must_pass` first. `selected` is
/// always one of these lists or their concatenation, so walking this covers the
/// selection too — the scenarios are loaded once, whichever set is in effect.
fn declared_scenarios(manifest: &SampleManifest) -> Vec<&Path> {
    let scenarios = &manifest.session.scenarios;
    scenarios
        .must_pass
        .iter()
        .chain(scenarios.nice_to_pass.iter())
        .map(PathBuf::as_path)
        .collect()
}

/// Every `*.ios.txt` sitting in `dir`, sorted so a refusal names the same file
/// on every filesystem. A missing directory yields none.
fn ios_baselines(dir: &Path) -> Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(source) if source.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(source) => {
            return Err(RunnerError::Io {
                context: format!("read sample baselines directory {}", dir.display()),
                source,
            });
        }
    };

    let mut found = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|source| RunnerError::Io {
            context: format!("walk sample baselines directory {}", dir.display()),
            source,
        })?;
        let path = entry.path();
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(IOS_BASELINE_SUFFIX))
        {
            found.push(path);
        }
    }
    found.sort();
    Ok(found)
}

/// What the sample's scenarios compare, keyed by [`resolve`] and split by
/// whether this run drives the scenario doing the comparing.
struct ComparedFiles {
    /// Compared by a scenario the `SAMPLE.md` declares, in either tier.
    by_declared: HashSet<PathBuf>,
    /// Compared by one of the scenarios this run selected — always a subset of
    /// [`Self::by_declared`].
    by_selected: HashSet<PathBuf>,
}

/// Every file the sample's `declared` scenarios compare, noting which of them
/// the run's `selected` list drives.
///
/// The scenarios are loaded through [`load_scenario_with_extras`] with the
/// same `MIRROIR_SAMPLE_DIR` extra [`crate::replay::run_scenario_with_context`]
/// passes, so a `${MIRROIR_SAMPLE_DIR}/baselines/…` entry resolves here exactly
/// as it will when the step runs.
///
/// Only top-level steps count: a `cross_surface:` nested in a `condition:`
/// branch dispatches as [`crate::replay_step::StepVerdict::Skipped`], so it
/// compares nothing and vouches for nothing.
fn compared_files(
    sample_dir: &Path,
    declared: &[&Path],
    selected: &[PathBuf],
) -> Result<ComparedFiles> {
    let extras = [("MIRROIR_SAMPLE_DIR", sample_dir.display().to_string())];
    let running: HashSet<&Path> = selected.iter().map(PathBuf::as_path).collect();
    let mut compared = ComparedFiles {
        by_declared: HashSet::new(),
        by_selected: HashSet::new(),
    };
    for scenario_rel in declared {
        let is_selected = running.contains(scenario_rel);
        let loaded = load_scenario_with_extras(&sample_dir.join(scenario_rel), &extras);
        let scenario = match loaded {
            Ok(scenario) => scenario,
            Err(err) if is_selected => return Err(err),
            Err(_) => continue,
        };
        for step in &scenario.steps {
            if let SkillStep::CrossSurface(args) = step {
                for file in &args.response_files {
                    let key = resolve(Path::new(file));
                    if is_selected {
                        compared.by_selected.insert(key.clone());
                    }
                    compared.by_declared.insert(key);
                }
            }
        }
    }
    Ok(compared)
}

/// The comparison key for a path: its canonical form when the file is on disk,
/// the path as written when it is not — a `response_files` entry may name a
/// capture the run has yet to write.
///
/// Both sides of the check go through this one function, so the directory
/// listing and a scenario's entry agree on what "the same file" means.
fn resolve(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// How a refusal names the baseline: `baselines/<file>`, since the message
/// already carries the sample directory.
fn relative_name(baseline: &Path) -> String {
    baseline.file_name().map_or_else(
        || baseline.display().to_string(),
        |name| format!("{BASELINES_DIR}/{}", name.to_string_lossy()),
    )
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use tempfile::TempDir;

    use super::*;
    use crate::parser::sample::{Boot, SAMPLE_SCHEMA_VERSION, Scenarios, Session};

    type TestResult = StdResult<(), Box<dyn StdError>>;

    /// A sample declaring `scenarios/parity.yaml` in `must_pass` — it compares
    /// `referenced.ios.txt` against a web capture the run writes — and
    /// `scenarios/smoke.yaml` in `nice_to_pass`, which compares nothing. Extra
    /// `baselines/` files are planted by name.
    fn plant_sample(extra_baselines: &[&str]) -> StdResult<TempDir, Box<dyn StdError>> {
        let tmp = TempDir::new()?;
        let dir = tmp.path();
        fs::create_dir_all(dir.join("scenarios"))?;
        fs::create_dir_all(dir.join(BASELINES_DIR))?;
        fs::write(
            dir.join(BASELINES_DIR).join("referenced.ios.txt"),
            "Order total 42 dollars\n",
        )?;
        for name in extra_baselines {
            fs::write(
                dir.join(BASELINES_DIR).join(name),
                "Order total 42 dollars\n",
            )?;
        }
        fs::write(
            dir.join("scenarios").join("parity.yaml"),
            concat!(
                "version: 1\n",
                "name: parity\n",
                "steps:\n",
                "  - cross_surface:\n",
                "      response_files:\n",
                "        - \"${MIRROIR_SAMPLE_DIR}/baselines/referenced.web.txt\"\n",
                "        - \"${MIRROIR_SAMPLE_DIR}/baselines/referenced.ios.txt\"\n",
                "      min_similarity: 0.5\n",
            ),
        )?;
        fs::write(
            dir.join("scenarios").join("smoke.yaml"),
            "version: 1\nname: smoke\nsteps:\n  - report: pass\n",
        )?;
        Ok(tmp)
    }

    /// The manifest [`plant_sample`] writes its tree for.
    fn planted_manifest() -> SampleManifest {
        SampleManifest {
            version: SAMPLE_SCHEMA_VERSION,
            name: None,
            description: None,
            session: Session {
                boot: Boot {
                    command: String::new(),
                    cwd: None,
                    env: HashMap::new(),
                    timeout_s: None,
                },
                scenarios: Scenarios {
                    must_pass: vec![PathBuf::from("scenarios/parity.yaml")],
                    nice_to_pass: vec![PathBuf::from("scenarios/smoke.yaml")],
                },
                boot_once: false,
                boot_ready_port: None,
                boot_ready_timeout_s: None,
            },
        }
    }

    fn parity_scenario() -> Vec<PathBuf> {
        vec![PathBuf::from("scenarios/parity.yaml")]
    }

    fn smoke_scenario() -> Vec<PathBuf> {
        vec![PathBuf::from("scenarios/smoke.yaml")]
    }

    /// The gap this module closes: drop a `.ios.txt` into a sample, name it
    /// from no scenario, and every other gate stays silent — the file is read
    /// by nothing, so nothing can notice it did not agree with anything.
    #[test]
    fn an_orphan_ios_baseline_is_refused_by_name() -> TestResult {
        let tmp = plant_sample(&["checkout.ios.txt"])?;
        let res = ensure_ios_baselines_are_referenced(
            tmp.path(),
            &planted_manifest(),
            ScenarioSet::MustPass,
            &parity_scenario(),
        );
        let Err(RunnerError::SampleBaselineUnreferenced {
            baseline,
            scenarios,
            ..
        }) = res
        else {
            return Err(format!("expected SampleBaselineUnreferenced, got {res:?}").into());
        };
        if baseline != "baselines/checkout.ios.txt" {
            return Err(format!("the refusal names the wrong file: {baseline}").into());
        }
        if scenarios != 2 {
            return Err(format!(
                "the refusal counts the selection rather than what the manifest declares: {scenarios}"
            )
            .into());
        }
        Ok(())
    }

    /// The companion: the baseline the scenario does name is accounted for. A
    /// guard that refused every sample carrying a `.ios.txt` would pass the
    /// test above and fail this one.
    #[test]
    fn a_baseline_named_by_a_selected_scenario_is_accepted() -> TestResult {
        let tmp = plant_sample(&[])?;
        ensure_ios_baselines_are_referenced(
            tmp.path(),
            &planted_manifest(),
            ScenarioSet::MustPass,
            &parity_scenario(),
        )?;
        Ok(())
    }

    /// The same tree, run with the set that leaves out the scenario naming the
    /// baseline. The sample is well formed — `must_pass` compares the capture —
    /// so the informational tier stays runnable: the run logs that it is not
    /// checking that gate instead of refusing a sample nothing is wrong with.
    #[test]
    fn a_baseline_named_by_an_unselected_tier_is_not_an_orphan() -> TestResult {
        let tmp = plant_sample(&[])?;
        ensure_ios_baselines_are_referenced(
            tmp.path(),
            &planted_manifest(),
            ScenarioSet::NiceToPass,
            &smoke_scenario(),
        )?;
        Ok(())
    }

    /// A declared scenario the set leaves out is read here and nowhere else, so
    /// one that will not parse compares nothing rather than failing a run that
    /// was never going to read it. The selected scenario still vouches.
    #[test]
    fn an_unselected_scenario_that_will_not_parse_does_not_fail_the_run() -> TestResult {
        let tmp = plant_sample(&[])?;
        fs::write(
            tmp.path().join("scenarios").join("smoke.yaml"),
            "version: 1\nname: smoke\nsteps: [[[\n",
        )?;
        ensure_ios_baselines_are_referenced(
            tmp.path(),
            &planted_manifest(),
            ScenarioSet::MustPass,
            &parity_scenario(),
        )?;
        Ok(())
    }

    /// Every sample that declares no cross-surface parity: no `baselines/`
    /// directory, nothing to account for. The selected scenario named here does
    /// not exist, so a check that read one before looking for baselines would
    /// fail on the read.
    #[test]
    fn a_sample_without_a_baselines_directory_reads_no_scenario() -> TestResult {
        let tmp = TempDir::new()?;
        ensure_ios_baselines_are_referenced(
            tmp.path(),
            &planted_manifest(),
            ScenarioSet::All,
            &parity_scenario(),
        )?;
        Ok(())
    }

    /// A `baselines/` directory holding only files the runner itself writes is
    /// not this guard's business: the run that checks a `.web.txt` is the run
    /// that wrote it.
    #[test]
    fn a_baselines_directory_with_no_ios_capture_reads_no_scenario() -> TestResult {
        let tmp = TempDir::new()?;
        fs::create_dir_all(tmp.path().join(BASELINES_DIR))?;
        fs::write(
            tmp.path().join(BASELINES_DIR).join("judge.txt"),
            "the recorded judge response\n",
        )?;
        ensure_ios_baselines_are_referenced(
            tmp.path(),
            &planted_manifest(),
            ScenarioSet::All,
            &parity_scenario(),
        )?;
        Ok(())
    }
}
