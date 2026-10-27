// ABOUTME: Scenario-set selection for a `.mirroir/` plan — which set runs, and which entries it leaves out.
// ABOUTME: A selection that would replay nothing is refused here instead of composing zero samples and exiting green.

use std::path::Path;

use crate::error::Result;
use crate::mirroir::error::MirroirError;
use crate::parser::mirroir::{DefaultScenarioSet, Plan, PlanEntry};
use crate::replay::ScenarioSet;

/// Resolve the effective scenario set. An explicit CLI `--scenarios` choice
/// always wins; when the user did not pass one (`None`), the config's
/// `default_set` is honored, falling back to `MustPass`.
#[must_use]
pub const fn select_set(
    config_default: Option<DefaultScenarioSet>,
    cli: Option<ScenarioSet>,
) -> ScenarioSet {
    if let Some(set) = cli {
        return set;
    }
    match config_default {
        Some(DefaultScenarioSet::MustPass) | None => ScenarioSet::MustPass,
        Some(DefaultScenarioSet::NiceToPass) => ScenarioSet::NiceToPass,
        Some(DefaultScenarioSet::All) => ScenarioSet::All,
    }
}

/// The plan entries `selected` leaves out of the run entirely.
///
/// These never reach compose or replay, so they carry no verdict of their own;
/// the caller records them as `skipped` so the run summary accounts for every
/// entry the plan declares.
#[must_use]
pub fn set_filtered_entries(plan: &Plan, selected: ScenarioSet) -> &[PlanEntry] {
    if selected.includes_nice_to_pass() {
        &[]
    } else {
        plan.nice_to_pass.as_slice()
    }
}

/// Refuse a selection that would replay nothing.
///
/// Two distinct shapes reach zero selected entries, and they have different
/// remedies:
///
/// * The plan declares entries, and `selected` filtered every one of them out.
///   The invocation is at fault, not the plan — naming a set that covers those
///   tiers runs them.
/// * The plan declares no entries in any tier. No invocation can fix that; the
///   config itself declares no work.
///
/// Either way the run is refused: composing zero samples and reporting `pass`
/// is a green verdict over nothing.
///
/// # Errors
///
/// * [`MirroirError::SelectionMatchedNothing`] when other tiers hold entries.
/// * [`MirroirError::PlanEmpty`] when no tier holds an entry.
pub fn ensure_selection_runs_something(
    config_path: &Path,
    plan: &Plan,
    selected: ScenarioSet,
) -> Result<()> {
    let total = plan.must_pass.len() + plan.nice_to_pass.len();
    let filtered_out = set_filtered_entries(plan, selected).len();
    if total > filtered_out {
        return Ok(());
    }
    if total == 0 {
        return Err(MirroirError::PlanEmpty {
            config: config_path.to_path_buf(),
        }
        .into());
    }
    let mut populated: Vec<&str> = Vec::with_capacity(2);
    if !plan.must_pass.is_empty() {
        populated.push("must_pass");
    }
    if !plan.nice_to_pass.is_empty() {
        populated.push("nice_to_pass");
    }
    Err(MirroirError::SelectionMatchedNothing {
        selected: selected.label().to_owned(),
        total,
        populated: populated.join(", "),
    }
    .into())
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};

    use super::{
        DefaultScenarioSet, Plan, ScenarioSet, ensure_selection_runs_something, select_set,
        set_filtered_entries,
    };
    use crate::error::RunnerError;
    use crate::mirroir::error::MirroirError;
    use crate::parser::mirroir::{PlanEntry, PlanEntryBoot, PlanEntrySource};

    fn entry(name: &str) -> PlanEntry {
        PlanEntry {
            name: name.to_owned(),
            source: PlanEntrySource::Local {
                path: PathBuf::from("samples/demo"),
            },
            flows: vec![],
            vars: HashMap::new(),
            boot: PlanEntryBoot {
                command: "true".to_owned(),
                cwd: None,
                env: HashMap::new(),
                timeout_s: None,
                boot_once: true,
                boot_ready_port: None,
                boot_ready_timeout_s: None,
            },
            skip: false,
        }
    }

    fn config() -> &'static Path {
        Path::new("/repo/.mirroir/mirroir.yaml")
    }

    #[test]
    fn explicit_cli_choice_wins_over_config_default() {
        let resolved = select_set(Some(DefaultScenarioSet::MustPass), Some(ScenarioSet::All));
        assert!(matches!(resolved, ScenarioSet::All));
    }

    #[test]
    fn config_default_honored_when_cli_absent() {
        assert!(matches!(
            select_set(Some(DefaultScenarioSet::All), None),
            ScenarioSet::All
        ));
        assert!(matches!(
            select_set(Some(DefaultScenarioSet::NiceToPass), None),
            ScenarioSet::NiceToPass
        ));
    }

    #[test]
    fn falls_back_to_must_pass_when_both_absent() {
        assert!(matches!(select_set(None, None), ScenarioSet::MustPass));
    }

    /// The reproduction: entries only under `nice_to_pass`, no `default_set`.
    /// `MustPass` selects none of them, and that is a refusal, not a pass.
    #[test]
    fn must_pass_over_a_nice_to_pass_only_plan_is_refused() -> Result<(), String> {
        let plan = Plan {
            must_pass: vec![],
            nice_to_pass: vec![entry("demo")],
        };
        let res = ensure_selection_runs_something(config(), &plan, ScenarioSet::MustPass);
        let Err(RunnerError::Mirroir(MirroirError::SelectionMatchedNothing {
            selected,
            total,
            populated,
        })) = res
        else {
            return Err(format!("expected SelectionMatchedNothing, got {res:?}"));
        };
        if selected != "must_pass" || total != 1 || populated != "nice_to_pass" {
            return Err(format!(
                "the refusal misdescribes the plan: selected={selected} total={total} populated={populated}"
            ));
        }
        Ok(())
    }

    /// Naming a set that covers the populated tier makes the same plan run.
    #[test]
    fn a_set_that_covers_the_populated_tier_is_accepted() -> Result<(), RunnerError> {
        let plan = Plan {
            must_pass: vec![],
            nice_to_pass: vec![entry("demo")],
        };
        ensure_selection_runs_something(config(), &plan, ScenarioSet::All)?;
        ensure_selection_runs_something(config(), &plan, ScenarioSet::NiceToPass)
    }

    /// A plan with no entries anywhere is the config's fault, not the
    /// invocation's — no `--scenarios` value can make it run something.
    #[test]
    fn a_plan_with_no_entries_anywhere_is_a_config_error() {
        let res = ensure_selection_runs_something(config(), &Plan::default(), ScenarioSet::All);
        assert!(
            matches!(
                res,
                Err(RunnerError::Mirroir(MirroirError::PlanEmpty { .. }))
            ),
            "an empty plan must be PlanEmpty, got {res:?}"
        );
    }

    #[test]
    fn only_a_must_pass_selection_filters_the_nice_to_pass_tier() {
        let plan = Plan {
            must_pass: vec![entry("core")],
            nice_to_pass: vec![entry("extra")],
        };
        let filtered = set_filtered_entries(&plan, ScenarioSet::MustPass);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].name, "extra");
        assert_eq!(
            set_filtered_entries(&plan, ScenarioSet::All),
            &[] as &[PlanEntry]
        );
        assert_eq!(
            set_filtered_entries(&plan, ScenarioSet::NiceToPass),
            &[] as &[PlanEntry]
        );
    }
}
