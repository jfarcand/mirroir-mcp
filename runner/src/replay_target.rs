// ABOUTME: Checks each surface a scenario declares against the executors this binary has, on this host.
// ABOUTME: The plan layer asks here first, so a plan nothing can execute never reaches a compiler or a run.

use std::ops::Range;

use crate::error::{Result, RunnerError};
use crate::ios_error::IosError;
use crate::parser::step::{SkillStep, TargetArgs, TargetKind};
use crate::parser::surface::{is_ai_only, is_device_step, is_web, step_kind};

/// Stands in for the first step's kind when the scenario declares no steps.
const NO_STEPS: &str = "<empty>";

/// Stands in for the declared surface when the scenario declares no `target:`.
const NO_TARGET: &str = "none";

/// Stands in for the step after a block when the block ends the scenario.
const END_OF_SCENARIO: &str = "<end>";

/// Whether this host can run an `ios` block: mirroir-mcp drives iPhone
/// Mirroring, a macOS application.
const HOST_RUNS_IOS: bool = cfg!(target_os = "macos");

/// Check one `target:` declaration: some executor here opens its surface, and
/// this host can run it.
///
/// Every declaration is checked, not just the opening one: a `target:` lower
/// down names a surface as loudly as the first.
///
/// # Errors
///
/// * [`RunnerError::NoExecutorForTargetKind`] when the kind names a surface
///   nothing here opens — `macos` is `mirroir-mcp test`'s, and `process` /
///   `http` steps carry their own work.
/// * [`RunnerError::IosNeedsMacosHost`] for an `ios` block on another host.
///   It is refused, not skipped: a skipped block is a silent pass.
pub fn check_target(index: usize, target: &TargetArgs) -> Result<()> {
    if !target.kind.runner_executes() {
        return Err(RunnerError::NoExecutorForTargetKind {
            index,
            kind: target.kind,
        });
    }
    if target.kind == TargetKind::Ios && !HOST_RUNS_IOS {
        return Err(RunnerError::IosNeedsMacosHost { index });
    }
    Ok(())
}

/// Check the steps of the `ios` block spanning `block`: none may be AI-only
/// ([`crate::parser::surface::AI_ONLY_STEP_KINDS`]).
///
/// A web block compiles a `remember:` to a comment in the spec it emits, but
/// `mirroir-mcp test` cannot evaluate an AI-only step and fails the skill
/// holding it — so inside an `ios` block the step is a plan error, not a note.
///
/// # Errors
///
/// [`IosError::AiOnlyStepInBlock`] naming the first such step.
pub fn check_ios_block(steps: &[SkillStep], block: Range<usize>) -> Result<()> {
    let block_start = block.start;
    let Some(offset) = steps[block].iter().position(is_ai_only) else {
        return Ok(());
    };
    let index = block_start + offset;
    Err(IosError::AiOnlyStepInBlock {
        index,
        kind: step_kind(&steps[index]),
        block_start,
    }
    .into())
}

/// Check a step the plan is about to make a runner-side hook: only steps the
/// runner evaluates may become one.
///
/// A phone-only step outside an `ios` block has no device to drive, and a
/// `condition:` has no evaluator for `if_visible` anywhere — the runner,
/// Playwright and `mirroir-mcp test` all lack one. Either, as a hook, would
/// run nothing and let the scenario pass on its other steps, so the plan
/// refuses both by name.
///
/// `ios_block` is the range of the `ios` block already planned, if one opened.
///
/// # Errors
///
/// * [`RunnerError::BlockNotContiguous`] for a phone-only step after the
///   `ios` block already ended — a second block would be a fresh session.
/// * [`IosError::DeviceStepOutsideIosBlock`] for a phone-only step before any
///   `ios` block opens.
/// * [`RunnerError::ConditionHasNoEvaluator`] for a `condition:`.
pub fn check_hook(
    steps: &[SkillStep],
    index: usize,
    ios_block: Option<Range<usize>>,
) -> Result<()> {
    let step = &steps[index];
    if let SkillStep::Condition(condition) = step {
        return Err(RunnerError::ConditionHasNoEvaluator {
            index,
            if_visible: condition.if_visible.clone(),
        });
    }
    if !is_device_step(step, TargetKind::Ios) || is_web(step) {
        return Ok(());
    }
    Err(ios_block.map_or_else(
        || {
            IosError::DeviceStepOutsideIosBlock {
                index,
                kind: step_kind(step),
            }
            .into()
        },
        |block| block_not_contiguous(steps, index, TargetKind::Ios, &block),
    ))
}

/// The error for a device step at `index` that belongs to the `surface` block
/// spanning `block`, which a runner-side step already ended.
#[must_use]
pub fn block_not_contiguous(
    steps: &[SkillStep],
    index: usize,
    surface: TargetKind,
    block: &Range<usize>,
) -> RunnerError {
    RunnerError::BlockNotContiguous {
        index,
        kind: step_kind(&steps[index]),
        surface,
        block_end: block.end - 1,
        separator_kind: steps.get(block.end).map_or(END_OF_SCENARIO, step_kind),
    }
}

/// The error for a scenario whose web steps have no browser to run in, naming
/// what the scenario opens with and what surface it did declare.
#[must_use]
pub fn no_web_target(steps: &[SkillStep]) -> RunnerError {
    RunnerError::NoWebTarget {
        first_step: steps.first().map_or(NO_STEPS, step_kind),
        declared: declared_targets(steps)
            .next()
            .map_or(NO_TARGET, |(_, t)| t.kind.as_yaml()),
    }
}

/// The scenario's `target:` declarations, each with the index it reads at.
fn declared_targets(steps: &[SkillStep]) -> impl Iterator<Item = (usize, &TargetArgs)> {
    steps
        .iter()
        .enumerate()
        .filter_map(|(index, step)| match step {
            SkillStep::Target(target) => Some((index, target)),
            _ => None,
        })
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use super::{check_ios_block, check_target, no_web_target};
    use crate::error::RunnerError;
    use crate::ios_error::IosError;
    use crate::parser::step::{SkillStep, TapArgs, TargetArgs, TargetKind};

    type TestResult = StdResult<(), String>;

    fn target(kind: TargetKind) -> TargetArgs {
        TargetArgs {
            kind,
            browsers: Vec::new(),
            url: None,
            app: None,
        }
    }

    #[test]
    fn a_web_target_has_an_executor() -> TestResult {
        check_target(0, &target(TargetKind::Web)).map_err(|e| format!("web refused: {e}"))
    }

    #[test]
    fn a_process_target_is_refused_naming_its_kind() -> TestResult {
        match check_target(2, &target(TargetKind::Process)) {
            Err(RunnerError::NoExecutorForTargetKind {
                index: 2,
                kind: TargetKind::Process,
            }) => Ok(()),
            other => Err(format!("expected NoExecutorForTargetKind, got {other:?}")),
        }
    }

    /// `macos` windows are `mirroir-mcp test`'s to drive, not a block here.
    #[test]
    fn a_macos_target_is_refused() -> TestResult {
        match check_target(0, &target(TargetKind::Macos)) {
            Err(RunnerError::NoExecutorForTargetKind {
                kind: TargetKind::Macos,
                ..
            }) => Ok(()),
            other => Err(format!("expected NoExecutorForTargetKind, got {other:?}")),
        }
    }

    /// On macOS an iOS block has an executor.
    #[cfg(target_os = "macos")]
    #[test]
    fn an_ios_target_runs_on_a_macos_host() -> TestResult {
        check_target(1, &target(TargetKind::Ios)).map_err(|e| format!("ios refused on macOS: {e}"))
    }

    /// Anywhere else it is refused by name — never skipped into a pass.
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn an_ios_target_is_refused_off_macos() -> TestResult {
        match check_target(1, &target(TargetKind::Ios)) {
            Err(RunnerError::IosNeedsMacosHost { index: 1 }) => Ok(()),
            other => Err(format!("expected IosNeedsMacosHost, got {other:?}")),
        }
    }

    /// `mirroir-mcp test` skips an AI-only step and grades the skill on the
    /// rest, so one inside an `ios` block is refused, naming the step; the
    /// same note outside the block's range is not the block's concern.
    #[test]
    fn an_ai_only_step_inside_an_ios_block_is_refused_naming_it() -> TestResult {
        let steps = vec![
            SkillStep::Target(target(TargetKind::Ios)),
            SkillStep::Launch("Clock".to_owned()),
            SkillStep::Remember("the alarm list loaded".to_owned()),
            SkillStep::Tap(TapArgs::new("Alarmes".to_owned())),
            SkillStep::Remember("after the block".to_owned()),
        ];
        check_ios_block(&steps[..2], 0..2).map_err(|e| format!("clean block refused: {e}"))?;
        match check_ios_block(&steps, 0..4) {
            Err(RunnerError::Ios(IosError::AiOnlyStepInBlock {
                index: 2,
                kind: "remember",
                block_start: 0,
            })) => Ok(()),
            other => Err(format!("expected AiOnlyStepInBlock, got {other:?}")),
        }
    }

    #[test]
    fn the_missing_browser_error_names_what_the_scenario_declared() -> TestResult {
        let steps = vec![SkillStep::Target(target(TargetKind::Ios))];
        match no_web_target(&steps) {
            RunnerError::NoWebTarget {
                first_step: "target",
                declared: "ios",
            } => Ok(()),
            other => Err(format!("wrong error: {other}")),
        }
    }
}
