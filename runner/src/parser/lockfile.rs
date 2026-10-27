// ABOUTME: Schema + (de)serializer for `.mirroir/mirroir.lock` — exact archetype resolutions.
// ABOUTME: Path-independent (no install_path field); install path is computed at resolve time.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{Result, RunnerError};

/// Schema version of the `mirroir.lock` file.
pub const LOCKFILE_SCHEMA_VERSION: u32 = 1;

/// Top-level lockfile shape — the data persisted to `<repo>/.mirroir/mirroir.lock`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Lockfile {
    /// Schema major version. Currently always `1`.
    pub version: u32,
    /// UTC timestamp recorded when the lockfile was last regenerated.
    pub generated_at: DateTime<Utc>,
    /// Human-readable producer (`"mirroir-run 0.2.0"` etc.).
    pub generated_by: String,
    /// Per-archetype resolution records. Ordered by `ref` for deterministic diffs.
    pub archetypes: Vec<LockedArchetype>,
}

/// One row of the lockfile — maps a friendly ref to an exact resolution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LockedArchetype {
    /// Friendly reference as it appears in `mirroir.yaml`
    /// (e.g., `mirroir-skills/atmosphere/ai-console@v1` or `./archetypes/foo`).
    #[serde(rename = "ref")]
    pub reference: String,
    /// Exact resolution at lock time.
    pub resolved: ResolvedRecord,
}

/// Exact resolution recorded in the lockfile. Path-independent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResolvedRecord {
    /// Origin kind — drives install-path computation at resolve time.
    pub kind: LockedOrigin,
    /// Pack identifier (e.g., `mirroir-skills`). `None` for project-local + user-global.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pack: Option<String>,
    /// Archetype name (e.g., `atmosphere/ai-console`) or project-local path.
    pub name: String,
    /// Resolved exact version. `None` for project-local refs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Git source information when the archetype lives in a git repo.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<GitSource>,
    /// `sha256:` checksum of the archetype directory tree (canonical file content hash).
    pub checksum: String,
}

/// Where the resolved archetype originated.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LockedOrigin {
    /// Pack-installed from a git repo.
    Pack,
    /// Project-local — lives in `<repo>/.mirroir/<path>`.
    ProjectLocal,
    /// User-global — lives in `~/.mirroir/archetypes/<name>/<version>/`.
    UserGlobal,
}

/// Git source bound recorded for pack-installed archetypes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GitSource {
    /// Remote URL the pack was cloned from.
    pub url: String,
    /// Tag the pack was checked out at, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    /// Commit SHA the install dir was at when the lockfile was generated.
    pub commit: String,
}

/// Parse a lockfile from YAML text.
///
/// # Errors
///
/// * [`RunnerError::YamlParse`] on serde failure.
/// * [`RunnerError::UnsupportedVersion`] when `version` is out of range.
pub fn parse_lockfile(source_label: &str, yaml: &str) -> Result<Lockfile> {
    let parsed: Lockfile =
        serde_norway::from_str(yaml).map_err(|source| RunnerError::YamlParse {
            file: source_label.to_owned(),
            source,
        })?;
    if parsed.version != LOCKFILE_SCHEMA_VERSION {
        return Err(RunnerError::UnsupportedVersion {
            artifact: "mirroir.lock".to_owned(),
            found: parsed.version,
            expected: LOCKFILE_SCHEMA_VERSION..=LOCKFILE_SCHEMA_VERSION,
        });
    }
    Ok(parsed)
}

/// Serialize a lockfile to YAML text. The output is deterministic — entries
/// are sorted by `reference` so two semantically-identical lockfiles produce
/// byte-identical output.
///
/// # Errors
///
/// Returns [`RunnerError::YamlParse`] (reused for symmetry) if serde fails to
/// emit YAML — in practice this cannot happen for the lockfile shape.
pub fn serialize_lockfile(lockfile: &Lockfile) -> Result<String> {
    let mut canonical = lockfile.clone();
    canonical
        .archetypes
        .sort_by(|a, b| a.reference.cmp(&b.reference));
    serde_norway::to_string(&canonical).map_err(|source| RunnerError::YamlParse {
        file: "mirroir.lock (serialize)".to_owned(),
        source,
    })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn sample_lockfile() -> StdResult<Lockfile, Box<dyn StdError>> {
        let ts = DateTime::parse_from_rfc3339("2026-05-16T18:22:14Z")?.with_timezone(&Utc);
        Ok(Lockfile {
            version: 1,
            generated_at: ts,
            generated_by: "mirroir-run 0.2.0".to_owned(),
            archetypes: vec![
                LockedArchetype {
                    reference: "mirroir-skills/atmosphere/ai-console@v1".to_owned(),
                    resolved: ResolvedRecord {
                        kind: LockedOrigin::Pack,
                        pack: Some("mirroir-skills".to_owned()),
                        name: "atmosphere/ai-console".to_owned(),
                        version: Some("1.0.3".to_owned()),
                        source: Some(GitSource {
                            url: "https://github.com/jfarcand/mirroir-skills".to_owned(),
                            tag: Some("v1.0.3".to_owned()),
                            commit: "7f2fc967c0a4b8e9f3d2a1c5b6e8f0a1d2c3b4e5".to_owned(),
                        }),
                        checksum: "sha256:abcd".to_owned(),
                    },
                },
                LockedArchetype {
                    reference: "./archetypes/custom-flow".to_owned(),
                    resolved: ResolvedRecord {
                        kind: LockedOrigin::ProjectLocal,
                        pack: None,
                        name: "./archetypes/custom-flow".to_owned(),
                        version: None,
                        source: None,
                        checksum: "sha256:effe".to_owned(),
                    },
                },
            ],
        })
    }

    #[test]
    fn roundtrip_preserves_data() -> TestResult {
        let lock = sample_lockfile()?;
        let yaml = serialize_lockfile(&lock)?;
        let parsed = parse_lockfile("test", &yaml)?;
        // Ordering: serialize sorts by reference; parse preserves serialized order.
        // Compare via sorted clones for stability.
        let mut sorted_in = lock.archetypes.clone();
        sorted_in.sort_by(|a, b| a.reference.cmp(&b.reference));
        assert_eq!(parsed.archetypes, sorted_in);
        assert_eq!(parsed.version, lock.version);
        assert_eq!(parsed.generated_by, lock.generated_by);
        Ok(())
    }

    #[test]
    fn serialize_sorts_entries_for_deterministic_output() -> TestResult {
        let lock = sample_lockfile()?;
        let yaml = serialize_lockfile(&lock)?;
        let pos_local = yaml
            .find("./archetypes/custom-flow")
            .ok_or("local entry not found")?;
        let pos_pack = yaml
            .find("mirroir-skills/atmosphere")
            .ok_or("pack entry not found")?;
        assert!(
            pos_local < pos_pack,
            "expected local entry to sort before pack entry"
        );
        Ok(())
    }

    #[test]
    fn rejects_unknown_field() {
        let yaml = "version: 1\ngenerated_at: 2026-05-16T18:22:14Z\ngenerated_by: x\narchetypes: []\nrogue: oops\n";
        assert!(matches!(
            parse_lockfile("test", yaml),
            Err(RunnerError::YamlParse { .. })
        ));
    }

    #[test]
    fn rejects_wrong_version() {
        let yaml =
            "version: 99\ngenerated_at: 2026-05-16T18:22:14Z\ngenerated_by: x\narchetypes: []\n";
        assert!(matches!(
            parse_lockfile("test", yaml),
            Err(RunnerError::UnsupportedVersion { .. })
        ));
    }
}
