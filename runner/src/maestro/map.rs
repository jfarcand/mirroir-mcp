// ABOUTME: The Maestro → mirroir mapping table for leaf commands: each yields scenario steps or the reason it cannot.
// ABOUTME: Steps are built as the YAML values the runner's own parser reads, so its defaults stay the single source.

use std::collections::HashMap;

use serde_norway::{Mapping, Value};

use crate::maestro::error::MaestroError;
use crate::maestro::interpolate::EnvScope;
use crate::maestro::map_gestures::{
    SCROLL_SWIPE, erase_text, extended_wait_until, no_arguments, press_key, scroll_until_visible,
    set_airplane_mode, swipe,
};
use crate::maestro::refused::refusal;
use crate::maestro::selector::{Fields, scalar_text, selector_label, take_text_selector};

/// How long Maestro's `assertVisible` retries before failing, per its docs.
const ASSERT_VISIBLE_TIMEOUT_S: u64 = 7;

/// A scenario step as the YAML the runner reads: `- <kind>: <args>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepValue {
    /// The step key (`tap`, `wait_for`, …).
    pub kind: &'static str,
    /// Its argument: a string shorthand, a record, or `null`.
    pub args: Value,
}

impl StepValue {
    /// `- <kind>: "<text>"`.
    #[must_use]
    pub fn text(kind: &'static str, text: &str) -> Self {
        Self {
            kind,
            args: Value::String(text.to_owned()),
        }
    }

    /// `- <kind>: { <fields> }`.
    #[must_use]
    pub fn record(kind: &'static str, fields: Vec<(&str, Value)>) -> Self {
        let mut map = Mapping::new();
        for (key, value) in fields {
            map.insert(Value::String(key.to_owned()), value);
        }
        Self {
            kind,
            args: Value::Mapping(map),
        }
    }

    /// `- reset_app: "<app>"`.
    #[must_use]
    pub fn reset_app(app: &str) -> Self {
        Self::text("reset_app", app)
    }
}

/// `--app <appId>=<name>`: the home-screen name Spotlight finds for a bundle id.
#[derive(Debug, Clone, Default)]
pub struct AppNames {
    names: HashMap<String, String>,
}

impl AppNames {
    /// Parse `--app` arguments.
    ///
    /// # Errors
    ///
    /// [`MaestroError::AppMapping`] for an argument that is not `id=name`.
    pub fn parse(arguments: &[String]) -> Result<Self, MaestroError> {
        let mut names = HashMap::new();
        for argument in arguments {
            let Some((id, name)) = argument.split_once('=') else {
                return Err(MaestroError::AppMapping {
                    value: argument.clone(),
                });
            };
            let (id, name) = (id.trim(), name.trim());
            if id.is_empty() || name.is_empty() {
                return Err(MaestroError::AppMapping {
                    value: argument.clone(),
                });
            }
            names.insert(id.to_owned(), name.to_owned());
        }
        Ok(Self { names })
    }

    /// The name to launch for `app_id`.
    ///
    /// # Errors
    ///
    /// The reason, when no `--app` maps it.
    pub fn display_name(&self, app_id: &str) -> Result<String, String> {
        self.names.get(app_id).cloned().ok_or_else(|| {
            format!(
                "`{app_id}` is a bundle id; mirroir launches apps by home-screen name through Spotlight — pass `--app {app_id}=<name>`"
            )
        })
    }
}

/// What a leaf command maps against: the flow's app, `--app`, and env scope.
#[derive(Debug, Clone, Copy)]
pub struct LeafContext<'a> {
    /// The flow header's `appId`, inherited by subflows that name none.
    pub app_id: Option<&'a str>,
    /// `--app` mappings.
    pub apps: &'a AppNames,
    /// Env constants in scope.
    pub scope: &'a EnvScope,
}

impl LeafContext<'_> {
    fn app_name(&self, explicit: Option<&Value>) -> Result<String, String> {
        let id = match explicit {
            Some(value) => scalar_text(value, self.scope)?,
            None => self
                .app_id
                .map(str::to_owned)
                .ok_or("the flow names no `appId` and the command names none")?,
        };
        self.apps.display_name(&id)
    }
}

/// Collects every reason one command cannot cross, so the user sees them all.
#[derive(Debug, Default)]
pub struct Reasons(pub Vec<String>);

impl Reasons {
    /// Keep `result`'s value, or record its reason.
    pub fn check<T>(&mut self, result: Result<T, String>) -> Option<T> {
        result.map_err(|reason| self.0.push(reason)).ok()
    }

    /// Record every key `fields` still holds as unmapped.
    pub fn leftover(&mut self, fields: &Fields) {
        for key in fields.leftover() {
            self.0
                .push(format!("`{key}` is not an option the import maps"));
        }
    }

    /// `steps`, or every reason recorded.
    ///
    /// # Errors
    ///
    /// The joined reasons, when any were recorded.
    pub fn finish(self, steps: Vec<StepValue>) -> Result<Vec<StepValue>, String> {
        if self.0.is_empty() {
            Ok(steps)
        } else {
            Err(self.0.join("; "))
        }
    }
}

/// Map one leaf command (anything but `runFlow` / `repeat`) to steps.
///
/// `args` is the command's argument with `label:` and `optional:` already
/// taken by the caller: `Null` for the bare form, a scalar, or a map.
///
/// # Errors
///
/// The reason the command, or one of its arguments, has no faithful
/// equivalent.
pub fn map_leaf(name: &str, args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    if let Some(reason) = refusal(name) {
        return Err(reason.to_owned());
    }
    match name {
        "launchApp" => launch_app(args, ctx),
        "stopApp" | "killApp" => stop_app(args, ctx),
        "tapOn" => tap_on(args, ctx),
        "longPressOn" => selector_step(args, ctx, |label| StepValue::text("long_press", &label)),
        "assertVisible" => selector_step(args, ctx, |label| {
            StepValue::record(
                "wait_for",
                vec![
                    ("label", Value::String(label)),
                    ("timeout_s", Value::from(ASSERT_VISIBLE_TIMEOUT_S)),
                ],
            )
        }),
        "assertNotVisible" => selector_step(args, ctx, |label| {
            StepValue::text("assert_not_visible", &label)
        }),
        "inputText" => single_text(args, ctx, "text", |text| StepValue::text("type", &text)),
        "openLink" => open_link(args, ctx),
        "takeScreenshot" => single_text(args, ctx, "path", |name| {
            StepValue::text("screenshot", &name)
        }),
        "eraseText" => erase_text(args),
        "pressKey" => press_key(args, ctx),
        "scroll" => no_arguments(args, vec![StepValue::text("swipe", SCROLL_SWIPE)]),
        "swipe" => swipe(args, ctx),
        "scrollUntilVisible" => scroll_until_visible(args, ctx),
        "extendedWaitUntil" => extended_wait_until(args, ctx),
        "setAirplaneMode" => set_airplane_mode(args, ctx),
        _ => Err("not a Maestro command the import knows".to_owned()),
    }
}

/// `args` as fields, when it is a map.
#[must_use]
pub fn fields_of(args: &Value) -> Option<Fields> {
    match args {
        Value::Mapping(map) => Some(Fields::new(map.clone())),
        _ => None,
    }
}

fn launch_app(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let Some(mut fields) = fields_of(args) else {
        let explicit = (!args.is_null()).then_some(args);
        let app = ctx.app_name(explicit)?;
        return Ok(vec![
            StepValue::reset_app(&app),
            StepValue::text("launch", &app),
        ]);
    };
    let mut reasons = Reasons::default();
    let app = reasons.check(ctx.app_name(fields.take("appId").as_ref()));
    let stop = match fields.take("stopApp") {
        None => true,
        Some(Value::Bool(stop)) => stop,
        Some(_) => {
            reasons.0.push("`stopApp` must be true or false".to_owned());
            true
        }
    };
    let inert = Value::Bool(false);
    reasons.check(fields.refuse_unless(
        "clearState",
        &inert,
        "a stock iPhone exposes no reset of one app's data",
    ));
    reasons.check(fields.refuse_unless(
        "clearKeychain",
        &inert,
        "a stock iPhone exposes no Keychain reset",
    ));
    reasons.check(fields.refuse_unless(
        "permissions",
        &Value::Null,
        "permissions cannot be pre-set on a stock iPhone",
    ));
    reasons.check(fields.refuse_unless(
        "arguments",
        &Value::Null,
        "Spotlight launches pass no launch arguments",
    ));
    reasons.leftover(&fields);
    let steps = app.map_or_else(Vec::new, |app| {
        let launch = StepValue::text("launch", &app);
        if stop {
            vec![StepValue::reset_app(&app), launch]
        } else {
            vec![launch]
        }
    });
    reasons.finish(steps)
}

fn stop_app(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let Some(mut fields) = fields_of(args) else {
        let explicit = (!args.is_null()).then_some(args);
        return Ok(vec![StepValue::reset_app(&ctx.app_name(explicit)?)]);
    };
    let mut reasons = Reasons::default();
    let app = reasons.check(ctx.app_name(fields.take("appId").as_ref()));
    reasons.leftover(&fields);
    reasons.finish(
        app.map(|app| StepValue::reset_app(&app))
            .into_iter()
            .collect(),
    )
}

fn tap_on(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let Some(mut fields) = fields_of(args) else {
        return Ok(vec![StepValue::text(
            "tap",
            &selector_label(args, ctx.scope)?,
        )]);
    };
    let mut reasons = Reasons::default();
    let label = reasons.check(take_text_selector(&mut fields, ctx.scope));
    let times = fields.take("repeat").map_or(Some(1), |value| {
        reasons.check(
            value
                .as_u64()
                .filter(|times| *times > 0)
                .ok_or_else(|| "`repeat` must be a positive whole number".to_owned()),
        )
    });
    reasons.check(fields.refuse_unless(
        "delay",
        &Value::Null,
        "mirroir spaces repeated taps by its own input timing",
    ));
    reasons.check(fields.refuse_unless(
        "retryTapIfNoChange",
        &Value::Bool(false),
        "mirroir taps once and has no view hierarchy to compare",
    ));
    reasons.check(fields.refuse_unless(
        "waitToSettleTimeoutMs",
        &Value::Null,
        "mirroir has no per-step settle bound",
    ));
    reasons.leftover(&fields);
    let steps = match (label, times) {
        (Some(label), Some(times)) => (0..times).map(|_| StepValue::text("tap", &label)).collect(),
        _ => Vec::new(),
    };
    reasons.finish(steps)
}

/// A command whose whole argument is one selector.
fn selector_step(
    args: &Value,
    ctx: LeafContext<'_>,
    build: impl Fn(String) -> StepValue,
) -> Result<Vec<StepValue>, String> {
    if args.is_null() {
        return Err("names no element".to_owned());
    }
    Ok(vec![build(selector_label(args, ctx.scope)?)])
}

/// A command taking one text, as the shorthand or under `key`.
fn single_text(
    args: &Value,
    ctx: LeafContext<'_>,
    key: &str,
    build: impl Fn(String) -> StepValue,
) -> Result<Vec<StepValue>, String> {
    let Some(mut fields) = fields_of(args) else {
        return Ok(vec![build(scalar_text(args, ctx.scope)?)]);
    };
    let mut reasons = Reasons::default();
    let text = match fields.take(key) {
        Some(value) => reasons.check(scalar_text(&value, ctx.scope)),
        None => reasons.check(Err::<String, _>(format!("`{key}` is required"))),
    };
    reasons.leftover(&fields);
    reasons.finish(text.map(build).into_iter().collect())
}

fn open_link(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let Some(mut fields) = fields_of(args) else {
        return Ok(vec![StepValue::text(
            "open_url",
            &scalar_text(args, ctx.scope)?,
        )]);
    };
    let mut reasons = Reasons::default();
    let inert = Value::Bool(false);
    reasons.check(fields.refuse_unless(
        "autoVerify",
        &inert,
        "Android App Link verification has no iOS meaning",
    ));
    reasons.check(fields.refuse_unless(
        "browser",
        &inert,
        "`open_url` opens the link as iOS routes it, never forcing the browser",
    ));
    let url = match fields.take("link") {
        Some(link) => reasons.check(scalar_text(&link, ctx.scope)),
        None => reasons.check(Err::<String, _>("`link` is required".to_owned())),
    };
    reasons.leftover(&fields);
    reasons.finish(
        url.map(|url| StepValue::text("open_url", &url))
            .into_iter()
            .collect(),
    )
}

#[cfg(test)]
#[path = "map_tests.rs"]
mod tests;
