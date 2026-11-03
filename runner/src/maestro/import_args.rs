// ABOUTME: Reads the arguments of Maestro's structural commands — `runFlow`, `repeat` — and header `tags`.
// ABOUTME: Each returns the call to perform or every reason it cannot cross, joined, for the importer to record.

use serde_norway::Value;

use crate::maestro::interpolate::EnvScope;
use crate::maestro::selector::{Fields, scalar_text};

/// The platform an imported flow runs on, as Maestro's `when: platform:` spells it.
const IOS_PLATFORM: &str = "ios";

/// What a `runFlow` runs.
pub enum RunFlowBody {
    /// A flow file, relative to the including flow.
    File(String),
    /// Inline `commands:`.
    Inline(Vec<Value>),
}

/// One `runFlow`, read.
pub struct RunFlowCall {
    /// What it runs.
    pub body: RunFlowBody,
    /// Its `env:`, resolved against the caller's scope.
    pub env: Vec<(String, String)>,
    /// The platform its `when:` names, when that platform is not iOS.
    pub excluded_platform: Option<String>,
}

/// Read a `runFlow` argument.
///
/// # Errors
///
/// Every reason it cannot cross, joined.
pub fn run_flow_call(args: &Value, scope: &EnvScope) -> Result<RunFlowCall, String> {
    if let Value::String(file) = args {
        return Ok(RunFlowCall {
            body: RunFlowBody::File(scalar_text(&Value::String(file.clone()), scope)?),
            env: Vec::new(),
            excluded_platform: None,
        });
    }
    let Value::Mapping(map) = args else {
        return Err("takes a file path or a map with `file:` or `commands:`".to_owned());
    };
    let mut fields = Fields::new(map.clone());
    let mut reasons = Vec::new();
    let mut excluded_platform = None;
    if let Some(when) = fields.take("when") {
        match platform_condition(&when) {
            Ok(Some(platform)) if !platform.eq_ignore_ascii_case(IOS_PLATFORM) => {
                excluded_platform = Some(platform);
            }
            Ok(_) => {}
            Err(reason) => reasons.push(reason),
        }
    }
    let mut env = Vec::new();
    if let Some(value) = fields.take("env") {
        match value {
            Value::Mapping(entries) => {
                for (name, raw) in &entries {
                    match (name.as_str(), scalar_text(raw, scope)) {
                        (Some(name), Ok(resolved)) => env.push((name.to_owned(), resolved)),
                        (_, Err(reason)) => reasons.push(format!("`env`: {reason}")),
                        (None, Ok(_)) => reasons.push("an `env` key must be text".to_owned()),
                    }
                }
            }
            _ => reasons.push("`env` must be a map".to_owned()),
        }
    }
    let body = match (fields.take("file"), fields.take("commands")) {
        (Some(file), None) => scalar_text(&file, scope).map(RunFlowBody::File),
        (None, Some(Value::Sequence(values))) => Ok(RunFlowBody::Inline(values)),
        _ => Err("needs exactly one of `file:` or a `commands:` list".to_owned()),
    };
    for key in fields.leftover() {
        reasons.push(format!("`{key}` is not an option the import maps"));
    }
    match body {
        Ok(body) if reasons.is_empty() => Ok(RunFlowCall {
            body,
            env,
            excluded_platform,
        }),
        Ok(_) => Err(reasons.join("; ")),
        Err(reason) => {
            reasons.push(reason);
            Err(reasons.join("; "))
        }
    }
}

/// `when: { platform: X }` → `Some(X)`; any other condition is refused,
/// because it is evaluated on the live screen, which an ios block cannot do.
fn platform_condition(when: &Value) -> Result<Option<String>, String> {
    let Value::Mapping(map) = when else {
        return Err("`when` must be a map".to_owned());
    };
    let mut fields = Fields::new(map.clone());
    let platform = fields
        .take("platform")
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or("`platform` must be text")
        })
        .transpose()?;
    let others = fields.leftover();
    if others.is_empty() {
        Ok(platform)
    } else {
        Err(format!(
            "`when: {}` is a live-screen condition; an ios block has no evaluator for it",
            others.join(", ")
        ))
    }
}

/// Read a `repeat` argument: its `times` and its `commands`.
///
/// # Errors
///
/// Every reason it cannot cross, joined.
pub fn repeat_call(args: &Value) -> Result<(u64, Vec<Value>), String> {
    let Value::Mapping(map) = args else {
        return Err("takes a map with `times:` and `commands:`".to_owned());
    };
    let mut fields = Fields::new(map.clone());
    let mut reasons = Vec::new();
    if fields.take("while").is_some() {
        reasons.push(
            "`while` loops on a live-screen condition, which an ios block cannot evaluate"
                .to_owned(),
        );
    }
    let times = fields.take("times").map(|times| times.as_u64());
    let commands = fields.take("commands");
    for key in fields.leftover() {
        reasons.push(format!("`{key}` is not an option the import maps"));
    }
    match (times, commands) {
        (Some(Some(times)), Some(Value::Sequence(values))) if reasons.is_empty() => {
            Ok((times, values))
        }
        (Some(None), _) => {
            reasons.push("`times` must be a whole number".to_owned());
            Err(reasons.join("; "))
        }
        (None, _) if reasons.is_empty() => Err("`times` is required".to_owned()),
        (_, Some(Value::Sequence(_))) => Err(reasons.join("; ")),
        _ => {
            reasons.push("`commands` must be a command list".to_owned());
            Err(reasons.join("; "))
        }
    }
}

/// Read a header `tags:` list.
///
/// # Errors
///
/// The reason, when it is not a list of text.
pub fn tags(value: &Value) -> Result<Vec<String>, String> {
    let Value::Sequence(items) = value else {
        return Err("`tags` must be a list".to_owned());
    };
    items
        .iter()
        .map(|item| {
            item.as_str()
                .map(str::to_owned)
                .ok_or_else(|| "every tag must be text".to_owned())
        })
        .collect()
}
