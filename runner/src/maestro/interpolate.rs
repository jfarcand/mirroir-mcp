// ABOUTME: Resolves Maestro `${…}` parameters against a flow's env scope, or hands them to the runner's own substitution.
// ABOUTME: `${VAR}` and `${VAR || "default"}` cross; any other `${…}` is JavaScript and is refused by name.

use std::collections::HashMap;

/// Opens a Maestro parameter expression.
const OPEN: &str = "${";
/// Closes it.
const CLOSE: char = '}';
/// The JavaScript fallback operator Maestro documents for defaults.
const OR: &str = "||";

/// The env constants in scope for one flow: its header `env:`, a `runFlow`'s
/// `env:`, and those inherited from the calling flow.
///
/// A name in scope resolves at import time, as Maestro resolves it when the
/// flow runs. A name not in scope is a parameter Maestro reads from
/// `-e KEY=value`; it is written as `${KEY}`, which mirroir-run substitutes
/// from the environment when it loads the scenario.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EnvScope {
    values: HashMap<String, String>,
}

impl EnvScope {
    /// The value bound to `name`, if any.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    /// Bind `name` to an already-resolved `value`.
    pub fn bind(&mut self, name: String, value: String) {
        self.values.insert(name, value);
    }
}

/// Resolve every `${…}` in `text` against `scope`.
///
/// * `${VAR}` in scope → its value; out of scope → `${VAR}`.
/// * `${VAR || "default"}` (or single quotes) in scope with a non-empty value
///   → the value; otherwise in scope → `default`; out of scope →
///   `${VAR:-default}`. JavaScript's `||` and the shell's `:-` agree: both
///   take the default for an unset *or empty* value.
///
/// # Errors
///
/// The reason, for an unclosed `${`, or an expression that is any other
/// JavaScript (`${output.x}`, `${A + B}`, `${parseInt(N)}`) — nothing in
/// mirroir evaluates JavaScript.
pub fn interpolate(text: &str, scope: &EnvScope) -> Result<String, String> {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(OPEN) {
        out.push_str(&rest[..start]);
        let after = &rest[start + OPEN.len()..];
        let Some(end) = after.find(CLOSE) else {
            return Err(format!("`{text}` opens `${{` and never closes it"));
        };
        out.push_str(&resolve(after[..end].trim(), scope)?);
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

fn resolve(expression: &str, scope: &EnvScope) -> Result<String, String> {
    if is_identifier(expression) {
        return Ok(scope
            .get(expression)
            .map_or_else(|| format!("${{{expression}}}"), str::to_owned));
    }
    if let Some((name, default)) = with_default(expression) {
        return Ok(match scope.get(name) {
            Some(value) if !value.is_empty() => value.to_owned(),
            Some(_) => default.to_owned(),
            None => format!("${{{name}:-{default}}}"),
        });
    }
    Err(format!(
        "`${{{expression}}}` is a JavaScript expression; mirroir-run substitutes only `${{VAR}}` and `${{VAR:-default}}`"
    ))
}

/// `NAME || "default"` / `NAME || 'default'` → `(NAME, default)`.
fn with_default(expression: &str) -> Option<(&str, &str)> {
    let (name, default) = expression.split_once(OR)?;
    let name = name.trim();
    let default = default.trim();
    let quoted = ['"', '\''].into_iter().find_map(|quote| {
        default
            .strip_prefix(quote)
            .and_then(|inner| inner.strip_suffix(quote))
            .filter(|inner| !inner.contains(quote))
    })?;
    is_identifier(name).then_some((name, quoted))
}

fn is_identifier(text: &str) -> bool {
    let mut chars = text.chars();
    chars
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic() || first == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope(pairs: &[(&str, &str)]) -> EnvScope {
        let mut scope = EnvScope::default();
        for (name, value) in pairs {
            scope.bind((*name).to_owned(), (*value).to_owned());
        }
        scope
    }

    #[test]
    fn a_constant_in_scope_resolves_at_import() -> Result<(), String> {
        let out = interpolate("hi ${USER}!", &scope(&[("USER", "ada")]))?;
        assert_eq!(out, "hi ada!");
        Ok(())
    }

    #[test]
    fn a_parameter_out_of_scope_is_left_to_the_runner() -> Result<(), String> {
        assert_eq!(interpolate("${PASSWORD}", &scope(&[]))?, "${PASSWORD}");
        Ok(())
    }

    #[test]
    fn a_javascript_default_becomes_a_shell_default() -> Result<(), String> {
        let empty = scope(&[]);
        assert_eq!(
            interpolate("${USER_ID || \"test_user_1\"}", &empty)?,
            "${USER_ID:-test_user_1}"
        );
        assert_eq!(interpolate("${U || 'x'}", &scope(&[("U", "")]))?, "x");
        assert_eq!(interpolate("${U || 'x'}", &scope(&[("U", "y")]))?, "y");
        Ok(())
    }

    #[test]
    fn any_other_javascript_is_refused() {
        for text in ["${output.token}", "${A + B}", "${parseInt(N)}", "${OPEN"] {
            assert!(interpolate(text, &scope(&[])).is_err(), "{text} crossed");
        }
    }
}
