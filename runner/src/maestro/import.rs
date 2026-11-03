// ABOUTME: Walks a Maestro flow into scenario lines — header, onFlowStart, runFlow includes, repeat unrolling.
// ABOUTME: Every command either becomes steps the runner's parser reads back or is recorded as unsupported, never dropped.

use std::fs;
use std::mem;
use std::path::{Path, PathBuf};

use serde_norway::Value;
use serde_norway::with::singleton_map_recursive;

use crate::compile::mirroir_block::ios_block_yaml;
use crate::error::RunnerError;
use crate::ios_error::IosError;
use crate::maestro::error::{Location, MaestroError, UnsupportedItem};
use crate::maestro::flow::{Command, FlowFile};
use crate::maestro::header::{Header, read_header};
use crate::maestro::import_args::{RunFlowBody, repeat_call, run_flow_call};
use crate::maestro::interpolate::EnvScope;
use crate::maestro::map::{AppNames, LeafContext, StepValue, map_leaf};
use crate::maestro::selector::{Fields, scalar_text};
use crate::parser::step::SkillStep;

/// One line of the scenario being built.
#[derive(Debug, Clone, PartialEq)]
pub enum Line {
    /// A step, with the Maestro `label:` it carried.
    Step {
        /// The step as the YAML written.
        value: StepValue,
        /// The same step as the runner's parser reads it.
        step: Box<SkillStep>,
        /// The command's `label:`, written as a comment above it.
        comment: Option<String>,
    },
    /// A note the scenario carries (a `runFlow` label, a platform-excluded include).
    Comment(String),
    /// A command left out under `--skip-unsupported`.
    Skipped(UnsupportedItem),
}

/// A flow, imported.
#[derive(Debug, Clone)]
pub struct ImportedFlow {
    /// The flow file.
    pub source: PathBuf,
    /// The header's `name`, else the file stem.
    pub name: String,
    /// The header's `tags`.
    pub tags: Vec<String>,
    /// The scenario lines, its `target:` first.
    pub lines: Vec<Line>,
    /// Every unsupported item, deduplicated, in flow order.
    pub unsupported: Vec<UnsupportedItem>,
}

/// Import the flow at `path`, following its `runFlow` includes.
///
/// # Errors
///
/// [`MaestroError::Read`] / [`MaestroError::Parse`] / [`MaestroError::Shape`]
/// for the flow or an include, [`MaestroError::FlowCycle`] for includes that
/// loop, and [`MaestroError::RoundTrip`] when a built step does not parse.
/// Unsupported commands are not errors here; they are listed in
/// [`ImportedFlow::unsupported`] for the caller to refuse or skip.
pub fn import_flow(path: &Path, apps: &AppNames) -> Result<ImportedFlow, MaestroError> {
    let flow = FlowFile::load(path)?;
    let mut importer = Importer {
        apps,
        source: path.to_path_buf(),
        lines: Vec::new(),
        unsupported: Vec::new(),
        chain: vec![canonical(path)?],
    };
    let header = importer.header(&flow, &EnvScope::default(), &EnvScope::default(), true);
    let mut target = serde_norway::Mapping::new();
    target.insert("kind".into(), "ios".into());
    if let Some(app) = header
        .app_id
        .as_deref()
        .and_then(|id| apps.display_name(id).ok())
    {
        target.insert("app".into(), app.into());
    }
    let target = StepValue {
        kind: "target",
        args: Value::Mapping(target),
    };
    importer.push_line(target, None)?;
    let ctx = FlowCtx {
        flow: &flow,
        app_id: header.app_id,
        scope: header.scope,
    };
    importer.commands(&ctx, &header.on_flow_start)?;
    importer.commands(&ctx, &flow.commands)?;
    let mut unsupported: Vec<UnsupportedItem> = Vec::new();
    for item in importer.unsupported {
        if !unsupported.contains(&item) {
            unsupported.push(item);
        }
    }
    let stem = path.file_stem().map_or_else(
        || path.display().to_string(),
        |stem| stem.to_string_lossy().into_owned(),
    );
    Ok(ImportedFlow {
        source: importer.source,
        name: header.name.unwrap_or(stem),
        tags: header.tags,
        lines: importer.lines,
        unsupported,
    })
}

struct Importer<'a> {
    apps: &'a AppNames,
    source: PathBuf,
    lines: Vec<Line>,
    unsupported: Vec<UnsupportedItem>,
    chain: Vec<PathBuf>,
}

struct FlowCtx<'f> {
    flow: &'f FlowFile,
    app_id: Option<String>,
    scope: EnvScope,
}

impl Importer<'_> {
    /// Read `flow`'s header, recording each key it refuses.
    fn header(
        &mut self,
        flow: &FlowFile,
        inherited: &EnvScope,
        call_env: &EnvScope,
        top_level: bool,
    ) -> Header {
        let mut header = read_header(flow, inherited, call_env, top_level);
        for (location, key, reason) in mem::take(&mut header.refused) {
            self.refuse(location, &key, reason);
        }
        header
    }

    fn refuse(&mut self, location: Location, command: &str, reason: String) {
        let item = UnsupportedItem {
            location,
            command: command.to_owned(),
            reason,
        };
        self.lines.push(Line::Skipped(item.clone()));
        self.unsupported.push(item);
    }

    fn commands(&mut self, ctx: &FlowCtx<'_>, commands: &[Command]) -> Result<(), MaestroError> {
        for command in commands {
            self.command(ctx, command)?;
        }
        Ok(())
    }

    fn command(&mut self, ctx: &FlowCtx<'_>, command: &Command) -> Result<(), MaestroError> {
        let location = command.location.clone();
        let (name, mut args) = match command.name_and_args() {
            Ok(pair) => pair,
            Err(reason) => {
                self.refuse(location, "?", reason);
                return Ok(());
            }
        };
        let mut label = None;
        if let Value::Mapping(map) = &args {
            let mut fields = Fields::new(map.clone());
            // A label is documentation: one whose `${…}` cannot resolve is
            // kept as written rather than lost.
            label = fields.take("label").map(|value| {
                scalar_text(&value, &ctx.scope)
                    .unwrap_or_else(|_| value.as_str().unwrap_or_default().to_owned())
            });
            if let Err(reason) = fields.refuse_unless(
                "optional",
                &Value::Bool(false),
                "an ios block fails on a step that does not succeed; nothing is optional",
            ) {
                self.refuse(location, &name, reason);
                return Ok(());
            }
            args = fields.into_value();
        }
        match name.as_str() {
            "runFlow" => self.run_flow(ctx, command, &args, label),
            "repeat" => self.repeat(ctx, command, &args, label),
            _ => {
                let leaf = LeafContext {
                    app_id: ctx.app_id.as_deref(),
                    apps: self.apps,
                    scope: &ctx.scope,
                };
                match map_leaf(&name, &args, leaf) {
                    Ok(steps) => self.push_steps(&location, &name, steps, label),
                    Err(reason) => {
                        self.refuse(location, &name, reason);
                        Ok(())
                    }
                }
            }
        }
    }

    /// Append one command's steps — or, when mirroir-mcp's one-step-per-line
    /// dialect cannot carry one of them, refuse the whole command.
    fn push_steps(
        &mut self,
        location: &Location,
        command: &str,
        steps: Vec<StepValue>,
        label: Option<String>,
    ) -> Result<(), MaestroError> {
        let parsed = steps
            .iter()
            .map(|value| self.parse_step(value))
            .collect::<Result<Vec<_>, _>>()?;
        if let Err(err) = ios_block_yaml(command, &parsed, 0..parsed.len()) {
            let reason = match err {
                RunnerError::Ios(IosError::NotExpressible { reason, .. }) => reason,
                other => other.to_string(),
            };
            self.refuse(location.clone(), command, reason);
            return Ok(());
        }
        let mut comment = label;
        for (value, step) in steps.into_iter().zip(parsed) {
            if self.repeats_reset(&step) {
                continue;
            }
            self.lines.push(Line::Step {
                value,
                step: Box::new(step),
                comment: comment.take(),
            });
        }
        Ok(())
    }

    fn push_line(&mut self, value: StepValue, comment: Option<String>) -> Result<(), MaestroError> {
        let step = self.parse_step(&value)?;
        self.lines.push(Line::Step {
            value,
            step: Box::new(step),
            comment,
        });
        Ok(())
    }

    /// A force-quit straight after the same force-quit (`stopApp` then
    /// `launchApp`) changes nothing; it is written once.
    fn repeats_reset(&self, step: &SkillStep) -> bool {
        let SkillStep::ResetApp(app) = step else {
            return false;
        };
        let last = self.lines.iter().rev().find_map(|line| match line {
            Line::Step { step, .. } => Some(step.as_ref()),
            Line::Comment(_) | Line::Skipped(_) => None,
        });
        matches!(last, Some(SkillStep::ResetApp(previous)) if previous == app)
    }

    /// Build the step through the runner's own parser.
    fn parse_step(&self, value: &StepValue) -> Result<SkillStep, MaestroError> {
        let mut map = serde_norway::Mapping::new();
        map.insert(value.kind.into(), value.args.clone());
        singleton_map_recursive::deserialize(Value::Mapping(map)).map_err(|err| {
            MaestroError::RoundTrip {
                flow: self.source.clone(),
                reason: format!("`{}` step: {err}", value.kind),
            }
        })
    }

    fn run_flow(
        &mut self,
        ctx: &FlowCtx<'_>,
        command: &Command,
        args: &Value,
        label: Option<String>,
    ) -> Result<(), MaestroError> {
        let location = command.location.clone();
        let call = match run_flow_call(args, &ctx.scope) {
            Ok(call) => call,
            Err(reason) => {
                self.refuse(location, "runFlow", reason);
                return Ok(());
            }
        };
        if let Some(platform) = call.excluded_platform {
            self.lines.push(Line::Comment(format!(
                "{location}: runFlow left out — `when: platform: {platform}` excludes iOS"
            )));
            return Ok(());
        }
        if let Some(label) = label {
            self.lines.push(Line::Comment(label));
        }
        let mut scope = ctx.scope.clone();
        for (name, value) in &call.env {
            scope.bind(name.clone(), value.clone());
        }
        match call.body {
            RunFlowBody::Inline(values) => {
                let nested = ctx.flow.nested(command, "commands", values);
                let inner = FlowCtx {
                    flow: ctx.flow,
                    app_id: ctx.app_id.clone(),
                    scope,
                };
                self.commands(&inner, &nested)
            }
            RunFlowBody::File(file) => {
                let base = ctx.flow.path.parent().unwrap_or_else(|| Path::new(""));
                self.include(ctx, &base.join(file), &scope, &call.env)
            }
        }
    }

    fn include(
        &mut self,
        ctx: &FlowCtx<'_>,
        path: &Path,
        scope: &EnvScope,
        env: &[(String, String)],
    ) -> Result<(), MaestroError> {
        let resolved = canonical(path)?;
        if self.chain.contains(&resolved) {
            let mut chain = self.chain.clone();
            chain.push(resolved);
            return Err(MaestroError::FlowCycle { chain });
        }
        let flow = FlowFile::load(path)?;
        let mut call_env = EnvScope::default();
        for (name, value) in env {
            call_env.bind(name.clone(), value.clone());
        }
        self.chain.push(resolved);
        let header = self.header(&flow, scope, &call_env, false);
        let inner = FlowCtx {
            flow: &flow,
            app_id: header.app_id.or_else(|| ctx.app_id.clone()),
            scope: header.scope,
        };
        let outcome = self.commands(&inner, &flow.commands);
        self.chain.pop();
        outcome
    }

    fn repeat(
        &mut self,
        ctx: &FlowCtx<'_>,
        command: &Command,
        args: &Value,
        label: Option<String>,
    ) -> Result<(), MaestroError> {
        let location = command.location.clone();
        match repeat_call(args) {
            Ok((times, values)) => {
                if let Some(label) = label {
                    self.lines.push(Line::Comment(label));
                }
                let nested = ctx.flow.nested(command, "commands", values);
                for _ in 0..times {
                    self.commands(ctx, &nested)?;
                }
                Ok(())
            }
            Err(reason) => {
                self.refuse(location, "repeat", reason);
                Ok(())
            }
        }
    }
}

fn canonical(path: &Path) -> Result<PathBuf, MaestroError> {
    fs::canonicalize(path).map_err(|source| MaestroError::Read {
        path: path.to_path_buf(),
        source,
    })
}

#[cfg(test)]
#[path = "import_tests.rs"]
mod tests;
