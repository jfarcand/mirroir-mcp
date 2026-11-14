/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Pre-deserialization `${VAR}` / `${VAR:-default}` substitution on YAML text.
// ABOUTME: Matches POSIX shell semantics — empty/unset VAR resolves to default when default is given.

use std::collections::HashMap;

use regex::{Captures, Regex};

use crate::error::{Result, RunnerError};

/// Substitute `${VAR}` and `${VAR:-default}` placeholders in raw YAML text.
///
/// Semantics match POSIX shell parameter expansion:
/// * `${VAR}` → value of `VAR` in `env`, or empty string if unset.
/// * `${VAR:-default}` → value of `VAR` if set and non-empty, else `default`.
///
/// The substitution is purely textual; placeholders inside YAML strings, comments,
/// keys, or values are all replaced uniformly. Callers that need to preserve a
/// literal `${...}` must escape it before parsing (mirroir YAML has no such case).
///
/// # Errors
///
/// Returns [`RunnerError::RegexCompile`] if the internal substitution pattern
/// fails to compile. In practice this cannot happen for the hardcoded pattern,
/// but the result is surfaced honestly rather than swallowed via `.expect()`.
pub fn substitute(text: &str, env: &HashMap<String, String>) -> Result<String> {
    let re = Regex::new(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}").map_err(|source| {
        RunnerError::RegexCompile {
            pattern: "env-substitution".to_owned(),
            source,
        }
    })?;

    Ok(re
        .replace_all(text, |caps: &Captures| {
            let name = caps.get(1).map_or("", |m| m.as_str());
            let default = caps.get(2).map_or("", |m| m.as_str());
            match env.get(name) {
                Some(v) if !v.is_empty() => v.clone(),
                _ => default.to_owned(),
            }
        })
        .into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    #[test]
    fn substitutes_set_variable() -> Result<()> {
        let out = substitute("hello ${NAME}", &env(&[("NAME", "world")]))?;
        assert_eq!(out, "hello world");
        Ok(())
    }

    #[test]
    fn missing_variable_with_no_default_resolves_empty() -> Result<()> {
        let out = substitute("hello ${NAME}!", &env(&[]))?;
        assert_eq!(out, "hello !");
        Ok(())
    }

    #[test]
    fn missing_variable_with_default_uses_default() -> Result<()> {
        let out = substitute("${MISSING:-fallback}", &env(&[]))?;
        assert_eq!(out, "fallback");
        Ok(())
    }

    #[test]
    fn empty_set_variable_uses_default() -> Result<()> {
        let out = substitute("${EMPTY:-fallback}", &env(&[("EMPTY", "")]))?;
        assert_eq!(out, "fallback");
        Ok(())
    }

    #[test]
    fn set_variable_beats_default() -> Result<()> {
        let out = substitute("${VAR:-default}", &env(&[("VAR", "actual")]))?;
        assert_eq!(out, "actual");
        Ok(())
    }

    #[test]
    fn handles_login_flow_fixture_lines() -> Result<()> {
        let environment = env(&[("TEST_EMAIL", "user@example.com")]);
        assert_eq!(
            substitute("${APP_SCREEN:-LoginDemo}", &environment)?,
            "LoginDemo"
        );
        assert_eq!(
            substitute("${TEST_EMAIL}", &environment)?,
            "user@example.com"
        );
        Ok(())
    }

    #[test]
    fn leaves_unmatched_text_intact() -> Result<()> {
        let out = substitute("- tap: \"$NOT_A_PLACEHOLDER\"", &env(&[]))?;
        assert_eq!(out, "- tap: \"$NOT_A_PLACEHOLDER\"");
        Ok(())
    }
}
