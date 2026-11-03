// ABOUTME: Maps Maestro's gesture, key, scroll and wait commands — swipe, scroll, eraseText, pressKey, waits.
// ABOUTME: Only Maestro's documented defaults cross where mirroir-mcp applies its own budget; any other value is refused.

use serde_norway::Value;

use crate::maestro::map::{LeafContext, Reasons, StepValue, fields_of};
use crate::maestro::selector::{scalar_text, selector_label};

/// Characters Maestro's bare `eraseText` removes.
const ERASE_TEXT_DEFAULT: u64 = 50;
/// The most characters Maestro's `eraseText` accepts.
const ERASE_TEXT_MAX: u64 = 100;
/// Milliseconds per second, for Maestro's millisecond timeouts.
const MS_PER_SECOND: u64 = 1000;
/// mirroir's key names for Maestro's `enter` and `backspace`.
const KEY_RETURN: &str = "return";
const KEY_DELETE: &str = "delete";
/// The swipe Maestro's `scroll` performs: content moves down, finger moves up.
pub const SCROLL_SWIPE: &str = "up";
/// `scrollUntilVisible` defaults, per Maestro's docs — the only values that
/// cross, since `scroll_to` in an ios block uses mirroir-mcp's own budget.
const SCROLL_DIRECTION_DEFAULT: &str = "DOWN";
const SCROLL_TIMEOUT_MS_DEFAULT: u64 = 20_000;
const SCROLL_SPEED_DEFAULT: u64 = 40;
const SCROLL_VISIBILITY_DEFAULT: u64 = 100;
/// Swipe directions mirroir's `swipe:` names, matching Maestro's finger direction.
const SWIPE_DIRECTIONS: [&str; 4] = ["up", "down", "left", "right"];

/// Maestro's `eraseText` → that many `press_key: delete`.
///
/// # Errors
///
/// The reason it cannot cross.
pub fn erase_text(args: &Value) -> Result<Vec<StepValue>, String> {
    let count = match args {
        Value::Null => ERASE_TEXT_DEFAULT,
        Value::Mapping(map) => map
            .get("charactersToErase")
            .and_then(Value::as_u64)
            .filter(|_| map.len() == 1)
            .ok_or("`eraseText` takes a count or `charactersToErase:`")?,
        other => other
            .as_u64()
            .ok_or("`eraseText` takes a whole number of characters")?,
    };
    if count > ERASE_TEXT_MAX {
        return Err(format!(
            "Maestro erases at most {ERASE_TEXT_MAX} characters; {count} is not a valid Maestro flow"
        ));
    }
    Ok((0..count)
        .map(|_| StepValue::text("press_key", KEY_DELETE))
        .collect())
}

/// Maestro's `pressKey` → `press_key` / `home`, for the keys iOS has.
///
/// # Errors
///
/// The reason it cannot cross.
pub fn press_key(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let key = scalar_text(args, ctx.scope)?;
    let normalized = key.trim().to_lowercase();
    match normalized.as_str() {
        "enter" => Ok(vec![StepValue::text("press_key", KEY_RETURN)]),
        "backspace" => Ok(vec![StepValue::text("press_key", KEY_DELETE)]),
        "home" => Ok(vec![StepValue {
            kind: "home",
            args: Value::Null,
        }]),
        "lock" | "power" | "volume up" | "volume down" => Err(format!(
            "`{key}` is a hardware button, which iPhone Mirroring does not forward"
        )),
        "back" | "tab" => Err(format!("`{key}` is an Android-only key in Maestro")),
        other if other.starts_with("remote ") || other.starts_with("tv ") => {
            Err(format!("`{key}` is an Android TV remote key"))
        }
        _ => Err(format!("`{key}` is not a key Maestro defines")),
    }
}

/// A command that takes no arguments → `steps`.
///
/// # Errors
///
/// The reason it cannot cross.
pub fn no_arguments(args: &Value, steps: Vec<StepValue>) -> Result<Vec<StepValue>, String> {
    match args {
        Value::Null => Ok(steps),
        Value::Mapping(map) if map.is_empty() => Ok(steps),
        _ => Err("takes no arguments the import maps".to_owned()),
    }
}

/// Maestro's directional `swipe` → `swipe: <direction>`.
///
/// # Errors
///
/// The reason it cannot cross.
pub fn swipe(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let mut fields = fields_of(args).ok_or("`swipe` takes a map with `direction:`")?;
    let mut reasons = Reasons::default();
    for key in ["start", "end", "from"] {
        reasons.check(fields.refuse_unless(
            key,
            &Value::Null,
            "the scenario grammar swipes by direction across the screen; point and element swipes cannot cross",
        ));
    }
    for key in ["duration", "waitToSettleTimeoutMs"] {
        reasons.check(fields.refuse_unless(
            key,
            &Value::Null,
            "mirroir swipes at its own configured speed and settle time",
        ));
    }
    let direction = fields.take("direction").and_then(|value| {
        reasons.check(scalar_text(&value, ctx.scope).and_then(|direction| {
            let lowered = direction.to_lowercase();
            SWIPE_DIRECTIONS
                .contains(&lowered.as_str())
                .then_some(lowered)
                .ok_or_else(|| format!("`{direction}` is not a swipe direction"))
        }))
    });
    reasons.leftover(&fields);
    if direction.is_none() && reasons.0.is_empty() {
        reasons.0.push("`direction` is required".to_owned());
    }
    reasons.finish(
        direction
            .map(|direction| StepValue::text("swipe", &direction))
            .into_iter()
            .collect(),
    )
}

/// Maestro's `scrollUntilVisible` (downward, default budget) → `scroll_to`.
///
/// # Errors
///
/// The reason it cannot cross.
pub fn scroll_until_visible(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let mut fields = fields_of(args).ok_or("`scrollUntilVisible` takes a map with `element:`")?;
    let mut reasons = Reasons::default();
    let label = match fields.take("element") {
        Some(element) => reasons.check(selector_label(&element, ctx.scope)),
        None => reasons.check(Err::<String, _>("`element` is required".to_owned())),
    };
    if let Some(direction) = fields.take("direction") {
        let downward = direction
            .as_str()
            .is_some_and(|d| d.eq_ignore_ascii_case(SCROLL_DIRECTION_DEFAULT));
        if !downward {
            reasons.0.push(
                "`direction`: mirroir-mcp's `scroll_to` scrolls content down only (Maestro's DOWN)"
                    .to_owned(),
            );
        }
    }
    let budget = "`scroll_to` in an ios block uses mirroir-mcp's own scroll budget";
    reasons.check(fields.refuse_unless("timeout", &Value::from(SCROLL_TIMEOUT_MS_DEFAULT), budget));
    reasons.check(fields.refuse_unless("speed", &Value::from(SCROLL_SPEED_DEFAULT), budget));
    reasons.check(fields.refuse_unless(
        "visibilityPercentage",
        &Value::from(SCROLL_VISIBILITY_DEFAULT),
        "OCR reports text it reads, not how much of an element is on screen",
    ));
    reasons.check(fields.refuse_unless(
        "centerElement",
        &Value::Bool(false),
        "`scroll_to` stops once the text is read, without centering it",
    ));
    reasons.leftover(&fields);
    reasons.finish(
        label
            .map(|label| StepValue::text("scroll_to", &label))
            .into_iter()
            .collect(),
    )
}

/// Maestro's `extendedWaitUntil: { visible, timeout }` → `wait_for` with the timeout in whole seconds, rounded up.
///
/// # Errors
///
/// The reason it cannot cross.
pub fn extended_wait_until(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let mut fields = fields_of(args).ok_or("`extendedWaitUntil` takes a map")?;
    let mut reasons = Reasons::default();
    reasons.check(fields.refuse_unless(
        "notVisible",
        &Value::Null,
        "mirroir has no wait-until-gone step; `assert_not_visible` checks once",
    ));
    let label = match fields.take("visible") {
        Some(visible) => reasons.check(selector_label(&visible, ctx.scope)),
        None if reasons.0.is_empty() => {
            reasons.check(Err::<String, _>("`visible` is required".to_owned()))
        }
        None => None,
    };
    let seconds = match fields.take("timeout") {
        Some(value) => reasons.check(
            value
                .as_u64()
                .map(|ms| ms.div_ceil(MS_PER_SECOND))
                .ok_or_else(|| "`timeout` must be a whole number of milliseconds".to_owned()),
        ),
        None => reasons.check(Err::<u64, _>(
            "`timeout` is required to bound the wait".to_owned(),
        )),
    };
    reasons.leftover(&fields);
    let steps = match (label, seconds) {
        (Some(label), Some(seconds)) => vec![StepValue::record(
            "wait_for",
            vec![
                ("label", Value::String(label)),
                ("timeout_s", Value::from(seconds)),
            ],
        )],
        _ => Vec::new(),
    };
    reasons.finish(steps)
}

/// Maestro's `setAirplaneMode` → `set_network: airplane_on|airplane_off`.
///
/// # Errors
///
/// The reason it cannot cross.
pub fn set_airplane_mode(args: &Value, ctx: LeafContext<'_>) -> Result<Vec<StepValue>, String> {
    let mode = match scalar_text(args, ctx.scope)?.to_lowercase().as_str() {
        "enabled" => "airplane_on",
        "disabled" => "airplane_off",
        other => return Err(format!("`{other}` is neither `enabled` nor `disabled`")),
    };
    Ok(vec![StepValue::text("set_network", mode)])
}
