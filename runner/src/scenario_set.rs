// ABOUTME: Which scenarios of a `SAMPLE.md` a run drives — the `ScenarioSet` enum and its selection.
// ABOUTME: The selection itself refuses to hand back an empty list, so no caller can replay nothing and call it a pass.

use std::path::{Path, PathBuf};

use clap::ValueEnum;

use crate::error::{Result, RunnerError};
use crate::parser::sample::SampleManifest;

/// Which set of scenarios from a `SAMPLE.md` session block to drive.
#[derive(Copy, Clone, Debug, ValueEnum)]
pub enum ScenarioSet {
    /// `session.scenarios.must_pass` — these must pass for the sample to be considered green.
    MustPass,
    /// `session.scenarios.nice_to_pass` — informational; FAIL doesn't block the sample.
    NiceToPass,
    /// Both `must_pass` and `nice_to_pass`.
    All,
}

impl ScenarioSet {
    /// The `mirroir.yaml` / `SAMPLE.md` spelling of the set, for error and
    /// report messages.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::MustPass => "must_pass",
            Self::NiceToPass => "nice_to_pass",
            Self::All => "all",
        }
    }

    /// True when `self` covers the `nice_to_pass` tier as well — of a
    /// `SAMPLE.md`'s scenarios, and of a `.mirroir/` plan's entries.
    ///
    /// `NiceToPass` covers both tiers of a plan on purpose: the set narrows
    /// which scenarios inside each sample run, and a `must_pass` plan entry
    /// can still declare `nice_to_pass` scenarios of its own.
    #[must_use]
    pub const fn includes_nice_to_pass(self) -> bool {
        matches!(self, Self::NiceToPass | Self::All)
    }
}

/// Build the ordered list of scenario paths the user asked for: the scenario
/// list `set` names in `manifest`, in declaration order.
///
/// A set that names no scenario at all is refused rather than returned as an
/// empty list. A sample whose scenarios all sit in a tier the set leaves out
/// replays nothing, and a run that replayed nothing is not a pass — the same
/// refusal [`crate::mirroir::run_selection::ensure_selection_runs_something`]
/// makes one layer up, over the plan's own tiers.
///
/// # Errors
///
/// * [`RunnerError::SampleSetMatchedNothing`] when the manifest declares
///   scenarios, all of them in tiers `set` leaves out. The invocation is at
///   fault: naming a set that covers those tiers runs them.
/// * [`RunnerError::SampleDeclaresNoScenarios`] when the manifest declares no
///   scenario in any tier. No set can rescue that; the `SAMPLE.md` itself
///   declares no work.
pub fn select_scenarios(
    sample_dir: &Path,
    manifest: &SampleManifest,
    set: ScenarioSet,
) -> Result<Vec<PathBuf>> {
    let scenarios = &manifest.session.scenarios;
    let selected = match set {
        ScenarioSet::MustPass => scenarios.must_pass.clone(),
        ScenarioSet::NiceToPass => scenarios.nice_to_pass.clone(),
        ScenarioSet::All => {
            let mut combined = scenarios.must_pass.clone();
            combined.extend(scenarios.nice_to_pass.iter().cloned());
            combined
        }
    };
    if !selected.is_empty() {
        return Ok(selected);
    }

    let total = scenarios.must_pass.len() + scenarios.nice_to_pass.len();
    if total == 0 {
        return Err(RunnerError::SampleDeclaresNoScenarios {
            sample_dir: sample_dir.to_path_buf(),
        });
    }
    let mut populated: Vec<&str> = Vec::with_capacity(2);
    if !scenarios.must_pass.is_empty() {
        populated.push("must_pass");
    }
    if !scenarios.nice_to_pass.is_empty() {
        populated.push("nice_to_pass");
    }
    Err(RunnerError::SampleSetMatchedNothing {
        sample_dir: sample_dir.to_path_buf(),
        selected: set.label().to_owned(),
        total,
        populated: populated.join(", "),
    })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};

    use super::{ScenarioSet, select_scenarios};
    use crate::error::RunnerError;
    use crate::parser::sample::{Boot, SampleManifest, Scenarios, Session};
    use crate::parser::version::ArtifactKind;

    fn manifest(must_pass: &[&str], nice_to_pass: &[&str]) -> SampleManifest {
        SampleManifest {
            version: ArtifactKind::Sample.current(),
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
                    must_pass: must_pass.iter().map(PathBuf::from).collect(),
                    nice_to_pass: nice_to_pass.iter().map(PathBuf::from).collect(),
                },
                boot_once: false,
                boot_ready_port: None,
                boot_ready_timeout_s: None,
            },
        }
    }

    fn sample_dir() -> &'static Path {
        Path::new("/repo/.mirroir/samples/demo")
    }

    #[test]
    fn select_scenarios_all_concatenates_in_order() -> Result<(), RunnerError> {
        let manifest = manifest(&["a.yaml", "b.yaml"], &["c.yaml"]);
        let all = select_scenarios(sample_dir(), &manifest, ScenarioSet::All)?;
        assert_eq!(
            all,
            vec![
                PathBuf::from("a.yaml"),
                PathBuf::from("b.yaml"),
                PathBuf::from("c.yaml"),
            ]
        );
        let must = select_scenarios(sample_dir(), &manifest, ScenarioSet::MustPass)?;
        assert_eq!(must, vec![PathBuf::from("a.yaml"), PathBuf::from("b.yaml")]);
        let nice = select_scenarios(sample_dir(), &manifest, ScenarioSet::NiceToPass)?;
        assert_eq!(nice, vec![PathBuf::from("c.yaml")]);
        Ok(())
    }

    /// The shape the plan-level refusal's own remedy walks a user into: a set
    /// that covers no tier this `SAMPLE.md` populates. Selecting nothing is a
    /// refusal, not a sample that passed.
    #[test]
    fn a_set_covering_no_populated_tier_is_refused() -> Result<(), String> {
        let manifest = manifest(&["a.yaml"], &[]);
        let res = select_scenarios(sample_dir(), &manifest, ScenarioSet::NiceToPass);
        let Err(RunnerError::SampleSetMatchedNothing {
            sample_dir: dir,
            selected,
            total,
            populated,
        }) = res
        else {
            return Err(format!("expected SampleSetMatchedNothing, got {res:?}"));
        };
        if dir != sample_dir()
            || selected != "nice_to_pass"
            || total != 1
            || populated != "must_pass"
        {
            return Err(format!(
                "the refusal misdescribes the sample: dir={} selected={selected} total={total} populated={populated}",
                dir.display()
            ));
        }
        Ok(())
    }

    /// A `SAMPLE.md` with no scenario in any tier is the manifest's fault, not
    /// the invocation's — no set can make it replay something.
    #[test]
    fn a_manifest_with_no_scenarios_anywhere_is_a_manifest_error() {
        let manifest = manifest(&[], &[]);
        let res = select_scenarios(sample_dir(), &manifest, ScenarioSet::All);
        assert!(
            matches!(res, Err(RunnerError::SampleDeclaresNoScenarios { .. })),
            "a manifest declaring no scenarios must be SampleDeclaresNoScenarios, got {res:?}"
        );
    }
}
