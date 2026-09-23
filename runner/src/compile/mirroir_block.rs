// ABOUTME: Writes a scenario's `ios` block in mirroir-mcp's skill dialect — one step per line, as SkillParser reads it.
// ABOUTME: A step the dialect cannot express is refused by name; nothing is dropped or approximated.

use std::fmt::Write as _;
use std::ops::Range;

use crate::error::Result;
use crate::ios_error::IosError;
use crate::parser::step::{MeasureArgs, SkillStep};
use crate::parser::surface::step_kind;

/// The scroll direction mirroir-mcp's `scroll_to:` uses; the dialect has no
/// way to name another.
const SWIPE_SCROLL_DIRECTION: &str = "up";

/// The scroll budget the runner grammar defaults to. mirroir-mcp applies its
/// own configured budget, so only the default crosses unchanged.
const DEFAULT_MAX_SCROLLS: u32 = 10;

/// Render the steps in `block` as a skill file `mirroir-mcp test` runs.
///
/// mirroir-mcp's parser reads one step per line, so every step is written on
/// one line in the shapes it parses: `tap: "Label"`, `wait_for: "Label"
/// timeout: 30`, `measure: { tap: "A", until: "B", max: 5, name: "n" }`, and
/// the opening `target: { kind: ios, app: "…" }`.
///
/// # Errors
///
/// [`IosError::NotExpressible`] for a step that uses a web-only option
/// (`last:`, `into:`, `contains:`, a per-step timeout on `tap:` / asserts), a
/// runner-side step, or a value the line format cannot carry intact.
pub fn ios_block_yaml(name: &str, steps: &[SkillStep], block: Range<usize>) -> Result<String> {
    let mut out = format!(
        "version: 1\nname: {}\nsteps:\n",
        scalar(usize::MAX, "name", name)?
    );
    for index in block {
        let Some(step) = steps.get(index) else {
            continue;
        };
        writeln!(out, "  - {}", step_line(index, step)?)?;
    }
    Ok(out)
}

/// One step, as mirroir-mcp's parser reads it.
fn step_line(index: usize, step: &SkillStep) -> Result<String> {
    let kind = step_kind(step);
    let refuse = |reason: &str| -> Result<String> {
        Err(IosError::NotExpressible {
            index,
            kind,
            reason: reason.to_owned(),
        }
        .into())
    };
    let q = |value: &str| scalar(index, kind, value);
    Ok(match step {
        SkillStep::Target(target) => match target.app.as_deref() {
            Some(app) => format!("target: {{ kind: ios, app: {} }}", q(app)?),
            None => "target: { kind: ios }".to_owned(),
        },
        SkillStep::Launch(app) => format!("launch: {}", q(app)?),
        SkillStep::Tap(args) => {
            if args.last || args.timeout_s.is_some() {
                return refuse("`last:` and a per-step `timeout_s:` are web-only options");
            }
            format!("tap: {}", q(&args.label)?)
        }
        SkillStep::Type(args) => {
            if args.into.is_some() || args.last || args.timeout_s.is_some() {
                return refuse(
                    "`into:`, `last:` and `timeout_s:` are web-only; type into the focused field",
                );
            }
            format!("type: {}", q(&args.text)?)
        }
        SkillStep::PressKey(args) if args.modifiers.is_empty() => {
            format!("press_key: {}", q(&args.key)?)
        }
        SkillStep::PressKey(args) => {
            let modifiers = args
                .modifiers
                .iter()
                .map(|m| q(m))
                .collect::<Result<Vec<_>>>()?;
            format!(
                "press_key: {} modifiers: [{}]",
                q(&args.key)?,
                modifiers.join(", ")
            )
        }
        SkillStep::Swipe(direction) => format!("swipe: {}", q(direction)?),
        SkillStep::WaitFor(args) => {
            if args.last {
                return refuse("`last:` is a web-only option");
            }
            match args.timeout_s {
                Some(seconds) => format!("wait_for: {} timeout: {seconds}", q(&args.label)?),
                None => format!("wait_for: {}", q(&args.label)?),
            }
        }
        SkillStep::AssertVisible(args) | SkillStep::AssertNotVisible(args) => {
            if args.contains.is_some() || args.last || args.timeout_s.is_some() {
                return refuse("`contains:`, `last:` and `timeout_s:` are web-only options");
            }
            format!("{kind}: {}", q(&args.label)?)
        }
        SkillStep::Screenshot(label) => format!("screenshot: {}", q(label)?),
        SkillStep::OpenUrl(url) => format!("open_url: {}", q(url)?),
        SkillStep::Home(_) => "home".to_owned(),
        SkillStep::Shake(_) => "shake".to_owned(),
        SkillStep::ResetApp(app) => format!("reset_app: {}", q(app)?),
        SkillStep::SetNetwork(mode) => format!("set_network: {}", q(mode)?),
        SkillStep::Remember(note) => format!("remember: {}", q(note)?),
        SkillStep::ScrollTo(args) => {
            if args.direction != SWIPE_SCROLL_DIRECTION || args.max_scrolls != DEFAULT_MAX_SCROLLS {
                return refuse(
                    "mirroir-mcp scrolls up with its configured attempt budget; `direction:` and `max_scrolls:` cannot cross",
                );
            }
            format!("scroll_to: {}", q(&args.label)?)
        }
        SkillStep::LongPress(args) => match args.duration_ms {
            Some(ms) => format!("long_press: {} duration: {ms}", q(&args.label)?),
            None => format!("long_press: {}", q(&args.label)?),
        },
        SkillStep::Drag(args) => {
            format!(
                "drag: {{ from: {}, to: {} }}",
                comma_free(index, kind, &args.from)?,
                comma_free(index, kind, &args.to)?
            )
        }
        SkillStep::Measure(args) => measure_line(index, args)?,
        SkillStep::Condition(_)
        | SkillStep::Spawn(_)
        | SkillStep::WaitPort(_)
        | SkillStep::Kill(_)
        | SkillStep::AssertLog(_)
        | SkillStep::AssertLogClean(_)
        | SkillStep::Judge(_)
        | SkillStep::Http(_)
        | SkillStep::Report(_)
        | SkillStep::CrossSurface(_) => {
            return refuse("a runner-side step never joins a device block");
        }
    })
}

/// `measure: { <verb>: "<value>", until: "…", max: N, name: "…" }`.
fn measure_line(index: usize, args: &MeasureArgs) -> Result<String> {
    let kind = "measure";
    let refuse = |reason: &str| -> Result<String> {
        Err(IosError::NotExpressible {
            index,
            kind,
            reason: reason.to_owned(),
        }
        .into())
    };
    let Some((verb, value)) = args.action.split_once(':') else {
        return refuse("`action:` is not in `verb:value` form");
    };
    let Some(until) = args.until.as_deref() else {
        return refuse("mirroir-mcp stops the clock on `until:`, which this measure omits");
    };
    let mut line = format!(
        "measure: {{ {}: {}, until: {}",
        verb.trim(),
        comma_free(index, kind, value.trim())?,
        comma_free(index, kind, until)?
    );
    if let Some(max) = args.max_seconds {
        write!(line, ", max: {max}")?;
    }
    write!(line, ", name: {} }}", comma_free(index, kind, &args.name)?)?;
    Ok(line)
}

/// Quote `value` as one scalar mirroir-mcp's parser reads back unchanged.
///
/// Its parser strips one pair of surrounding quotes and unescapes nothing, so
/// a value is double-quoted, single-quoted when it holds a double quote, and
/// refused when it holds both or a line break.
fn scalar(index: usize, kind: &'static str, value: &str) -> Result<String> {
    let refuse = |reason: &str| -> Result<String> {
        Err(IosError::NotExpressible {
            index,
            kind,
            reason: reason.to_owned(),
        }
        .into())
    };
    if value.contains('\n') {
        return refuse("a value spanning lines cannot cross the one-step-per-line dialect");
    }
    match (value.contains('"'), value.contains('\'')) {
        (false, _) => Ok(format!("\"{value}\"")),
        (true, false) => Ok(format!("'{value}'")),
        (true, true) => refuse("a value holding both quote characters cannot be quoted intact"),
    }
}

/// [`scalar`], for a value inside a `{ … }` map mirroir-mcp splits on commas.
fn comma_free(index: usize, kind: &'static str, value: &str) -> Result<String> {
    if value.contains(',') {
        return Err(IosError::NotExpressible {
            index,
            kind,
            reason: format!("`{value}` holds a comma, which mirroir-mcp's map parser splits on"),
        }
        .into());
    }
    scalar(index, kind, value)
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use serde_yaml::Deserializer;
    use serde_yaml::with::singleton_map_recursive;

    use super::ios_block_yaml;
    use crate::error::RunnerError;
    use crate::ios_error::IosError;
    use crate::parser::scenario::Scenario;

    type TestResult = StdResult<(), String>;

    fn block(steps_yaml: &str) -> StdResult<Result<String, RunnerError>, String> {
        let yaml = format!("version: 1\nname: flow\nsteps:\n{steps_yaml}");
        let scenario: Scenario =
            singleton_map_recursive::deserialize(Deserializer::from_str(&yaml))
                .map_err(|e| format!("parse: {e}"))?;
        let len = scenario.steps.len();
        Ok(ios_block_yaml(&scenario.name, &scenario.steps, 0..len))
    }

    /// Every step lands on one line, in the shape `SkillParser` reads.
    #[test]
    fn the_block_is_written_one_step_per_line() -> TestResult {
        let yaml = block(concat!(
            "  - target: { kind: ios, app: \"Clock\" }\n",
            "  - launch: \"Clock\"\n",
            "  - tap: \"Alarmes\"\n",
            "  - wait_for: { label: \"Aucune alarme\", timeout_s: 30 }\n",
            "  - press_key: { key: \"l\", modifiers: [command] }\n",
            "  - long_press: { label: \"Photo\", duration_ms: 800 }\n",
            "  - drag: { from: \"A\", to: \"B\" }\n",
            "  - measure: { name: open, action: \"tap:Alarmes\", until: \"Aucune alarme\", max_seconds: 5 }\n",
            "  - assert_visible: 'Say \"hi\"'\n",
            "  - home:\n",
        ))?
        .map_err(|e| e.to_string())?;
        let expected = concat!(
            "version: 1\nname: \"flow\"\nsteps:\n",
            "  - target: { kind: ios, app: \"Clock\" }\n",
            "  - launch: \"Clock\"\n",
            "  - tap: \"Alarmes\"\n",
            "  - wait_for: \"Aucune alarme\" timeout: 30\n",
            "  - press_key: \"l\" modifiers: [\"command\"]\n",
            "  - long_press: \"Photo\" duration: 800\n",
            "  - drag: { from: \"A\", to: \"B\" }\n",
            "  - measure: { tap: \"Alarmes\", until: \"Aucune alarme\", max: 5, name: \"open\" }\n",
            "  - assert_visible: 'Say \"hi\"'\n",
            "  - home\n",
        );
        assert_eq!(yaml, expected);
        Ok(())
    }

    fn refused(steps_yaml: &str) -> StdResult<String, String> {
        match block(steps_yaml)? {
            Err(RunnerError::Ios(IosError::NotExpressible { reason, .. })) => Ok(reason),
            other => Err(format!("expected NotExpressible, got {other:?}")),
        }
    }

    /// A web-only option has no iOS meaning; dropping it would run a
    /// different test than the file reads.
    #[test]
    fn web_only_options_are_refused_not_dropped() -> TestResult {
        for step in [
            "  - tap: { label: \"Go\", last: true }\n",
            "  - type: { text: \"hi\", into: \"Email\" }\n",
            "  - assert_visible: { label: \"Total\", contains: \"42\" }\n",
        ] {
            let reason = refused(step)?;
            if !reason.contains("web-only") {
                return Err(format!("{step}: wrong reason {reason}"));
            }
        }
        Ok(())
    }

    #[test]
    fn a_value_the_line_format_cannot_carry_is_refused() -> TestResult {
        refused("  - tap: \"both \\\" and '\"\n")?;
        refused("  - drag: { from: \"a, b\", to: \"c\" }\n")?;
        Ok(())
    }
}
