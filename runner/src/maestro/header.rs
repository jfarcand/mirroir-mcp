// ABOUTME: Reads a Maestro flow header — appId, name, tags, env constants, onFlowStart — for the importer.
// ABOUTME: A key with no mirroir meaning is returned as refused with its location, never ignored.

use serde_norway::Value;

use crate::maestro::error::Location;
use crate::maestro::flow::{Command, FlowFile};
use crate::maestro::import_args::tags;
use crate::maestro::interpolate::EnvScope;
use crate::maestro::selector::scalar_text;

/// Header keys that change nothing an imported flow does: `jsEngine` picks
/// the engine for scripts, and every script command is refused.
const INERT_HEADER_KEYS: [&str; 1] = ["jsEngine"];

/// A flow header, read.
pub struct Header {
    /// `appId`.
    pub app_id: Option<String>,
    /// `name`.
    pub name: Option<String>,
    /// `tags`.
    pub tags: Vec<String>,
    /// The env scope the flow's commands see.
    pub scope: EnvScope,
    /// `onFlowStart`'s commands.
    pub on_flow_start: Vec<Command>,
    /// `(location, key, reason)` for every key that cannot cross.
    pub refused: Vec<(Location, String, String)>,
}

/// Read `flow`'s header. `inherited` is the caller's scope plus a
/// `runFlow`'s `env:` (`call_env`), which a header constant of the same name
/// would race with in an order Maestro does not document. Keys that cannot
/// cross land in [`Header::refused`].
#[must_use]
pub fn read_header(
    flow: &FlowFile,
    inherited: &EnvScope,
    call_env: &EnvScope,
    top_level: bool,
) -> Header {
    let mut header = Header {
        app_id: None,
        name: None,
        tags: Vec::new(),
        scope: inherited.clone(),
        on_flow_start: Vec::new(),
        refused: Vec::new(),
    };
    for (key, value) in &flow.header {
        let key = key.as_str().unwrap_or_default().to_owned();
        let location = flow.header_location(&key);
        let outcome = match key.as_str() {
            "appId" => scalar_text(value, inherited).map(|id| header.app_id = Some(id)),
            "name" => value
                .as_str()
                .map(|name| header.name = Some(name.to_owned()))
                .ok_or_else(|| "`name` must be text".to_owned()),
            "tags" => tags(value).map(|tags| header.tags = tags),
            "env" => header_env(value, inherited, call_env, &mut header.scope),
            "onFlowStart" if top_level => match value {
                Value::Sequence(values) => {
                    header.on_flow_start = flow.header_commands(&key, values.clone());
                    Ok(())
                }
                _ => Err("`onFlowStart` must be a command list".to_owned()),
            },
            "onFlowStart" => Err(
                "hooks of an included flow run in an order Maestro does not document".to_owned(),
            ),
            "onFlowComplete" => Err(
                "it runs even after a failure, and an ios block stops at its first failure"
                    .to_owned(),
            ),
            inert if INERT_HEADER_KEYS.contains(&inert) => Ok(()),
            _ => Err("not a header key the import maps".to_owned()),
        };
        if let Err(reason) = outcome {
            header.refused.push((location, key, reason));
        }
    }
    header
}

fn header_env(
    value: &Value,
    inherited: &EnvScope,
    call_env: &EnvScope,
    scope: &mut EnvScope,
) -> Result<(), String> {
    let Value::Mapping(env) = value else {
        return Err("`env` must be a map".to_owned());
    };
    let mut reasons = Vec::new();
    for (name, raw) in env {
        let Some(name) = name.as_str() else {
            reasons.push("an `env` key must be text".to_owned());
            continue;
        };
        match scalar_text(raw, inherited) {
            Ok(resolved) => match call_env.get(name) {
                Some(passed) if passed != resolved => reasons.push(format!(
                    "`{name}` is set both by the runFlow `env:` and by this header, and Maestro does not document which wins"
                )),
                Some(_) => {}
                None => scope.bind(name.to_owned(), resolved),
            },
            Err(reason) => reasons.push(format!("`{name}`: {reason}")),
        }
    }
    if reasons.is_empty() {
        Ok(())
    } else {
        Err(reasons.join("; "))
    }
}
