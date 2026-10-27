// ABOUTME: ${VAR} substitution + SAMPLE.md synthesis helpers for compose.
// ABOUTME: Builds the layered substitution env, rewrites fenced-yaml blocks, and renders the SAMPLE.md contract.

use std::collections::HashMap;
use std::env as std_env;
use std::fmt::Write as _;

use crate::error::{Result, RunnerError};
use crate::parser::archetype::ArchetypeRequiredVar;
use crate::parser::env::substitute as env_substitute;
use crate::parser::mirroir::PlanEntry;
use crate::parser::substitute::substitute_value;

/// Build the layered `${VAR}` substitution environment for a plan entry.
///
/// Precedence (lowest → highest): process env, archetype defaults, suite env,
/// `entry.boot.env`, then `entry.vars` (instance wins).
#[must_use]
pub fn build_substitution_env(
    entry: &PlanEntry,
    suite_env: &HashMap<String, String>,
    archetype_required_vars: &[ArchetypeRequiredVar],
) -> HashMap<String, String> {
    let mut env: HashMap<String, String> = std_env::vars().collect();
    // Archetype defaults first (lowest priority), then suite env, then entry.boot.env,
    // then entry.vars (highest priority — instance wins).
    for spec in archetype_required_vars {
        if let Some(default) = &spec.default {
            env.insert(spec.name.clone(), default.clone());
        }
    }
    for (k, v) in suite_env {
        env.insert(k.clone(), v.clone());
    }
    for (k, v) in &entry.boot.env {
        env.insert(k.clone(), v.clone());
    }
    for (k, v) in &entry.vars {
        env.insert(k.clone(), v.clone());
    }
    env
}

/// Substitute a markdown file's fenced yaml block while preserving the surrounding prose.
///
/// # Errors
///
/// Propagates [`RunnerError::YamlParse`] when the fenced body fails to parse or
/// re-serialize during substitution.
pub fn substitute_markdown_with_yaml(raw: &str, env: &HashMap<String, String>) -> Result<String> {
    let Some((start_idx, end_idx, body)) = locate_fenced_yaml(raw) else {
        // No yaml block — substitute nothing; return the markdown verbatim.
        return Ok(raw.to_owned());
    };
    let substituted_body = substitute_yaml_text(body, env)?;
    let mut out = String::with_capacity(raw.len() + substituted_body.len());
    out.push_str(&raw[..start_idx]);
    out.push_str(&substituted_body);
    out.push_str(&raw[end_idx..]);
    Ok(out)
}

/// Substitute a plain yaml string: parse → walk → re-serialize.
///
/// # Errors
///
/// Propagates [`RunnerError::YamlParse`] on parse or serialize failure.
pub fn substitute_yaml_text(yaml: &str, env: &HashMap<String, String>) -> Result<String> {
    let mut value: serde_norway::Value =
        serde_norway::from_str(yaml).map_err(|source| RunnerError::YamlParse {
            file: "(compose-substitute)".to_owned(),
            source,
        })?;
    substitute_value(&mut value, env)?;
    serde_norway::to_string(&value).map_err(|source| RunnerError::YamlParse {
        file: "(compose-substitute serialize)".to_owned(),
        source,
    })
}

/// Find the inclusive byte range of the body of the first fenced `yaml` block.
fn locate_fenced_yaml(markdown: &str) -> Option<(usize, usize, &str)> {
    let bytes = markdown.as_bytes();
    let needle = b"```yaml\n";
    let yml_needle = b"```yml\n";
    let mut start_fence_idx = None;
    let mut i = 0;
    while i + needle.len() <= bytes.len() {
        if bytes[i..i + needle.len()] == *needle {
            start_fence_idx = Some(i + needle.len());
            break;
        }
        if i + yml_needle.len() <= bytes.len() && bytes[i..i + yml_needle.len()] == *yml_needle {
            start_fence_idx = Some(i + yml_needle.len());
            break;
        }
        i += 1;
    }
    let start = start_fence_idx?;
    // Closing fence: a line that starts with ```.
    let mut j = start;
    while j < bytes.len() {
        if bytes[j] == b'`' && j + 2 < bytes.len() && &bytes[j..j + 3] == b"```" {
            // Walk back to start of line.
            let mut line_start = j;
            while line_start > 0 && bytes[line_start - 1] != b'\n' {
                line_start -= 1;
            }
            if line_start == j || markdown[line_start..j].chars().all(char::is_whitespace) {
                return Some((start, line_start, &markdown[start..line_start]));
            }
        }
        j += 1;
    }
    None
}

/// Render the SAMPLE.md contract from a plan entry's boot block + flow list.
#[must_use]
pub fn synthesize_sample_md(entry: &PlanEntry, env: &HashMap<String, String>) -> String {
    // Writing to a String via `std::fmt::Write` is infallible; discard the Result.
    let mut yaml = String::new();
    let _ = writeln!(yaml, "version: 1");
    let _ = writeln!(yaml, "name: {}", yaml_scalar(&entry.name));
    let _ = writeln!(yaml, "session:");
    let _ = writeln!(yaml, "  boot_once: {}", entry.boot.boot_once);
    if let Some(port) = entry.boot.boot_ready_port {
        let _ = writeln!(yaml, "  boot_ready_port: {port}");
    }
    if let Some(timeout) = entry.boot.boot_ready_timeout_s {
        let _ = writeln!(yaml, "  boot_ready_timeout_s: {timeout}");
    }
    let _ = writeln!(yaml, "  boot:");
    let _ = writeln!(yaml, "    command: {}", yaml_scalar(&entry.boot.command));
    if let Some(cwd) = &entry.boot.cwd {
        // Substitute ${VAR} in cwd before emitting so SAMPLE.md is fully concrete.
        let cwd_resolved = expand_env_in_scalar(cwd, env);
        let _ = writeln!(yaml, "    cwd: {}", yaml_scalar(&cwd_resolved));
    }
    if let Some(timeout) = entry.boot.timeout_s {
        let _ = writeln!(yaml, "    timeout_s: {timeout}");
    }
    if !entry.boot.env.is_empty() {
        let _ = writeln!(yaml, "    env:");
        let mut keys: Vec<&String> = entry.boot.env.keys().collect();
        keys.sort();
        for k in keys {
            let v = &entry.boot.env[k];
            let _ = writeln!(yaml, "      {}: {}", yaml_scalar(k), yaml_scalar(v));
        }
    }
    let _ = writeln!(yaml, "  scenarios:");
    let _ = writeln!(yaml, "    must_pass:");
    if entry.flows.is_empty() {
        let _ = writeln!(yaml, "      []");
    } else {
        for flow in &entry.flows {
            let _ = writeln!(yaml, "      - scenarios/{flow}.yaml");
        }
    }

    let mut out = String::new();
    let _ = writeln!(out, "# {name}", name = entry.name);
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "Composed by mirroir-run. Do not hand-edit; regenerate with `mirroir-run --recompose`."
    );
    let _ = writeln!(out);
    let _ = writeln!(out, "```yaml");
    out.push_str(&yaml);
    let _ = writeln!(out, "```");
    out
}

fn expand_env_in_scalar(s: &str, env: &HashMap<String, String>) -> String {
    env_substitute(s, env).unwrap_or_else(|_| s.to_owned())
}

/// Quote a string as a YAML scalar — always quoted so embedded `:` / `#` /
/// leading whitespace are safe. Quotes any internal `"` via `\"`.
fn yaml_scalar(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}
