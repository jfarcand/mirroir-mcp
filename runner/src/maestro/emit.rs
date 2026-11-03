// ABOUTME: Writes an imported flow as a mirroir-run scenario YAML, then reads it back through the runner's own loader.
// ABOUTME: A scenario that does not parse back into exactly the steps it was built from is refused, never written.

use std::fmt::{self, Write as _};

use serde_norway::Value;

use crate::error::RunnerError;
use crate::maestro::error::MaestroError;
use crate::maestro::import::{ImportedFlow, Line};
use crate::parser::scenario::Scenario;
use crate::parser::version::{self, ArtifactKind};

/// File suffix of an imported scenario — the one mirroir's own iOS emitter
/// uses, so the compiled screen reference lands beside it as
/// `<stem>.ios.compiled.json`.
pub const SCENARIO_SUFFIX: &str = ".ios.yaml";

/// Render `flow` as scenario YAML and verify it reads back unchanged.
///
/// # Errors
///
/// [`MaestroError::RoundTrip`] when the text does not load through the
/// runner's scenario loader, or loads into different steps.
pub fn render_scenario(flow: &ImportedFlow) -> Result<String, MaestroError> {
    let round_trip = |reason: String| MaestroError::RoundTrip {
        flow: flow.source.clone(),
        reason,
    };
    let mut out = String::new();
    let text = |out: &mut String, line: &str| -> Result<(), MaestroError> {
        writeln!(out, "{line}").map_err(|err| round_trip(err.to_string()))
    };
    text(
        &mut out,
        &format!(
            "# Imported from the Maestro flow {} by `mirroir-run import maestro`; re-importing overwrites this file.",
            one_line(&flow.source.display().to_string())
        ),
    )?;
    text(
        &mut out,
        &format!("version: {}", ArtifactKind::Scenario.current()),
    )?;
    let name = quote(&flow.name).map_err(|err| round_trip(err.to_string()))?;
    text(&mut out, &format!("name: {name}"))?;
    if !flow.tags.is_empty() {
        let tags = flow
            .tags
            .iter()
            .map(|tag| quote(tag))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|err| round_trip(err.to_string()))?;
        text(&mut out, &format!("tags: [{}]", tags.join(", ")))?;
    }
    text(&mut out, "steps:")?;
    let mut steps = Vec::new();
    for line in &flow.lines {
        match line {
            Line::Step {
                value,
                step,
                comment,
            } => {
                if let Some(comment) = comment {
                    text(&mut out, &format!("  # {}", one_line(comment)))?;
                }
                let args = flow_value(&value.args)
                    .map_err(|reason| round_trip(format!("`{}`: {reason}", value.kind)))?;
                text(&mut out, &format!("  - {}: {args}", value.kind))?;
                steps.push(step.as_ref().clone());
            }
            Line::Comment(note) => text(&mut out, &format!("  # {}", one_line(note)))?,
            Line::Skipped(item) => text(
                &mut out,
                &format!(
                    "  # skipped (no mirroir equivalent): {}",
                    one_line(&item.to_string())
                ),
            )?,
        }
    }
    let file = flow.source.display().to_string();
    let parsed: Scenario = version::from_yaml_str(ArtifactKind::Scenario, &file, &out, |source| {
        RunnerError::YamlParse {
            file: file.clone(),
            source,
        }
    })
    .map_err(|err| round_trip(err.to_string()))?;
    if parsed.steps != steps {
        return Err(round_trip(
            "the parsed steps differ from the imported ones".to_owned(),
        ));
    }
    Ok(out)
}

/// `value` in YAML flow style, every string double-quoted so a `${VAR}`
/// the runner substitutes at load time stays one scalar.
fn flow_value(value: &Value) -> Result<String, String> {
    Ok(match value {
        Value::Null => "null".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => number.to_string(),
        Value::String(text) => quote(text).map_err(|err| err.to_string())?,
        Value::Sequence(items) => {
            let items = items
                .iter()
                .map(flow_value)
                .collect::<Result<Vec<_>, _>>()?;
            format!("[{}]", items.join(", "))
        }
        Value::Mapping(map) => {
            let entries = map
                .iter()
                .map(|(key, value)| Ok(format!("{}: {}", flow_key(key)?, flow_value(value)?)))
                .collect::<Result<Vec<_>, String>>()?;
            format!("{{ {} }}", entries.join(", "))
        }
        Value::Tagged(_) => return Err("a tagged YAML value has no scenario form".to_owned()),
    })
}

/// A map key: plain when it is an identifier (`label`, `kind`), quoted otherwise.
fn flow_key(key: &Value) -> Result<String, String> {
    match key {
        Value::String(name)
            if !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') =>
        {
            Ok(name.clone())
        }
        other => flow_value(other),
    }
}

/// A YAML double-quoted scalar holding `text` exactly.
fn quote(text: &str) -> Result<String, fmt::Error> {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if c.is_control() => write!(out, "\\u{:04x}", u32::from(c))?,
            c => out.push(c),
        }
    }
    out.push('"');
    Ok(out)
}

/// `text` on one line, for a YAML comment.
fn one_line(text: &str) -> String {
    text.replace(['\n', '\r'], " ")
}
