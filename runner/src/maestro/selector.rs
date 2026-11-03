// ABOUTME: Maps Maestro element selectors to the OCR label mirroir taps, and refuses every selector OCR cannot honour.
// ABOUTME: Also holds `Fields`, the take-what-you-map view of a command's argument map that reports what is left over.

use serde_norway::{Mapping, Value};

use crate::maestro::interpolate::{EnvScope, interpolate};

/// Regex syntax with no literal reading: wildcards, classes, alternation,
/// anchors, escapes and counted repeats. Maestro matches a text selector when
/// it equals the element text or matches it as a regex; mirroir matches the
/// literal, so a value carrying any of these is refused rather than tapped as
/// characters its author never meant literally.
const PATTERN_MARKERS: [&str; 7] = [".*", ".+", "\\", "[", "|", "^", "{"];

/// Maestro's "text contains" idiom, which mirroir's substring match tier
/// expresses directly.
const CONTAINS_WRAPPER: &str = ".*";

/// A command's argument map, consumed key by key. What no mapping took is
/// [`Fields::leftover`], so an argument is never silently dropped.
#[derive(Debug, Clone, Default)]
pub struct Fields {
    map: Mapping,
}

impl Fields {
    /// View `map` as fields to consume.
    #[must_use]
    pub const fn new(map: Mapping) -> Self {
        Self { map }
    }

    /// Remove and return `key`.
    pub fn take(&mut self, key: &str) -> Option<Value> {
        self.map.remove(key)
    }

    /// Remove `key`, refusing it unless it is absent or equal to `inert` —
    /// the value that means "do nothing" (`optional: false`).
    ///
    /// # Errors
    ///
    /// `reason`, when the key carries any other value.
    pub fn refuse_unless(&mut self, key: &str, inert: &Value, reason: &str) -> Result<(), String> {
        match self.take(key) {
            Some(value) if &value != inert => Err(format!("`{key}`: {reason}")),
            _ => Ok(()),
        }
    }

    /// The fields not yet consumed, as the map they came from.
    #[must_use]
    pub fn into_value(self) -> Value {
        Value::Mapping(self.map)
    }

    /// Keys no mapping consumed.
    #[must_use]
    pub fn leftover(&self) -> Vec<String> {
        self.map
            .keys()
            .map(|key| match key {
                Value::String(name) => name.clone(),
                other => format!("{other:?}"),
            })
            .collect()
    }
}

/// Why a selector key has no OCR equivalent; `None` for a key that is not a
/// selector key at all.
fn selector_key_reason(key: &str) -> Option<&'static str> {
    Some(match key {
        "id" => {
            "id selectors match the accessibility tree, which iPhone Mirroring does not expose; mirroir finds elements by OCR text"
        }
        "index" => "mirroir taps the best OCR match and has no nth-match selection on iOS",
        "point" => {
            "coordinate taps have no step in the scenario grammar; mirroir targets OCR labels"
        }
        "enabled" | "checked" | "focused" | "selected" => {
            "element state comes from the accessibility tree, which the mirror does not expose"
        }
        "above"
        | "below"
        | "leftOf"
        | "rightOf"
        | "childOf"
        | "containsChild"
        | "containsDescendants" => {
            "relational selectors resolve against the view hierarchy, which the mirror does not expose"
        }
        "width" | "height" | "tolerance" | "traits" => {
            "size and trait selectors read the view hierarchy, which the mirror does not expose"
        }
        "css" => "css selectors address web pages; an iOS flow has none",
        _ => return None,
    })
}

/// Consume the selector keys of `fields` and return the OCR label to target.
///
/// `fields` is the command's own argument map: Maestro mixes selector keys
/// (`text`, `id`, `below`, …) with command options (`repeat`, `label`, …), so
/// only selector keys are taken here and the caller consumes the rest.
///
/// # Errors
///
/// Every reason the selector cannot cross, joined.
pub fn take_text_selector(fields: &mut Fields, scope: &EnvScope) -> Result<String, String> {
    let mut reasons = Vec::new();
    for key in fields.leftover() {
        if let Some(reason) = selector_key_reason(&key) {
            fields.take(&key);
            reasons.push(format!("`{key}`: {reason}"));
        }
    }
    let text = fields
        .take("text")
        .map(|value| scalar_text(&value, scope).and_then(|text| literal_label(&text)));
    match (text, reasons.is_empty()) {
        (Some(Ok(label)), true) => Ok(label),
        (Some(Err(reason)), _) => {
            reasons.push(reason);
            Err(reasons.join("; "))
        }
        (None, true) => Err("the selector names no `text` for mirroir to find".to_owned()),
        (Some(Ok(_)) | None, false) => Err(reasons.join("; ")),
    }
}

/// The OCR label for a selector given either as the string shorthand or as
/// a selector map (`element:` of `scrollUntilVisible`, `visible:` of
/// `extendedWaitUntil`).
///
/// # Errors
///
/// Every reason the selector cannot cross, joined.
pub fn selector_label(value: &Value, scope: &EnvScope) -> Result<String, String> {
    match value {
        Value::Mapping(map) => {
            let mut fields = Fields::new(map.clone());
            let label = take_text_selector(&mut fields, scope)?;
            let leftover = fields.leftover();
            if leftover.is_empty() {
                Ok(label)
            } else {
                Err(format!("unknown selector key(s): {}", leftover.join(", ")))
            }
        }
        other => scalar_text(other, scope).and_then(|text| literal_label(&text)),
    }
}

/// A scalar argument as text, with its `${…}` parameters resolved.
///
/// # Errors
///
/// The reason, for a non-scalar or a JavaScript expression.
pub fn scalar_text(value: &Value, scope: &EnvScope) -> Result<String, String> {
    let raw = match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Bool(flag) => flag.to_string(),
        _ => return Err("expected a text value".to_owned()),
    };
    interpolate(&raw, scope)
}

/// The literal OCR label a Maestro text selector means.
///
/// `.*literal.*` is Maestro's "contains" and becomes `literal`, which
/// mirroir's matcher finds exactly first and then as a substring.
fn literal_label(text: &str) -> Result<String, String> {
    let inner = text
        .strip_prefix(CONTAINS_WRAPPER)
        .and_then(|rest| rest.strip_suffix(CONTAINS_WRAPPER))
        .unwrap_or(text);
    if inner.trim().is_empty() {
        return Err(format!(
            "`{text}` names no text for mirroir to find on screen"
        ));
    }
    if PATTERN_MARKERS.iter().any(|marker| inner.contains(marker)) {
        return Err(format!(
            "`{text}` is a regular expression; mirroir matches OCR text literally, so only a literal or `.*literal.*` crosses"
        ));
    }
    Ok(inner.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(yaml: &str) -> Result<Mapping, String> {
        serde_norway::from_str(yaml).map_err(|e| e.to_string())
    }

    #[test]
    fn text_and_contains_regex_cross() -> Result<(), String> {
        let scope = EnvScope::default();
        assert_eq!(
            selector_label(&Value::String("Login".to_owned()), &scope)?,
            "Login"
        );
        assert_eq!(
            selector_label(&Value::String(".*Save.*".to_owned()), &scope)?,
            "Save"
        );
        assert_eq!(
            selector_label(&Value::String("Forgot password?".to_owned()), &scope)?,
            "Forgot password?"
        );
        Ok(())
    }

    #[test]
    fn regex_and_hierarchy_selectors_are_refused_with_every_reason() -> Result<(), String> {
        let scope = EnvScope::default();
        assert!(selector_label(&Value::String("Order [0-9]+".to_owned()), &scope).is_err());
        let mut fields = Fields::new(map("{ text: Next, below: Password, id: next_btn }")?);
        let reason = take_text_selector(&mut fields, &scope)
            .err()
            .ok_or("hierarchy selector crossed")?;
        assert!(
            reason.contains("`below`") && reason.contains("`id`"),
            "{reason}"
        );
        assert_eq!(fields.leftover(), Vec::<String>::new());
        Ok(())
    }
}
