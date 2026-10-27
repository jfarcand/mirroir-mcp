// ABOUTME: Process-target step argument types — spawn, wait_port, kill, assert_log{,_clean}.
// ABOUTME: Split from step.rs to keep the grammar file under the 500-line ceiling; behavior unchanged.

use std::collections::HashMap;

use serde::Deserialize;

/// Arguments for `spawn` — start a subprocess managed by the process target.
/// Either `from: SAMPLE.md` (read the sample's boot block) or an inline
/// `command:` is required at dispatch time; the parser accepts both shapes
/// and lets the dispatcher decide.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct SpawnArgs {
    /// Identifier for this subprocess; later `kill { id: … }` targets the same id.
    pub id: String,
    /// `SAMPLE.md` literal when the spawn config lives in the sample's boot block.
    #[serde(default)]
    pub from: Option<String>,
    /// Inline command line.
    #[serde(default)]
    pub command: Option<String>,
    /// Working directory for the command.
    #[serde(default)]
    pub cwd: Option<String>,
    /// Environment variable overrides.
    #[serde(default)]
    pub env: HashMap<String, String>,
    /// Optional ceiling on subprocess runtime, in seconds.
    #[serde(default)]
    pub timeout_s: Option<u32>,
    /// Required exit code (defaults to 0 at dispatch time).
    #[serde(default)]
    pub expect_exit: Option<i32>,
    /// When set, capture stdout into the named runner variable for `${var}` substitution.
    #[serde(default)]
    pub capture_stdout: Option<String>,
}

/// Arguments for `wait_port` — block until a TCP port reaches the expected state.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct WaitPortArgs {
    /// TCP port to probe.
    pub port: u16,
    /// Timeout in seconds before the step fails.
    pub timeout_s: u32,
    /// Whether to wait for the port to open or close. Defaults to `Open`.
    #[serde(default = "default_port_expect")]
    pub expect: PortState,
}

/// Expected port state for `wait_port`.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PortState {
    /// Port should be accepting connections.
    Open,
    /// Port should refuse connections (process is gone / not listening).
    Closed,
}

fn default_port_expect() -> PortState {
    PortState::Open
}

/// Arguments for `kill` — terminate a previously-spawned subprocess.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct KillArgs {
    /// Identifier of the subprocess to kill (matches a prior `spawn { id }`).
    pub id: String,
    /// Grace period before `SIGKILL`, in seconds. Defaults to `5`.
    #[serde(default = "default_grace_s")]
    pub grace_s: u32,
    /// Optional cleanup shell command to run after the process exits.
    #[serde(default)]
    pub cleanup: Option<String>,
}

fn default_grace_s() -> u32 {
    5
}

/// Arguments for `assert_log` — single-pattern regex check against captured logs.
///
/// The dispatcher polls the log file until the pattern appears or `timeout_s`
/// elapses (Playwright "expect-with-retry" semantics). Omitting `timeout_s`
/// accepts the dispatcher's default.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct AssertLogArgs {
    /// Subprocess id whose log file to scan.
    pub id: String,
    /// Regex pattern. Must match at least one captured line to pass.
    pub pattern: String,
    /// Optional regex flag string (e.g. `"i"`, `"m"`, `"im"`).
    #[serde(default)]
    pub flags: Option<String>,
    /// Optional auto-retry deadline in seconds. The dispatcher polls the log
    /// every ~100ms until the pattern matches or this many seconds elapse.
    /// `None` accepts the dispatcher's default (5 s).
    #[serde(default)]
    pub timeout_s: Option<u32>,
}

/// Arguments for `assert_log_clean` — fail if any `deny` matches a line and no `allow` matches the same line.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct AssertLogCleanArgs {
    /// Subprocess id whose log file to scan.
    pub id: String,
    /// Patterns that, if matched, fail the step.
    pub deny: Vec<LogPattern>,
    /// Patterns that exempt an otherwise-deny-matching line from failing the step.
    #[serde(default)]
    pub allow: Vec<LogPattern>,
}

/// A regex pattern with optional flags, used by log assertions.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct LogPattern {
    /// The regex pattern body.
    pub pattern: String,
    /// Optional flags (e.g. `"i"` for case-insensitive).
    #[serde(default)]
    pub flags: Option<String>,
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use serde_norway::Deserializer;
    use serde_norway::with::singleton_map_recursive;

    use super::PortState;
    use crate::parser::step::SkillStep;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn parse(yaml: &str) -> StdResult<SkillStep, serde_norway::Error> {
        singleton_map_recursive::deserialize(Deserializer::from_str(yaml))
    }

    fn fail<T>(reason: String) -> StdResult<T, Box<dyn StdError>> {
        Err(reason.into())
    }

    #[test]
    fn spawn_with_id_and_from() -> TestResult {
        let SkillStep::Spawn(args) = parse("spawn: { id: server, from: SAMPLE.md }")? else {
            return fail("expected Spawn variant".to_owned());
        };
        assert_eq!(args.id, "server");
        assert_eq!(args.from.as_deref(), Some("SAMPLE.md"));
        assert!(args.command.is_none());
        Ok(())
    }

    #[test]
    fn wait_port_with_defaults() -> TestResult {
        let SkillStep::WaitPort(args) = parse("wait_port: { port: 8081, timeout_s: 120 }")? else {
            return fail("expected WaitPort variant".to_owned());
        };
        assert_eq!(args.port, 8081);
        assert_eq!(args.timeout_s, 120);
        assert_eq!(args.expect, PortState::Open);
        Ok(())
    }

    #[test]
    fn assert_log_clean_with_deny_and_allow() -> TestResult {
        let yaml = r#"
assert_log_clean:
  id: server
  deny:
    - { pattern: "^\\s*ERROR\\b", flags: "im" }
    - { pattern: "BeanInstantiationException" }
  allow:
    - { pattern: "Disabled retry on ERROR\\.RATE_LIMIT" }
"#;
        let SkillStep::AssertLogClean(args) = parse(yaml)? else {
            return fail("expected AssertLogClean variant".to_owned());
        };
        assert_eq!(args.id, "server");
        assert_eq!(args.deny.len(), 2);
        assert_eq!(args.allow.len(), 1);
        assert_eq!(args.deny[0].flags.as_deref(), Some("im"));
        Ok(())
    }
}
