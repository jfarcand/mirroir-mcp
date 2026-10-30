// ABOUTME: Parser for `.mirroir/mirroir.yaml` — the plan that lists samples + archetype refs.
// ABOUTME: Validates exactly-one-of(archetypes, local), plural archetypes (v1: ≤1 entry), and ref syntax.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::Deserialize;

use crate::error::{Result, RunnerError};
use crate::mirroir::error::MirroirError;

pub use crate::parser::mirroir_plan::{ArchetypeRef, ArchetypeRefKind};
use crate::parser::version::{self, ArtifactKind, SchemaVersion};

/// Top-level shape of `<repo>/.mirroir/mirroir.yaml`.
///
/// The plan is the contract between the consumer repository and the runner.
/// Each plan entry declares either a pack-resolved archetype (with per-instance
/// overrides) or a fully-local sample definition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MirroirConfig {
    /// Schema version, gated by [`ArtifactKind::MirroirConfig`].
    pub version: SchemaVersion,
    /// Human-readable suite name.
    pub name: Option<String>,
    /// Multi-line description.
    pub description: Option<String>,
    /// Default scenario tier when `--scenarios` is omitted.
    pub default_set: Option<DefaultScenarioSet>,
    /// The plan itself — `must_pass` + `nice_to_pass` tiers.
    pub plan: Plan,
    /// Suite-level env merged into every sample's boot (per-sample wins on key conflict).
    pub env: HashMap<String, String>,
}

/// Mirrors the runtime `ScenarioSet` from `replay.rs` but lives in the parser
/// module to keep parsing self-contained. The runner translates between them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DefaultScenarioSet {
    /// Run only `plan.must_pass`.
    MustPass,
    /// Run only `plan.nice_to_pass`.
    NiceToPass,
    /// Run both, `must_pass` first.
    All,
}

/// Two-tier scenario plan. Each tier is an ordered list of plan entries.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Plan {
    /// Samples whose failure blocks the suite.
    pub must_pass: Vec<PlanEntry>,
    /// Samples whose failure is informational (do not block).
    pub nice_to_pass: Vec<PlanEntry>,
}

/// One sample in the plan.
///
/// Exactly one of `source = Archetypes` or `source = Local` is set — the
/// raw YAML's `archetypes:` and `local:` fields are validated as mutually
/// exclusive at parse time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanEntry {
    /// Unique name within the plan. Used as the `.mirroir/.build/<name>/` directory.
    pub name: String,
    /// Where the sample's APP/SKILL/scenarios come from.
    pub source: PlanEntrySource,
    /// Subset of the archetype's `provides.flows`. Empty for `Local` sources.
    pub flows: Vec<String>,
    /// Variable substitutions applied to archetype-sourced files.
    pub vars: HashMap<String, String>,
    /// Per-instance boot wiring.
    pub boot: PlanEntryBoot,
    /// True only in `mirroir.local.yaml` overrides — excludes the entry from the run.
    pub skip: bool,
}

/// Either-or origin of a plan entry's artifacts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanEntrySource {
    /// One or more archetype references (v1 enforces exactly one).
    Archetypes {
        /// Parsed references in declaration order.
        references: Vec<ArchetypeRef>,
    },
    /// Path to a self-contained local sample under `<repo>/.mirroir/`.
    Local {
        /// Repo-relative path (relative to `<repo>/.mirroir/`).
        path: PathBuf,
    },
}

/// Boot wiring for one plan entry. Flattens what would otherwise be split
/// across `boot:` (command/cwd/env/timeout) and `session:` (`boot_once`/`ready_port`)
/// in a standalone `SAMPLE.md`. The compose layer separates these back out
/// when emitting `.mirroir/.build/<sample>/SAMPLE.md`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PlanEntryBoot {
    /// Shell-words-tokenized command line.
    pub command: String,
    /// Working directory for the boot subprocess. Supports `${VAR}` substitution.
    #[serde(default)]
    pub cwd: Option<String>,
    /// Environment overrides for the boot subprocess.
    #[serde(default)]
    pub env: HashMap<String, String>,
    /// Optional ceiling on the boot subprocess's runtime, in seconds.
    #[serde(default)]
    pub timeout_s: Option<u32>,
    /// When true, boot once across all scenarios in this sample.
    #[serde(default = "default_boot_once")]
    pub boot_once: bool,
    /// TCP port the runner waits on after boot.
    #[serde(default)]
    pub boot_ready_port: Option<u16>,
    /// Boot-ready wait timeout in seconds. Defaults to 60 when port is set.
    #[serde(default)]
    pub boot_ready_timeout_s: Option<u32>,
}

const fn default_boot_once() -> bool {
    true
}

// ─────────────────────────────────────────────────────────────────────────────
// Raw deserialization shapes — flat YAML mapping for `mirroir.yaml`.
// Validation is applied in `try_from` impls below.
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
struct MirroirConfigRaw {
    version: SchemaVersion,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    default_set: Option<DefaultScenarioSet>,
    #[serde(default)]
    plan: PlanRaw,
    #[serde(default)]
    env: HashMap<String, String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct PlanRaw {
    #[serde(default)]
    must_pass: Vec<PlanEntryRaw>,
    #[serde(default)]
    nice_to_pass: Vec<PlanEntryRaw>,
}

#[derive(Debug, Clone, Deserialize)]
struct PlanEntryRaw {
    name: String,
    #[serde(default)]
    archetypes: Option<Vec<String>>,
    #[serde(default)]
    local: Option<PathBuf>,
    #[serde(default)]
    flows: Vec<String>,
    #[serde(default)]
    vars: HashMap<String, String>,
    boot: PlanEntryBoot,
    #[serde(default)]
    skip: bool,
}

/// Parse a `mirroir.yaml` body into a validated [`MirroirConfig`].
///
/// The input should be the YAML content (no markdown frontmatter
/// stripping — `mirroir.yaml` is a pure YAML file, not a fenced block).
///
/// # Errors
///
/// * [`RunnerError::YamlParse`] when serde rejects the input.
/// * [`RunnerError::UnsupportedVersion`] when the `version:` major is unsupported.
/// * [`RunnerError::UnknownFields`] for keys the plan schema does not define.
/// * [`MirroirError::InvalidArchetypeRef`] for malformed refs.
/// * [`MirroirError::CompositionUnsupported`] for `archetypes.len() > 1`.
/// * [`MirroirError::PlanEntryAmbiguous`] when neither/both of
///   `archetypes` and `local` are set.
pub fn parse_mirroir_config(source_label: &str, yaml: &str) -> Result<MirroirConfig> {
    let raw: MirroirConfigRaw =
        version::from_yaml_str(ArtifactKind::MirroirConfig, source_label, yaml, |source| {
            RunnerError::YamlParse {
                file: source_label.to_owned(),
                source,
            }
        })?;

    let plan = Plan {
        must_pass: raw
            .plan
            .must_pass
            .into_iter()
            .map(PlanEntry::try_from_raw)
            .collect::<Result<Vec<_>>>()?,
        nice_to_pass: raw
            .plan
            .nice_to_pass
            .into_iter()
            .map(PlanEntry::try_from_raw)
            .collect::<Result<Vec<_>>>()?,
    };

    Ok(MirroirConfig {
        version: raw.version,
        name: raw.name,
        description: raw.description,
        default_set: raw.default_set,
        plan,
        env: raw.env,
    })
}

impl PlanEntry {
    fn try_from_raw(raw: PlanEntryRaw) -> Result<Self> {
        let source = match (raw.archetypes, raw.local) {
            (Some(refs), None) => {
                if refs.is_empty() {
                    return Err(MirroirError::PlanEntryAmbiguous {
                        entry_name: raw.name,
                        reason: "`archetypes:` is present but empty".to_owned(),
                    }
                    .into());
                }
                if refs.len() > 1 {
                    return Err(MirroirError::CompositionUnsupported {
                        entry_name: raw.name,
                        count: refs.len(),
                    }
                    .into());
                }
                let parsed = refs
                    .iter()
                    .map(|s| ArchetypeRef::parse(s))
                    .collect::<Result<Vec<_>>>()?;
                PlanEntrySource::Archetypes { references: parsed }
            }
            (None, Some(path)) => PlanEntrySource::Local { path },
            (Some(_), Some(_)) => {
                return Err(MirroirError::PlanEntryAmbiguous {
                    entry_name: raw.name,
                    reason: "both `archetypes:` and `local:` are set; pick one".to_owned(),
                }
                .into());
            }
            (None, None) => {
                return Err(MirroirError::PlanEntryAmbiguous {
                    entry_name: raw.name,
                    reason: "neither `archetypes:` nor `local:` is set; one is required".to_owned(),
                }
                .into());
            }
        };

        Ok(Self {
            name: raw.name,
            source,
            flows: raw.flows,
            vars: raw.vars,
            boot: raw.boot,
            skip: raw.skip,
        })
    }
}

#[cfg(test)]
#[allow(clippy::too_many_lines)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    #[test]
    fn parses_minimal_mirroir_yaml() -> TestResult {
        let yaml = r#"
version: 1
plan:
  must_pass:
    - name: hello
      local: apps/hello
      boot:
        command: "echo hi"
"#;
        let config = parse_mirroir_config("test", yaml)?;
        assert_eq!(config.plan.must_pass.len(), 1);
        let entry = &config.plan.must_pass[0];
        assert_eq!(entry.name, "hello");
        let PlanEntrySource::Local { path } = &entry.source else {
            return Err(format!("expected Local, got {:?}", entry.source).into());
        };
        assert_eq!(path, &PathBuf::from("apps/hello"));
        assert_eq!(entry.boot.command, "echo hi");
        assert!(entry.boot.boot_once);
        Ok(())
    }

    #[test]
    fn parses_archetype_entry_with_vars() -> TestResult {
        // Note: the cwd value uses a plain ${VAR} (not :-default) to avoid
        // the `literal_string_with_formatting_args` clippy lint catching
        // the literal `:-` inside a raw string at compile time.
        let yaml = r#"
version: 1
name: atmosphere
plan:
  must_pass:
    - name: spring-boot-ai-chat
      archetypes: [mirroir-skills/atmosphere/ai-console@v1]
      flows: [chat-stream]
      vars:
        PORT: "8080"
      boot:
        command: "./mvnw -q spring-boot:run -pl samples/spring-boot-ai-chat"
        cwd: "${ATMOSPHERE_HOME}"
        env:
          LLM_MODE: fake
        boot_ready_port: 8080
        boot_ready_timeout_s: 120
"#;
        let config = parse_mirroir_config("test", yaml)?;
        let entry = &config.plan.must_pass[0];
        assert_eq!(entry.flows, vec!["chat-stream".to_owned()]);
        assert_eq!(entry.vars.get("PORT").map(String::as_str), Some("8080"));
        let PlanEntrySource::Archetypes { references } = &entry.source else {
            return Err(format!("expected Archetypes, got {:?}", entry.source).into());
        };
        assert_eq!(references.len(), 1);
        assert_eq!(references[0].pack.as_deref(), Some("mirroir-skills"));
        assert_eq!(references[0].name, "atmosphere/ai-console");
        assert_eq!(references[0].version.as_deref(), Some("v1"));
        Ok(())
    }

    #[test]
    fn rejects_both_archetypes_and_local() -> TestResult {
        let yaml = r#"
version: 1
plan:
  must_pass:
    - name: bad
      archetypes: [mirroir-skills/foo/bar]
      local: apps/bad
      flows: [x]
      boot:
        command: "true"
"#;
        let Err(RunnerError::Mirroir(MirroirError::PlanEntryAmbiguous { entry_name, .. })) =
            parse_mirroir_config("test", yaml)
        else {
            return Err("expected MirroirPlanEntryAmbiguous".into());
        };
        assert_eq!(entry_name, "bad");
        Ok(())
    }

    #[test]
    fn rejects_neither_archetypes_nor_local() {
        let yaml = r#"
version: 1
plan:
  must_pass:
    - name: bad
      boot:
        command: "true"
"#;
        assert!(matches!(
            parse_mirroir_config("test", yaml),
            Err(RunnerError::Mirroir(
                MirroirError::PlanEntryAmbiguous { .. }
            ))
        ));
    }

    #[test]
    fn rejects_multi_archetype_composition_in_v1() -> TestResult {
        let yaml = r#"
version: 1
plan:
  must_pass:
    - name: composed
      archetypes:
        - mirroir-skills/a/one
        - mirroir-skills/b/two
      flows: [x]
      boot:
        command: "true"
"#;
        let Err(RunnerError::Mirroir(MirroirError::CompositionUnsupported { entry_name, count })) =
            parse_mirroir_config("test", yaml)
        else {
            return Err("expected MirroirCompositionUnsupported".into());
        };
        assert_eq!(entry_name, "composed");
        assert_eq!(count, 2);
        Ok(())
    }

    #[test]
    fn rejects_unknown_keys_at_a_known_minor() -> TestResult {
        let yaml = "version: 1\nplan:\n  must_pass: []\n  must_pas: []\nunknown_field: yep\n";
        let Err(RunnerError::UnknownFields { keys, .. }) = parse_mirroir_config("test", yaml)
        else {
            return Err("expected UnknownFields".into());
        };
        assert_eq!(
            keys,
            vec!["plan.must_pas".to_owned(), "unknown_field".to_owned()]
        );
        Ok(())
    }

    #[test]
    fn a_newer_minor_ignores_unknown_keys() -> TestResult {
        let yaml = "version: \"1.1\"\nplan:\n  must_pass: []\nadded_in_1_1: yep\n";
        let config = parse_mirroir_config("test", yaml)?;
        assert_eq!(config.version, SchemaVersion::new(1, 1));
        Ok(())
    }

    #[test]
    fn a_newer_major_with_new_keys_is_unsupported_not_a_parse_error() -> TestResult {
        let yaml = "version: 2\nplan:\n  must_pass: []\nadded_in_2: yep\n";
        let Err(RunnerError::UnsupportedVersion { found, .. }) = parse_mirroir_config("test", yaml)
        else {
            return Err("expected UnsupportedVersion".into());
        };
        assert_eq!(found, SchemaVersion::new(2, 0));
        Ok(())
    }
}
