// ABOUTME: Post-parse `${VAR}` substitution on serde_norway::Value trees — string leaves only.
// ABOUTME: Avoids Helm-class footguns (quoting / structural breakage) of pre-parse textual substitution.

use std::collections::HashMap;

use serde_norway::{Mapping, Value};

use crate::error::Result;
use crate::parser::env::substitute;

/// Substitute `${VAR}` and `${VAR:-default}` in every string leaf of `value`.
///
/// Recurses through sequences and mappings. Keys in mappings are **not**
/// substituted — that's a deliberate constraint that keeps the document
/// shape deterministic. Values that are null, booleans, numbers, or
/// tagged are left untouched.
///
/// This is the substitution model the architecture spec mandates (see
/// the "Substitution semantics" section): post-parse, string-leaves only,
/// no risk of values containing `:`, `"`, newlines, or `${...}` breaking
/// YAML structure.
///
/// # Errors
///
/// Propagates [`crate::error::RunnerError::RegexCompile`] from the
/// underlying [`substitute`] helper. In practice the regex is hardcoded
/// and cannot fail; the error is surfaced honestly rather than via `.expect()`.
pub fn substitute_value(value: &mut Value, env: &HashMap<String, String>) -> Result<()> {
    match value {
        Value::String(s) => {
            *s = substitute(s, env)?;
        }
        Value::Sequence(seq) => {
            for item in seq.iter_mut() {
                substitute_value(item, env)?;
            }
        }
        Value::Mapping(map) => {
            substitute_mapping(map, env)?;
        }
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::Tagged(_) => {}
    }
    Ok(())
}

/// Walk a `Mapping` substituting its values. Keys are deliberately preserved.
fn substitute_mapping(map: &mut Mapping, env: &HashMap<String, String>) -> Result<()> {
    // serde_norway::Mapping doesn't expose iter_mut() over (k, v) pairs that
    // lets us mutate the value while borrowing the key. Collect keys first,
    // then mutate values by key. Keys themselves are not modified.
    let keys: Vec<Value> = map.keys().cloned().collect();
    for k in keys {
        if let Some(v) = map.get_mut(&k) {
            substitute_value(v, env)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    fn as_mapping(v: Value) -> StdResult<Mapping, Box<dyn StdError>> {
        match v {
            Value::Mapping(m) => Ok(m),
            other => Err(format!("expected mapping, got {other:?}").into()),
        }
    }

    fn get_string<'a>(m: &'a Mapping, key: &str) -> StdResult<&'a str, Box<dyn StdError>> {
        match m.get(Value::String(key.to_owned())) {
            Some(Value::String(s)) => Ok(s.as_str()),
            other => Err(format!("expected string at key `{key}`, got {other:?}").into()),
        }
    }

    #[test]
    fn substitutes_string_leaf() -> TestResult {
        let mut v: Value = serde_norway::from_str("hello ${NAME}")?;
        substitute_value(&mut v, &env(&[("NAME", "world")]))?;
        assert_eq!(v, Value::String("hello world".to_owned()));
        Ok(())
    }

    #[test]
    fn substitutes_inside_mapping_value() -> TestResult {
        let yaml = "greeting: hello ${NAME}\ncount: 7\n";
        let mut v: Value = serde_norway::from_str(yaml)?;
        substitute_value(&mut v, &env(&[("NAME", "world")]))?;
        let m = as_mapping(v)?;
        assert_eq!(get_string(&m, "greeting")?, "hello world");
        // Numbers untouched.
        assert!(matches!(
            m.get(Value::String("count".to_owned())),
            Some(Value::Number(_))
        ));
        Ok(())
    }

    #[test]
    fn substitutes_inside_sequence() -> TestResult {
        let mut v: Value = serde_norway::from_str("- a/${X}\n- b/${X}\n")?;
        substitute_value(&mut v, &env(&[("X", "Y")]))?;
        let Value::Sequence(seq) = v else {
            return Err("expected sequence".into());
        };
        assert_eq!(seq[0], Value::String("a/Y".to_owned()));
        assert_eq!(seq[1], Value::String("b/Y".to_owned()));
        Ok(())
    }

    #[test]
    fn keys_are_not_substituted() -> TestResult {
        let yaml = "\"${KEY}\": \"${VAL}\"\n";
        let mut v: Value = serde_norway::from_str(yaml)?;
        substitute_value(&mut v, &env(&[("KEY", "should_not_appear"), ("VAL", "ok")]))?;
        let m = as_mapping(v)?;
        // Key still literal "${KEY}"; only the value got substituted.
        assert!(m.contains_key(Value::String("${KEY}".to_owned())));
        assert_eq!(get_string(&m, "${KEY}")?, "ok");
        Ok(())
    }

    #[test]
    fn helm_class_value_with_colon_is_safe() -> TestResult {
        // Pre-parse substitution would inject a `:` into the YAML and break
        // structure. Post-parse, the value is opaque to the parser.
        let mut v: Value = serde_norway::from_str("greeting: \"prefix ${MSG}\"")?;
        substitute_value(
            &mut v,
            &env(&[("MSG", "hello: world, line1\nline2, ${literal}")]),
        )?;
        let m = as_mapping(v)?;
        let greeting = get_string(&m, "greeting")?;
        assert!(greeting.contains("hello: world"));
        assert!(greeting.contains('\n'));
        // Document structure intact: only one key.
        assert_eq!(m.len(), 1);
        Ok(())
    }

    #[test]
    fn nulls_numbers_bools_untouched() -> TestResult {
        let mut v: Value = serde_norway::from_str("a: null\nb: 42\nc: true\n")?;
        substitute_value(&mut v, &env(&[]))?;
        let m = as_mapping(v)?;
        assert_eq!(m.get(Value::String("a".to_owned())), Some(&Value::Null));
        assert!(matches!(
            m.get(Value::String("b".to_owned())),
            Some(Value::Number(_))
        ));
        assert_eq!(
            m.get(Value::String("c".to_owned())),
            Some(&Value::Bool(true))
        );
        Ok(())
    }

    #[test]
    fn default_fallback_inline() -> TestResult {
        let mut v: Value = serde_norway::from_str("cwd: \"${MISSING:-default-path}\"")?;
        substitute_value(&mut v, &env(&[]))?;
        let m = as_mapping(v)?;
        assert_eq!(get_string(&m, "cwd")?, "default-path");
        Ok(())
    }
}
