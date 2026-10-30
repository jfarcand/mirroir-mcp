// ABOUTME: Compose cache freshness — manifest structs, sha256 hashing, and the compose_needed check.
// ABOUTME: Decides whether a cached `.build/<sample>/` tree is stale vs. its archetype + plan inputs.

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tracing::info;

use crate::error::{Result, RunnerError};
use crate::mirroir::compose::build_dir_for;
use crate::mirroir::resolve::{ArchetypeOrigin, ResolvedArchetype};
use crate::parser::mirroir::PlanEntry;
use crate::parser::version::{self, ArtifactKind, SchemaVersion};

/// Filename of the per-sample compose-provenance manifest.
pub const COMPOSE_MANIFEST_FILE: &str = ".compose-manifest.json";

/// Determine whether the cached `.build/<entry.name>/` is stale relative to
/// its archetype source + plan-entry inputs.
///
/// Fast-path: when the compose manifest's `composed_at` is newer than every
/// archetype source file's `mtime`, the cache is trusted as-is.
/// Slow-path: any source file with a newer mtime triggers a sha256 check
/// against the recorded sums.
///
/// Returns `true` when compose must run, `false` when cache is valid.
///
/// # Errors
///
/// Returns [`RunnerError::Io`] when manifest read fails for an existing
/// `.build/` directory.
pub fn compose_needed(
    entry: &PlanEntry,
    resolved: &ResolvedArchetype,
    project_root: &Path,
) -> Result<bool> {
    let build = build_dir_for(entry, project_root);
    if !build.join(COMPOSE_MANIFEST_FILE).exists() {
        return Ok(true);
    }

    let manifest_path = build.join(COMPOSE_MANIFEST_FILE);
    let raw = fs::read_to_string(&manifest_path).map_err(|source| RunnerError::Io {
        context: format!("read compose manifest {}", manifest_path.display()),
        source,
    })?;
    let label = manifest_path.display().to_string();
    let manifest = match version::from_json_str::<ComposeManifest>(
        ArtifactKind::ComposeManifest,
        &label,
        &raw,
        |source| RunnerError::Io {
            context: format!("parse compose manifest {label}"),
            source: source.into(),
        },
    ) {
        Ok(manifest) => manifest,
        Err(err @ RunnerError::UnsupportedVersion { .. }) => {
            // A cache another binary wrote: rebuild it rather than trust it.
            info!(%err, "compose manifest is from an unsupported major; recomposing");
            return Ok(true);
        }
        // Unreadable or unknown keys at a known minor → corrupt → recompose.
        Err(_) => return Ok(true),
    };

    if manifest.instance.plan_entry_sha256 != hash_plan_entry(entry) {
        return Ok(true);
    }

    // Fast-path: compare each recorded source file's mtime to composed_at.
    let composed_at_sys: SystemTime = manifest.composed_at.into();
    let mut needs_sha = false;
    for record in &manifest.archetype.source_files {
        let abs = resolved.directory.join(&record.path);
        let Ok(meta) = fs::metadata(&abs) else {
            // Source file removed → recompose.
            return Ok(true);
        };
        let Ok(mtime) = meta.modified() else {
            // Filesystem without mtime → fall back to slow path.
            needs_sha = true;
            continue;
        };
        if mtime > composed_at_sys {
            needs_sha = true;
        }
    }
    if !needs_sha {
        return Ok(false);
    }

    // Slow-path: sha256 every recorded source file.
    for record in &manifest.archetype.source_files {
        let abs = resolved.directory.join(&record.path);
        let Ok(bytes) = fs::read(&abs) else {
            return Ok(true);
        };
        if sha256_hex(&bytes) != record.sha256 {
            return Ok(true);
        }
    }

    Ok(false)
}

/// Extract the resolved archetype version, if the origin carries one.
#[must_use]
pub fn archetype_version(resolved: &ResolvedArchetype) -> Option<String> {
    match &resolved.origin {
        ArchetypeOrigin::Pack { version, .. } | ArchetypeOrigin::UserGlobal { version, .. } => {
            Some(version.clone())
        }
        ArchetypeOrigin::ProjectLocal { .. } => None,
    }
}

/// Hex-encoded SHA-256 of `bytes`.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

/// Deterministic hash of the plan-entry fields that affect the composed output.
///
/// The entry carries two `HashMap`s — `vars` and `boot.env` — and every
/// `HashMap` a process builds gets its own random hash keys, so two maps with
/// identical contents iterate in different orders. Hashing their `Debug`
/// rendering would therefore produce a different digest on every run and the
/// compose cache would never hit. The fields are folded into a
/// [`BTreeMap`]-ordered, length-prefixed encoding instead: sorted by key, and
/// self-delimiting so no value's bytes can imitate a field separator.
#[must_use]
pub fn hash_plan_entry(entry: &PlanEntry) -> String {
    let mut canonical = String::new();
    push_field(&mut canonical, "name", &entry.name);
    push_field(&mut canonical, "flows.len", &entry.flows.len().to_string());
    for (position, flow) in entry.flows.iter().enumerate() {
        push_field(&mut canonical, &format!("flows[{position}]"), flow);
    }
    push_map(&mut canonical, "vars", &entry.vars);
    push_field(&mut canonical, "boot.command", &entry.boot.command);
    push_field(
        &mut canonical,
        "boot.cwd",
        &optional(entry.boot.cwd.as_deref()),
    );
    push_map(&mut canonical, "boot.env", &entry.boot.env);
    push_field(
        &mut canonical,
        "boot.timeout_s",
        &optional_number(entry.boot.timeout_s),
    );
    push_field(
        &mut canonical,
        "boot.boot_once",
        if entry.boot.boot_once {
            "true"
        } else {
            "false"
        },
    );
    push_field(
        &mut canonical,
        "boot.boot_ready_port",
        &optional_number(entry.boot.boot_ready_port),
    );
    push_field(
        &mut canonical,
        "boot.boot_ready_timeout_s",
        &optional_number(entry.boot.boot_ready_timeout_s),
    );
    sha256_hex(canonical.as_bytes())
}

/// Append one `<key>=<len>:<value>;` field. The length prefix makes the
/// encoding self-delimiting: a value containing `=`, `;`, or a whole encoded
/// field cannot be read as anything but that value.
fn push_field(out: &mut String, key: &str, value: &str) {
    out.push_str(key);
    out.push('=');
    out.push_str(&value.len().to_string());
    out.push(':');
    out.push_str(value);
    out.push(';');
}

/// Append every entry of `map` under `prefix`, ordered by key.
fn push_map(out: &mut String, prefix: &str, map: &HashMap<String, String>) {
    let ordered: BTreeMap<&str, &str> = map
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect();
    push_field(out, &format!("{prefix}.len"), &ordered.len().to_string());
    for (key, value) in ordered {
        push_field(out, &format!("{prefix}[{key}]"), value);
    }
}

/// Encode an optional string so `None` and `Some("")` stay distinguishable.
fn optional(value: Option<&str>) -> String {
    value.map_or_else(|| "none".to_owned(), |inner| format!("some:{inner}"))
}

/// Encode an optional number the same way [`optional`] encodes a string.
fn optional_number<T: fmt::Display>(value: Option<T>) -> String {
    value.map_or_else(|| "none".to_owned(), |inner| format!("some:{inner}"))
}

/// Provenance manifest emitted under `.build/<sample>/.compose-manifest.json`.
#[derive(Debug, Serialize, Deserialize)]
pub struct ComposeManifest {
    /// Manifest schema version, gated by [`ArtifactKind::ComposeManifest`].
    pub version: SchemaVersion,
    /// Timestamp the sample was composed at (fast-path mtime comparison anchor).
    pub composed_at: DateTime<Utc>,
    /// Archetype-side provenance (reference, version, source-file checksums).
    pub archetype: ComposeManifestArchetype,
    /// Instance-side provenance (sample name + plan-entry hash).
    pub instance: ComposeManifestInstance,
}

/// Archetype-side provenance recorded in [`ComposeManifest`].
#[derive(Debug, Serialize, Deserialize)]
pub struct ComposeManifestArchetype {
    /// Debug rendering of the resolved archetype origin.
    pub reference: String,
    /// Resolved archetype version, when the origin carries one.
    pub resolved_version: Option<String>,
    /// Checksummed archetype source files used during compose.
    pub source_files: Vec<SourceFileRecord>,
}

/// Instance-side provenance recorded in [`ComposeManifest`].
#[derive(Debug, Serialize, Deserialize)]
pub struct ComposeManifestInstance {
    /// Composed sample name (matches the plan entry).
    pub name: String,
    /// Hash of the plan entry — a mismatch forces a recompose.
    pub plan_entry_sha256: String,
}

/// A single archetype source file's path + checksum.
#[derive(Debug, Serialize, Deserialize)]
pub struct SourceFileRecord {
    /// Archetype-relative path of the source file.
    pub path: PathBuf,
    /// Hex SHA-256 of the source file's bytes at compose time.
    pub sha256: String,
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::error::Error as StdError;
    use std::io;
    use std::result::Result as StdResult;
    use std::thread::sleep;
    use std::time::Duration;

    use super::*;
    use crate::mirroir::compose::compose_sample;
    use crate::parser::archetype::parse_archetype_manifest;
    use crate::parser::mirroir::{ArchetypeRef, ArchetypeRefKind, PlanEntryBoot, PlanEntrySource};

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn write_archetype_tree(dir: &Path) -> io::Result<()> {
        fs::create_dir_all(dir.join("scenarios"))?;
        fs::write(
            dir.join("archetype.md"),
            "```yaml\nversion: 1\nname: test/sample\narchetype_version: 1.0.0\nprovides:\n  flows:\n    - chat-stream\n```\n",
        )?;
        fs::write(
            dir.join("APP.md"),
            "# Test App\n\n```yaml\nversion: 1\napp: test\nsurface: web\nurl: \"http://127.0.0.1:${PORT}/\"\n```\n\nProse follows.",
        )?;
        fs::write(
            dir.join("scenarios/chat-stream.yaml"),
            "version: 1\nname: chat-stream\nsteps:\n  - target: { kind: web, url: \"http://127.0.0.1:${PORT}/console/\" }\n  - type: \"${MESSAGE:-hello}\"\n",
        )?;
        Ok(())
    }

    fn fixture_resolved(dir: &Path) -> StdResult<ResolvedArchetype, Box<dyn StdError>> {
        let raw = fs::read_to_string(dir.join("archetype.md"))?;
        let manifest = parse_archetype_manifest("archetype.md", &raw)?;
        Ok(ResolvedArchetype {
            origin: ArchetypeOrigin::Pack {
                pack: "test-pack".to_owned(),
                name: "test/sample".to_owned(),
                version: "1.0.0".to_owned(),
            },
            manifest,
            directory: dir.to_path_buf(),
        })
    }

    fn fixture_entry(name: &str, port: &str) -> PlanEntry {
        let archetype_ref = ArchetypeRef {
            kind: ArchetypeRefKind::Pack,
            pack: Some("test-pack".to_owned()),
            name: "test/sample".to_owned(),
            version: Some("1.0.0".to_owned()),
        };
        // Two vars and two boot env entries on purpose: one key per map cannot
        // expose an iteration-order-dependent hash.
        let mut vars = HashMap::new();
        vars.insert("PORT".to_owned(), port.to_owned());
        vars.insert("MESSAGE".to_owned(), "hello".to_owned());
        let mut env = HashMap::new();
        env.insert("ALPHA".to_owned(), "1".to_owned());
        env.insert("BETA".to_owned(), "2".to_owned());
        PlanEntry {
            name: name.to_owned(),
            source: PlanEntrySource::Archetypes {
                references: vec![archetype_ref],
            },
            flows: vec!["chat-stream".to_owned()],
            vars,
            boot: PlanEntryBoot {
                command: "echo hi".to_owned(),
                cwd: Some("${CWD_FALLBACK:-/tmp}".to_owned()),
                env,
                timeout_s: None,
                boot_once: true,
                boot_ready_port: Some(port.parse::<u16>().unwrap_or(8080)),
                boot_ready_timeout_s: Some(120),
            },
            skip: false,
        }
    }

    #[test]
    fn compose_needed_false_on_clean_cache() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path().join("proj");
        fs::create_dir_all(&project)?;
        let archetype_dir = tmp.path().join("arch");
        write_archetype_tree(&archetype_dir)?;
        let entry = fixture_entry("sample-c", "7070");
        let resolved = fixture_resolved(&archetype_dir)?;
        let _ = compose_sample(&entry, &HashMap::new(), Some(&resolved), &project)?;
        assert!(!compose_needed(&entry, &resolved, &project)?);
        Ok(())
    }

    #[test]
    fn compose_needed_true_after_source_edit() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path().join("proj");
        fs::create_dir_all(&project)?;
        let archetype_dir = tmp.path().join("arch");
        write_archetype_tree(&archetype_dir)?;
        let entry = fixture_entry("sample-d", "5050");
        let resolved = fixture_resolved(&archetype_dir)?;
        let _ = compose_sample(&entry, &HashMap::new(), Some(&resolved), &project)?;

        // Mutate the archetype source: append bytes, ensures different content + mtime.
        sleep(Duration::from_millis(10));
        let mut existing = fs::read_to_string(archetype_dir.join("APP.md"))?;
        existing.push_str("\nappended\n");
        fs::write(archetype_dir.join("APP.md"), existing)?;

        assert!(compose_needed(&entry, &resolved, &project)?);
        Ok(())
    }

    #[test]
    fn compose_needed_true_after_plan_entry_change() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path().join("proj");
        fs::create_dir_all(&project)?;
        let archetype_dir = tmp.path().join("arch");
        write_archetype_tree(&archetype_dir)?;
        let resolved = fixture_resolved(&archetype_dir)?;

        let entry_v1 = fixture_entry("sample-e", "1111");
        let _ = compose_sample(&entry_v1, &HashMap::new(), Some(&resolved), &project)?;

        let entry_v2 = fixture_entry("sample-e", "2222"); // different PORT
        assert!(compose_needed(&entry_v2, &resolved, &project)?);
        Ok(())
    }

    /// Rust seeds every `HashMap` with its own random keys, so two maps built
    /// from the same pairs iterate in different orders. A hash that folded in
    /// their `Debug` rendering changed on every construction, which meant every
    /// compose run missed the cache and `rm -rf`-ed the composed tree — taking
    /// any baseline written under `${MIRROIR_SAMPLE_DIR}` with it.
    #[test]
    fn the_plan_entry_hash_is_stable_across_freshly_built_maps() {
        let mut digests = BTreeSet::new();
        for _ in 0..5 {
            digests.insert(hash_plan_entry(&fixture_entry("sample-hash", "8080")));
        }
        assert_eq!(
            digests.len(),
            1,
            "five identical entries hashed to {} distinct digests: {digests:?}",
            digests.len()
        );
    }

    /// The encoding stays sensitive to what it encodes: a changed var value, a
    /// changed boot env value, and a var/env key swap each move the digest.
    #[test]
    fn the_plan_entry_hash_still_separates_different_entries() {
        let base = fixture_entry("sample-hash", "8080");
        let other_port = fixture_entry("sample-hash", "9090");
        assert_ne!(hash_plan_entry(&base), hash_plan_entry(&other_port));

        let mut renamed_var = fixture_entry("sample-hash", "8080");
        renamed_var.vars.remove("MESSAGE");
        renamed_var
            .vars
            .insert("GREETING".to_owned(), "hello".to_owned());
        assert_ne!(hash_plan_entry(&base), hash_plan_entry(&renamed_var));

        let mut other_env = fixture_entry("sample-hash", "8080");
        other_env.boot.env.insert("BETA".to_owned(), "3".to_owned());
        assert_ne!(hash_plan_entry(&base), hash_plan_entry(&other_env));

        let mut no_cwd = fixture_entry("sample-hash", "8080");
        no_cwd.boot.cwd = None;
        let mut empty_cwd = fixture_entry("sample-hash", "8080");
        empty_cwd.boot.cwd = Some(String::new());
        assert_ne!(
            hash_plan_entry(&no_cwd),
            hash_plan_entry(&empty_cwd),
            "an absent cwd must not hash like an empty one"
        );
    }

    /// The exit criterion, end to end: compose once, then five consecutive
    /// checks against freshly built entries all report the cache is valid.
    #[test]
    fn five_consecutive_checks_all_hit_the_cache() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path().join("proj");
        fs::create_dir_all(&project)?;
        let archetype_dir = tmp.path().join("arch");
        write_archetype_tree(&archetype_dir)?;
        let resolved = fixture_resolved(&archetype_dir)?;
        let _ = compose_sample(
            &fixture_entry("sample-cache", "6060"),
            &HashMap::new(),
            Some(&resolved),
            &project,
        )?;

        for attempt in 1..=5 {
            let entry = fixture_entry("sample-cache", "6060");
            assert!(
                !compose_needed(&entry, &resolved, &project)?,
                "check {attempt} of 5 missed the cache"
            );
        }
        Ok(())
    }
}
