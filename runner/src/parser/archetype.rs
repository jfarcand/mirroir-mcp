// ABOUTME: Parser for `archetype.md` — the manifest at the root of an archetype directory.
// ABOUTME: Frontmatter is YAML (deserialized); body is markdown prose (ignored by tooling).

use std::collections::HashMap;

use serde::Deserialize;

use crate::error::{Result, RunnerError};
use crate::parser::sample::extract_yaml_block;
use crate::parser::version::{self, ArtifactKind, SchemaVersion};

/// Parsed frontmatter of an `archetype.md` file.
///
/// `archetype.md` lives at `<pack-version>/archetypes/<name>/archetype.md` (or
/// `<repo>/.mirroir/archetypes/<name>/archetype.md` for project-local). The
/// markdown body is human documentation; the runner reads only the
/// frontmatter.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ArchetypeManifest {
    /// Frontmatter schema version, gated by [`ArtifactKind::Archetype`].
    pub version: SchemaVersion,
    /// Fully-qualified archetype name within its pack (e.g., `atmosphere/ai-console`).
    pub name: String,
    /// Semver of this archetype revision.
    pub archetype_version: String,
    /// Optional human-readable description.
    #[serde(default)]
    pub description: Option<String>,
    /// What an instance must / may provide.
    #[serde(default)]
    pub requires: ArchetypeRequires,
    /// What flows this archetype offers to plan entries.
    pub provides: ArchetypeProvides,
    /// Compatibility statements (informational; not enforced at parse time).
    #[serde(default)]
    pub compatible_with: HashMap<String, String>,
}

/// Declared inputs an instance plan entry may need to supply.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Default)]
pub struct ArchetypeRequires {
    /// Variable declarations consumed via `${VAR}` in archetype-sourced files.
    #[serde(default)]
    pub vars: Vec<ArchetypeRequiredVar>,
    /// Environment variables the boot process expects.
    #[serde(default)]
    pub env: Vec<ArchetypeRequiredEnv>,
}

/// One required-or-optional variable an archetype declares.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ArchetypeRequiredVar {
    /// Variable name (referenced as `${name}` in source files).
    pub name: String,
    /// Human description of what the variable means.
    #[serde(default)]
    pub description: Option<String>,
    /// When true, plan entries that don't supply this var error at compose time.
    #[serde(default)]
    pub required: bool,
    /// Default value when the var is absent. Mirrors `${VAR:-default}` semantics.
    #[serde(default)]
    pub default: Option<String>,
}

/// One environment variable an archetype's boot process expects.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ArchetypeRequiredEnv {
    /// Environment variable name.
    pub name: String,
    /// Default value applied when the plan entry's `boot.env` omits this key.
    #[serde(default)]
    pub default: Option<String>,
    /// Human description.
    #[serde(default)]
    pub description: Option<String>,
}

/// What the archetype offers — flows that instances can opt into.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ArchetypeProvides {
    /// Names of flows defined under the archetype's `scenarios/` directory.
    pub flows: Vec<String>,
}

/// Parse an `archetype.md` file's body, extracting the frontmatter as
/// [`ArchetypeManifest`].
///
/// The `source_label` is a human-readable name (file path) used in error
/// messages; it is not interpreted.
///
/// # Errors
///
/// * [`RunnerError::SampleMissingYaml`] when no fenced yaml block is present.
/// * [`RunnerError::YamlParse`] when the frontmatter fails deserialization.
/// * [`RunnerError::UnsupportedVersion`] when the `version:` major is unsupported.
/// * [`RunnerError::UnknownFields`] for keys the manifest schema does not define.
pub fn parse_archetype_manifest(source_label: &str, markdown: &str) -> Result<ArchetypeManifest> {
    let body = extract_yaml_block(markdown).ok_or_else(|| RunnerError::SampleMissingYaml {
        path: source_label.to_owned(),
    })?;

    version::from_yaml_str(ArtifactKind::Archetype, source_label, &body, |source| {
        RunnerError::YamlParse {
            file: source_label.to_owned(),
            source,
        }
    })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    #[test]
    fn parses_full_manifest() -> TestResult {
        let md = r#"# Atmosphere AI Console

```yaml
version: 1
name: atmosphere/ai-console
archetype_version: 1.0.0
description: |
  Vue console at /atmosphere/console/.
requires:
  vars:
    - name: PORT
      description: TCP port the app is bound to
      required: true
  env:
    - name: ATMOSPHERE_AUTH_ENABLED
      default: "false"
provides:
  flows:
    - chat-stream
    - chat-broadcast
compatible_with:
  atmosphere: ">=4.0.0,<5.0.0"
```

Prose follows.
"#;
        let m = parse_archetype_manifest("test/archetype.md", md)?;
        assert_eq!(m.name, "atmosphere/ai-console");
        assert_eq!(m.archetype_version, "1.0.0");
        assert_eq!(m.requires.vars.len(), 1);
        assert!(m.requires.vars[0].required);
        assert_eq!(m.provides.flows, vec!["chat-stream", "chat-broadcast"]);
        assert_eq!(
            m.compatible_with.get("atmosphere").map(String::as_str),
            Some(">=4.0.0,<5.0.0")
        );
        Ok(())
    }

    #[test]
    fn parses_minimal_manifest() -> TestResult {
        let md = "```yaml\nversion: 1\nname: foo/bar\narchetype_version: 0.1.0\nprovides:\n  flows: []\n```";
        let m = parse_archetype_manifest("test", md)?;
        assert_eq!(m.name, "foo/bar");
        assert_eq!(m.requires.vars, []);
        assert_eq!(m.provides.flows, Vec::<String>::new());
        Ok(())
    }

    #[test]
    fn rejects_missing_yaml_block() {
        let md = "Just prose, no fenced block.";
        assert!(matches!(
            parse_archetype_manifest("test", md),
            Err(RunnerError::SampleMissingYaml { .. })
        ));
    }

    #[test]
    fn rejects_wrong_version() {
        let md =
            "```yaml\nversion: 9\nname: x/y\narchetype_version: 1.0.0\nprovides:\n  flows: []\n```";
        assert!(matches!(
            parse_archetype_manifest("test", md),
            Err(RunnerError::UnsupportedVersion { .. })
        ));
    }

    #[test]
    fn rejects_unknown_field() {
        let md = "```yaml\nversion: 1\nname: x/y\narchetype_version: 1.0.0\nprovides:\n  flows: []\nrogue_field: nope\n```";
        assert!(matches!(
            parse_archetype_manifest("test", md),
            Err(RunnerError::UnknownFields { keys, .. }) if keys == ["rogue_field"]
        ));
    }
}
