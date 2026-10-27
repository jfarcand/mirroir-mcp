// ABOUTME: Emits a `measure:` step — time its action, stop on `until`, record the elapsed ms.
// ABOUTME: The action reuses the ordinary step emitter, so a measured tap compiles like any other tap.

use std::fmt::Write as _;

use crate::compile::error::PlaywrightError;
use crate::compile::playwright_emit::{EmitContext, emit_step, js_string_literal};
use crate::error::Result;
use crate::parser::step::{MeasureArgs, PressKeyArgs, SkillStep, TapArgs, TypeArgs, WaitForArgs};

/// Ceiling, in milliseconds, for a measured wait whose step declares no
/// `max_seconds` of its own.
const DEFAULT_MEASURE_TIMEOUT_MS: u64 = 30_000;

/// Emit a `measure:` step: run its action, stop the clock when `until`
/// becomes visible, and record the elapsed milliseconds into the captures
/// object the test attaches. The Rust post-hook enforces `max_seconds`
/// against that number.
///
/// # Errors
///
/// * [`PlaywrightError::Unsupported`] when `until` is empty or the action verb
///   has no web equivalent.
/// * Anything [`emit_step`] returns for the action itself.
pub fn emit_measure(args: &MeasureArgs, ctx: &mut EmitContext, out: &mut String) -> Result<()> {
    let (action, until_label) = measure_target(args)?;
    let name = js_string_literal(&args.name, "measure name")?;
    let until = js_string_literal(&until_label, "measure until label")?;
    let timeout_ms = args
        .max_seconds
        .map_or(DEFAULT_MEASURE_TIMEOUT_MS, |secs| (secs * 1000.0) as u64);
    writeln!(out, "  {{")?;
    writeln!(out, "    const _t0 = Date.now();")?;
    if let Some(action) = action {
        emit_step(&action, ctx, out)?;
    }
    writeln!(
        out,
        "    await _by(page, {until}).waitFor({{ state: 'visible', timeout: {timeout_ms} }});"
    )?;
    writeln!(out, "    _captures.metrics[{name}] = Date.now() - _t0;")?;
    writeln!(out, "  }}")?;
    Ok(())
}

/// Resolve what a `measure:` step actually times: the action to run before the
/// clock is read, and the label whose appearance stops it.
///
/// With an explicit `until`, the action runs and then the clock stops on that
/// label. Without one, the action must be a waiting verb — it is self-terminating,
/// so its own label is the stop condition and there is no separate action to run.
/// Any other verb has nothing to stop the clock, which is an authoring error
/// rather than an unbounded wait.
fn measure_target(args: &MeasureArgs) -> Result<(Option<SkillStep>, String)> {
    match args.until.as_deref().map(str::trim) {
        Some("") => Err(PlaywrightError::Unsupported {
            reason: format!("measure `{}` declares an empty `until` label", args.name),
        }
        .into()),
        Some(until) => Ok((
            Some(measure_action_step(&args.name, &args.action)?),
            until.to_owned(),
        )),
        None => match measure_action_step(&args.name, &args.action)? {
            SkillStep::WaitFor(wait) => Ok((None, wait.label)),
            _ => Err(PlaywrightError::Unsupported {
                reason: format!(
                    "measure `{}` omits `until`, which only a self-terminating action \
                     (`wait_for` / `wait_visible`) can supply — action `{}` needs an \
                     explicit `until` label to stop the clock",
                    args.name, args.action
                ),
            }
            .into()),
        },
    }
}

/// Parse a `measure.action` in mirroir's `<verb>:<value>` shorthand into the
/// [`SkillStep`] it names, so the action reuses the same emitter every other
/// step goes through.
fn measure_action_step(measure_name: &str, action: &str) -> Result<SkillStep> {
    let unsupported = |reason: String| PlaywrightError::Unsupported { reason }.into();
    let Some((verb, value)) = action.split_once(':') else {
        return Err(unsupported(format!(
            "measure `{measure_name}` action `{action}` is not in `<verb>:<value>` form"
        )));
    };
    let value = value.trim().to_owned();
    Ok(match verb.trim() {
        "tap" => SkillStep::Tap(TapArgs::new(value)),
        "type" => SkillStep::Type(TypeArgs::new(value)),
        "press_key" => SkillStep::PressKey(PressKeyArgs {
            key: value,
            modifiers: Vec::new(),
        }),
        "swipe" => SkillStep::Swipe(value),
        "open_url" => SkillStep::OpenUrl(value),
        "wait_for" | "wait_visible" => SkillStep::WaitFor(WaitForArgs::new(value)),
        other => {
            return Err(unsupported(format!(
                "measure `{measure_name}` action verb `{other}` has no web equivalent \
                 (use tap, type, press_key, swipe, open_url, or wait_visible)"
            )));
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::scenario::Scenario;
    use crate::parser::step::SkillStep;

    /// The locked spec's own `first_token_latency` block declares no `until` —
    /// its action is a wait, so the action supplies the stop condition.
    #[test]
    fn a_waiting_action_supplies_its_own_stop_condition() -> Result<()> {
        let scenario: Scenario = serde_norway::from_str(
            "version: 1\nname: spec measure\nsteps:\n  - measure:\n      \
             name: first_token_latency\n      \
             action: \"wait_visible: streaming-caret\"\n      max_seconds: 5\n",
        )
        .map_err(|source| PlaywrightError::Unsupported {
            reason: format!("spec measure block should parse: {source}"),
        })?;
        let Some(SkillStep::Measure(args)) = scenario.steps.into_iter().next() else {
            return Err(PlaywrightError::Unsupported {
                reason: "expected a measure step".to_owned(),
            }
            .into());
        };
        assert_eq!(args.until, None);
        let (action, until) = measure_target(&args)?;
        assert!(
            action.is_none(),
            "a self-terminating action runs no extra step"
        );
        assert_eq!(until, "streaming-caret");
        Ok(())
    }

    /// An explicit `until` still runs the action and then stops on the label.
    #[test]
    fn an_explicit_until_keeps_the_action_and_the_label() -> Result<()> {
        let args = MeasureArgs {
            name: "roundtrip".to_owned(),
            action: "tap:send".to_owned(),
            until: Some("caret".to_owned()),
            max_seconds: None,
        };
        let (action, until) = measure_target(&args)?;
        assert!(matches!(action, Some(SkillStep::Tap(_))));
        assert_eq!(until, "caret");
        Ok(())
    }

    /// A non-waiting action with no `until` has nothing to stop the clock.
    #[test]
    fn a_non_waiting_action_without_until_is_rejected() -> Result<()> {
        let args = MeasureArgs {
            name: "roundtrip".to_owned(),
            action: "tap:send".to_owned(),
            until: None,
            max_seconds: None,
        };
        let Err(err) = measure_target(&args) else {
            return Err(PlaywrightError::Unsupported {
                reason: "a tap with no `until` must be rejected".to_owned(),
            }
            .into());
        };
        let rendered = err.to_string();
        assert!(rendered.contains("omits `until`"), "got: {rendered}");
        assert!(rendered.contains("tap:send"), "got: {rendered}");
        Ok(())
    }
}
