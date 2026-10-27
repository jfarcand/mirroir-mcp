// ABOUTME: SAMPLE.md parser — extracts the first fenced ```yaml block from a markdown file.
// ABOUTME: Yields SampleManifest with session.boot + session.scenarios.{must_pass,nice_to_pass}.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::Deserialize;

/// Highest version of the `SAMPLE.md` schema this binary understands.
///
/// Bumps work the same way as [`crate::parser::scenario::SCHEMA_VERSION`]:
/// major-version mismatch is a hard load error; new optional fields stay
/// forward-tolerant via `#[serde(default)]`.
pub const SAMPLE_SCHEMA_VERSION: u32 = 1;

/// Top-level shape of a `SAMPLE.md` manifest (the fenced YAML block inside it).
///
/// A `SAMPLE.md` is a markdown file colocated with an Atmosphere sample. The
/// runner extracts the first fenced `yaml` code block and deserializes it
/// into this struct. The rest of the markdown is prose for human readers and
/// is ignored at parse time.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SampleManifest {
    /// Schema major version. Currently always `1`.
    pub version: u32,
    /// Session block — how the runner boots the sample and which scenarios to drive.
    pub session: Session,
    /// Optional human-readable name.
    #[serde(default)]
    pub name: Option<String>,
    /// Optional multi-line description.
    #[serde(default)]
    pub description: Option<String>,
}

/// `session:` block inside a [`SampleManifest`].
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Session {
    /// How to boot the sample's process. Used to fill `spawn:` step defaults
    /// when a scenario writes `from: SAMPLE.md`.
    pub boot: Boot,
    /// Which scenario YAML files belong to which result tier.
    pub scenarios: Scenarios,
    /// When true, the runner boots the sample's process **once** before any
    /// scenarios run and kills it after the last scenario. Scenarios still
    /// declare `spawn: { from: SAMPLE.md }` for portability, but the runner
    /// observes the id already in flight and treats those spawns as no-ops.
    /// Default `false` (legacy per-scenario boot).
    #[serde(default)]
    pub boot_once: bool,
    /// Optional TCP port for the runner to wait on after the shared boot.
    /// Only consulted when `boot_once` is true. When unset, the runner
    /// skips the wait — caller scenarios may issue their own `wait_port:`.
    #[serde(default)]
    pub boot_ready_port: Option<u16>,
    /// Timeout in seconds for the boot-ready wait. Defaults to 60 when
    /// `boot_ready_port` is set; ignored otherwise.
    #[serde(default)]
    pub boot_ready_timeout_s: Option<u32>,
}

/// `session.boot:` — the canonical command to start the sample under test.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Boot {
    /// Shell-words-tokenized command line (e.g. `"java -jar target/foo.jar"`).
    pub command: String,
    /// Working directory relative to the sample dir (`SAMPLE.md`'s parent).
    /// `None` accepts the current directory of the `mirroir-run` invocation.
    #[serde(default)]
    pub cwd: Option<String>,
    /// Environment variable overrides for the boot process.
    #[serde(default)]
    pub env: HashMap<String, String>,
    /// Optional ceiling on the boot subprocess's runtime, in seconds.
    #[serde(default)]
    pub timeout_s: Option<u32>,
}

/// `session.scenarios:` — scenario YAML files grouped by result tier.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Scenarios {
    /// Scenarios that must pass for the sample to be considered green.
    /// Paths are relative to the sample dir.
    #[serde(default)]
    pub must_pass: Vec<PathBuf>,
    /// Scenarios that are informational — FAIL doesn't fail the sample.
    /// Paths are relative to the sample dir.
    #[serde(default)]
    pub nice_to_pass: Vec<PathBuf>,
}

/// Extract the body of the first fenced `yaml` (or `yml`) code block from a
/// markdown document.
///
/// Returns the lines between the opening fence and the next closing fence,
/// joined with `\n`. Returns `None` if no such block exists. Fences that
/// lack the explicit `yaml` / `yml` tag are ignored — `SAMPLE.md` must use a
/// tagged fence so prose code samples don't get parsed as the manifest.
#[must_use]
pub fn extract_yaml_block(markdown: &str) -> Option<String> {
    let mut in_block = false;
    let mut body = String::new();
    for line in markdown.lines() {
        let trimmed = line.trim_start();
        if in_block {
            if trimmed.starts_with("```") {
                return Some(body);
            }
            body.push_str(line);
            body.push('\n');
        } else if trimmed.starts_with("```yaml") || trimmed.starts_with("```yml") {
            in_block = true;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    #[test]
    fn extract_yaml_block_returns_body_between_fences() -> TestResult {
        let md = "# Title\n\n```yaml\nversion: 1\nname: smoke\n```\n\nMore prose.";
        let body = extract_yaml_block(md).ok_or("expected a yaml block")?;
        assert_eq!(body, "version: 1\nname: smoke\n");
        Ok(())
    }

    #[test]
    fn extract_yaml_block_accepts_yml_tag() -> TestResult {
        let md = "```yml\nversion: 1\n```\n";
        let body = extract_yaml_block(md).ok_or("expected a yml block")?;
        assert_eq!(body, "version: 1\n");
        Ok(())
    }

    #[test]
    fn extract_yaml_block_ignores_untagged_fences() {
        let md = "prose\n\n```\nnot yaml\n```\n";
        assert!(extract_yaml_block(md).is_none());
    }

    #[test]
    fn extract_yaml_block_returns_first_block_when_multiple() -> TestResult {
        let md = "```yaml\nfirst: yes\n```\n\n```yaml\nsecond: yes\n```\n";
        let body = extract_yaml_block(md).ok_or("expected a yaml block")?;
        assert_eq!(body, "first: yes\n");
        Ok(())
    }

    #[test]
    fn parses_full_manifest() -> TestResult {
        let yaml = r#"
version: 1
name: spring-boot-chat
description: |
  Boot the chat sample, run smoke scenarios.
session:
  boot:
    command: "java -jar target/spring-boot-chat.jar"
    cwd: "samples/spring-boot-chat"
    env:
      SPRING_PROFILES_ACTIVE: ci
    timeout_s: 60
  scenarios:
    must_pass:
      - connect-then-broadcast.yaml
    nice_to_pass:
      - slow-network.yaml
"#;
        let manifest: SampleManifest = serde_norway::from_str(yaml)?;
        assert_eq!(manifest.version, SAMPLE_SCHEMA_VERSION);
        assert_eq!(manifest.name.as_deref(), Some("spring-boot-chat"));
        assert_eq!(
            manifest.session.boot.command,
            "java -jar target/spring-boot-chat.jar"
        );
        assert_eq!(manifest.session.boot.timeout_s, Some(60));
        assert_eq!(manifest.session.scenarios.must_pass.len(), 1);
        assert_eq!(manifest.session.scenarios.nice_to_pass.len(), 1);
        Ok(())
    }

    #[test]
    fn parses_minimal_manifest() -> TestResult {
        let yaml = r#"
version: 1
session:
  boot:
    command: "echo hi"
  scenarios:
    must_pass:
      - smoke.yaml
"#;
        let manifest: SampleManifest = serde_norway::from_str(yaml)?;
        assert_eq!(manifest.version, SAMPLE_SCHEMA_VERSION);
        assert!(manifest.name.is_none());
        assert!(manifest.session.boot.cwd.is_none());
        assert!(manifest.session.boot.timeout_s.is_none());
        assert!(manifest.session.boot.env.is_empty());
        assert!(manifest.session.scenarios.nice_to_pass.is_empty());
        Ok(())
    }

    #[test]
    fn rejects_unknown_top_level_field() -> TestResult {
        let yaml = r#"
version: 1
session:
  boot:
    command: "echo hi"
  scenarios:
    must_pass: []
unknown_field: nope
"#;
        let Err(err) = serde_norway::from_str::<SampleManifest>(yaml) else {
            return Err("expected deserialize to fail".into());
        };
        let msg = err.to_string();
        if !(msg.contains("unknown_field") || msg.contains("unknown field")) {
            return Err(format!("expected unknown-field error, got: {msg}").into());
        }
        Ok(())
    }
}
