// ABOUTME: The wall-clock budget one `ios` block gets before its `mirroir-mcp test` child is killed.
// ABOUTME: Derived from the block's steps times the per-step ceiling web steps already get; overridable by environment.

use std::ffi::OsString;
use std::time::Duration;

use crate::compile::playwright_emit::DEFAULT_STEP_TIMEOUT_MS;
use crate::error::Result;
use crate::ios_error::IosError;
use crate::parser::step::SkillStep;

/// Environment variable overriding the per-step allowance, in whole seconds.
/// A slow device or a CI host that shares its CPU raises it; nothing else
/// about the budget changes.
pub const IOS_STEP_ALLOWANCE_ENV: &str = "MIRROIR_IOS_STEP_ALLOWANCE_S";

/// What one step of an `ios` block earns when no override is set: the same
/// ceiling a web step gets for one locator action or assertion
/// ([`DEFAULT_STEP_TIMEOUT_MS`]). It covers a step's input, mirroir-mcp's
/// settle delay, and the OCR pass that reads the screen back — twice
/// mirroir-mcp's own `wait_for` default of 15 s.
pub const DEFAULT_IOS_STEP_ALLOWANCE: Duration = Duration::from_millis(DEFAULT_STEP_TIMEOUT_MS);

/// Allowances the block earns beyond its steps: `mirroir-mcp test` reads the
/// final screen once more after the last step, for the capture the runner
/// always requests.
const FINAL_CAPTURE_ALLOWANCES: u32 = 1;

/// The per-step allowance: `value` (from [`IOS_STEP_ALLOWANCE_ENV`]) when set,
/// else [`DEFAULT_IOS_STEP_ALLOWANCE`].
///
/// # Errors
///
/// [`IosError::InvalidStepAllowance`] when `value` is not a whole number of
/// seconds.
pub fn step_allowance(value: Option<OsString>) -> Result<Duration> {
    let Some(value) = value else {
        return Ok(DEFAULT_IOS_STEP_ALLOWANCE);
    };
    let text = value.to_string_lossy().into_owned();
    text.trim()
        .parse::<u64>()
        .map(Duration::from_secs)
        .map_err(|source| {
            IosError::InvalidStepAllowance {
                variable: IOS_STEP_ALLOWANCE_ENV,
                value: text,
                source,
            }
            .into()
        })
}

/// How long `mirroir-mcp test` may run `steps` before it is killed.
///
/// Each step earns `allowance`, or its own declared ceiling when that is
/// longer — a `wait_for:` timeout, a `measure:` `max_seconds`. A `scroll_to:`
/// reads the screen once per attempt, so it earns one allowance per attempt.
/// The final-screen capture earns one more.
#[must_use]
pub fn block_budget(steps: &[SkillStep], allowance: Duration) -> Duration {
    // Saturating throughout: an absurd override or `max_scrolls` caps the
    // budget at `Duration::MAX` instead of overflowing.
    steps.iter().map(|step| step_ceiling(step, allowance)).fold(
        allowance.saturating_mul(FINAL_CAPTURE_ALLOWANCES),
        Duration::saturating_add,
    )
}

/// What one step earns: its own declared ceiling, never less than `allowance`.
fn step_ceiling(step: &SkillStep, allowance: Duration) -> Duration {
    let declared = match step {
        SkillStep::WaitFor(args) => args
            .timeout_s
            .map(|seconds| Duration::from_secs(u64::from(seconds))),
        SkillStep::Measure(args) => args
            .max_seconds
            .and_then(|seconds| Duration::try_from_secs_f64(seconds).ok()),
        SkillStep::ScrollTo(args) => Some(allowance.saturating_mul(args.max_scrolls)),
        _ => None,
    };
    declared.map_or(allowance, |ceiling| ceiling.max(allowance))
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::result::Result as StdResult;
    use std::time::Duration;

    use serde_norway::Deserializer;
    use serde_norway::with::singleton_map_recursive;

    use super::{DEFAULT_IOS_STEP_ALLOWANCE, block_budget, step_allowance};
    use crate::error::RunnerError;
    use crate::ios_error::IosError;
    use crate::parser::scenario::Scenario;

    type TestResult = StdResult<(), String>;

    const ALLOWANCE: Duration = Duration::from_secs(10);

    fn budget(steps_yaml: &str) -> StdResult<Duration, String> {
        let yaml = format!("version: 1\nname: flow\nsteps:\n{steps_yaml}");
        let scenario: Scenario =
            singleton_map_recursive::deserialize(Deserializer::from_str(&yaml))
                .map_err(|e| format!("parse: {e}"))?;
        Ok(block_budget(&scenario.steps, ALLOWANCE))
    }

    /// Plain steps earn one allowance each, plus one for the final capture.
    #[test]
    fn each_step_earns_one_allowance_plus_the_final_capture() -> TestResult {
        let total = budget("  - launch: \"Clock\"\n  - tap: \"Alarmes\"\n  - home:\n")?;
        assert_eq!(total, ALLOWANCE * 4);
        Ok(())
    }

    /// A step that declares a longer ceiling of its own keeps it; a shorter
    /// one still earns the full allowance.
    #[test]
    fn a_declared_ceiling_longer_than_the_allowance_is_kept() -> TestResult {
        let total = budget(concat!(
            "  - wait_for: { label: \"Done\", timeout_s: 45 }\n",
            "  - wait_for: { label: \"Soon\", timeout_s: 2 }\n",
            "  - measure: { name: open, action: \"tap:A\", until: \"B\", max_seconds: 12.5 }\n",
        ))?;
        assert_eq!(
            total,
            Duration::from_secs(45) + ALLOWANCE + Duration::from_millis(12_500) + ALLOWANCE
        );
        Ok(())
    }

    /// `scroll_to:` reads the screen once per attempt.
    #[test]
    fn a_scroll_earns_one_allowance_per_attempt() -> TestResult {
        let total = budget("  - scroll_to: \"About\"\n")?;
        assert_eq!(total, ALLOWANCE * 10 + ALLOWANCE);
        Ok(())
    }

    /// An override as large as `u64` seconds caps the budget rather than
    /// overflowing the arithmetic.
    #[test]
    fn a_huge_allowance_saturates_instead_of_overflowing() -> TestResult {
        let yaml = "version: 1\nname: flow\nsteps:\n  - scroll_to: \"About\"\n  - tap: \"A\"\n";
        let scenario: Scenario = singleton_map_recursive::deserialize(Deserializer::from_str(yaml))
            .map_err(|e| format!("parse: {e}"))?;
        let huge = step_allowance(Some(OsString::from(u64::MAX.to_string())))
            .map_err(|e| e.to_string())?;
        assert_eq!(block_budget(&scenario.steps, huge), Duration::MAX);
        Ok(())
    }

    #[test]
    fn the_allowance_defaults_and_takes_an_override() -> TestResult {
        assert_eq!(
            step_allowance(None).map_err(|e| e.to_string())?,
            DEFAULT_IOS_STEP_ALLOWANCE
        );
        assert_eq!(
            step_allowance(Some(OsString::from("90"))).map_err(|e| e.to_string())?,
            Duration::from_secs(90)
        );
        match step_allowance(Some(OsString::from("1m"))) {
            Err(RunnerError::Ios(IosError::InvalidStepAllowance { value, .. })) => {
                assert_eq!(value, "1m");
                Ok(())
            }
            other => Err(format!("expected InvalidStepAllowance, got {other:?}")),
        }
    }
}
