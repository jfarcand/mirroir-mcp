// ABOUTME: Compose archetype + plan entry → ready-to-replay `.mirroir/.build/<sample>/` tree.
// ABOUTME: Post-parse ${VAR} substitution on every source file; content-addressed cache (sha256 + mtime fast-path).

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use chrono::Utc;

use crate::error::{Result, RunnerError};
use crate::mirroir::compose_cache::{
    COMPOSE_MANIFEST_FILE, ComposeManifest, ComposeManifestArchetype, ComposeManifestInstance,
    SourceFileRecord, archetype_version, hash_plan_entry, sha256_hex,
};
use crate::mirroir::compose_synth::{
    build_substitution_env, substitute_markdown_with_yaml, substitute_yaml_text,
    synthesize_sample_md,
};
use crate::mirroir::error::MirroirError;
use crate::mirroir::resolve::ResolvedArchetype;
use crate::parser::archetype::ArchetypeRequiredEnv;
use crate::parser::mirroir::{PlanEntry, PlanEntrySource};
use crate::parser::version::ArtifactKind;

pub use crate::mirroir::compose_cache::compose_needed;

/// Directory name (under `.mirroir/`) where composed artifacts land.
pub const BUILD_DIR: &str = ".build";

/// Where the composed `<sample>/` tree for `entry` lives.
#[must_use]
pub fn build_dir_for(entry: &PlanEntry, project_root: &Path) -> PathBuf {
    project_root
        .join(".mirroir")
        .join(BUILD_DIR)
        .join(&entry.name)
}

/// Top-level outcome of [`compose_sample`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ComposedSample {
    /// Directory mirroir-run consumes via `run_sample`. For local: entries this
    /// is the source path (no build/ copy); for archetype-extending entries
    /// it's `<project>/.mirroir/.build/<entry.name>/`.
    pub directory: PathBuf,
    /// True when the sample was authored fully under `.mirroir/apps/<...>` and
    /// compose was a no-op. Useful for diagnostics + telemetry.
    pub local: bool,
}

/// Compose `entry` into `<repo>/.mirroir/.build/<entry.name>/` from `resolved`.
///
/// For `PlanEntrySource::Local` entries, compose is a passthrough — the
/// returned [`ComposedSample::directory`] points at the source `.mirroir/<rel>/`
/// directory and no `.build/` tree is created.
///
/// For `PlanEntrySource::Archetypes` entries, compose:
/// 1. Substitutes `${VAR}` placeholders post-parse on every archetype source file.
/// 2. Writes `APP.md`, `SKILL.md`, `scenarios/<flow>.yaml` for each selected flow.
/// 3. Synthesizes a `SAMPLE.md` from the plan entry's boot + flow list.
/// 4. Records source-file sha256s + plan-entry hash in `.compose-manifest.json`.
///
/// # Errors
///
/// * [`RunnerError::Io`] for any read/write/mkdir failure.
/// * [`MirroirError::SampleMissing`] when a Local entry's path doesn't exist.
/// * [`MirroirError::ComposeFailed`] for malformed archetype-side files.
pub fn compose_sample(
    entry: &PlanEntry,
    suite_env: &HashMap<String, String>,
    resolved: Option<&ResolvedArchetype>,
    project_root: &Path,
) -> Result<ComposedSample> {
    match &entry.source {
        PlanEntrySource::Local { path } => {
            let abs = project_root.join(".mirroir").join(path);
            if !abs.is_dir() {
                return Err(MirroirError::SampleMissing {
                    sample: entry.name.clone(),
                    expected_path: abs,
                }
                .into());
            }
            Ok(ComposedSample {
                directory: abs,
                local: true,
            })
        }
        PlanEntrySource::Archetypes { .. } => {
            let resolved = resolved.ok_or_else(|| {
                RunnerError::Mirroir(MirroirError::ComposeFailed {
                    sample: entry.name.clone(),
                    context: "archetype entry composed without a resolved archetype".to_owned(),
                    source: io::Error::other("missing resolved archetype"),
                })
            })?;
            compose_archetype_entry(entry, suite_env, resolved, project_root)
        }
    }
}

fn compose_archetype_entry(
    entry: &PlanEntry,
    suite_env: &HashMap<String, String>,
    resolved: &ResolvedArchetype,
    project_root: &Path,
) -> Result<ComposedSample> {
    let build = build_dir_for(entry, project_root);
    if build.exists() {
        fs::remove_dir_all(&build).map_err(|source| RunnerError::Io {
            context: format!("clear stale build dir {}", build.display()),
            source,
        })?;
    }
    fs::create_dir_all(&build).map_err(|source| RunnerError::Io {
        context: format!("mkdir build dir {}", build.display()),
        source,
    })?;
    fs::create_dir_all(build.join("scenarios")).map_err(|source| RunnerError::Io {
        context: format!("mkdir scenarios dir {}", build.display()),
        source,
    })?;

    // Fold archetype-declared `requires.env` defaults into the effective
    // boot.env before substitution + SAMPLE.md synthesis. A default applies
    // only when the plan entry's boot.env omits that key; explicit boot.env
    // always wins. The original `entry` is kept for the plan-entry cache hash.
    let effective = apply_required_env_defaults(entry, &resolved.manifest.requires.env);
    let env = build_substitution_env(&effective, suite_env, &resolved.manifest.requires.vars);
    let mut source_records = Vec::new();

    // Copy + substitute APP.md and SKILL.md if present in the archetype.
    for fname in ["APP.md", "SKILL.md"] {
        let src = resolved.directory.join(fname);
        if src.is_file() {
            let bytes = fs::read(&src).map_err(|source| RunnerError::Io {
                context: format!("read archetype file {}", src.display()),
                source,
            })?;
            source_records.push(SourceFileRecord {
                path: PathBuf::from(fname),
                sha256: sha256_hex(&bytes),
            });
            let raw = String::from_utf8_lossy(&bytes).into_owned();
            let substituted = substitute_markdown_with_yaml(&raw, &env)?;
            fs::write(build.join(fname), substituted).map_err(|source| RunnerError::Io {
                context: format!("write composed {fname}"),
                source,
            })?;
        }
    }

    // Always include archetype.md as a provenance copy in source_records (not
    // emitted to .build/ — the runner doesn't read it).
    let archetype_md = resolved.directory.join("archetype.md");
    if archetype_md.is_file() {
        let bytes = fs::read(&archetype_md).map_err(|source| RunnerError::Io {
            context: format!("read archetype manifest {}", archetype_md.display()),
            source,
        })?;
        source_records.push(SourceFileRecord {
            path: PathBuf::from("archetype.md"),
            sha256: sha256_hex(&bytes),
        });
    }

    // For each selected flow, substitute its scenario YAML and write under build/scenarios/.
    for flow in &entry.flows {
        let src = resolved
            .directory
            .join("scenarios")
            .join(format!("{flow}.yaml"));
        if !src.is_file() {
            return Err(MirroirError::ComposeFailed {
                sample: entry.name.clone(),
                context: format!(
                    "flow `{flow}` is not provided by archetype `{}` (file {} missing)",
                    resolved.manifest.name,
                    src.display(),
                ),
                source: io::Error::other("flow scenario file not found"),
            }
            .into());
        }
        let bytes = fs::read(&src).map_err(|source| RunnerError::Io {
            context: format!("read flow scenario {}", src.display()),
            source,
        })?;
        source_records.push(SourceFileRecord {
            path: PathBuf::from("scenarios").join(format!("{flow}.yaml")),
            sha256: sha256_hex(&bytes),
        });
        let substituted = substitute_yaml_text(&String::from_utf8_lossy(&bytes), &env)?;
        let out = build.join("scenarios").join(format!("{flow}.yaml"));
        fs::write(&out, substituted).map_err(|source| RunnerError::Io {
            context: format!("write composed scenario {}", out.display()),
            source,
        })?;
    }

    // Synthesize SAMPLE.md from the plan entry's boot + flow list. Uses the
    // effective entry so archetype `requires.env` defaults reach boot.env.
    let sample_md = synthesize_sample_md(&effective, &env);
    fs::write(build.join("SAMPLE.md"), sample_md).map_err(|source| RunnerError::Io {
        context: "write composed SAMPLE.md".to_owned(),
        source,
    })?;

    // Write the compose manifest.
    let manifest = ComposeManifest {
        version: ArtifactKind::ComposeManifest.current(),
        composed_at: Utc::now(),
        archetype: ComposeManifestArchetype {
            reference: format!("{:?}", resolved.origin),
            resolved_version: archetype_version(resolved),
            source_files: source_records,
        },
        instance: ComposeManifestInstance {
            name: entry.name.clone(),
            plan_entry_sha256: hash_plan_entry(entry),
        },
    };
    let manifest_json =
        serde_json::to_string_pretty(&manifest).map_err(|source| RunnerError::Io {
            context: "serialize compose manifest".to_owned(),
            source: io::Error::other(source.to_string()),
        })?;
    fs::write(build.join(COMPOSE_MANIFEST_FILE), manifest_json).map_err(|source| {
        RunnerError::Io {
            context: "write compose manifest".to_owned(),
            source,
        }
    })?;

    Ok(ComposedSample {
        directory: build,
        local: false,
    })
}

/// Clone `entry` with archetype `requires.env` defaults folded into `boot.env`
/// for any key the entry omits. Explicit `boot.env` values always win; a
/// declared env var with no `default` is left for the boot process to supply.
fn apply_required_env_defaults(
    entry: &PlanEntry,
    required_env: &[ArchetypeRequiredEnv],
) -> PlanEntry {
    let mut merged = entry.clone();
    for spec in required_env {
        if let Some(default) = &spec.default {
            merged
                .boot
                .env
                .entry(spec.name.clone())
                .or_insert_with(|| default.clone());
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::fs;
    use std::result::Result as StdResult;

    use super::*;
    use crate::mirroir::resolve::{ArchetypeOrigin, ResolvedArchetype};
    use crate::parser::archetype::parse_archetype_manifest;
    use crate::parser::mirroir::{
        ArchetypeRef, ArchetypeRefKind, PlanEntry, PlanEntryBoot, PlanEntrySource,
    };

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
        let mut vars = HashMap::new();
        vars.insert("PORT".to_owned(), port.to_owned());
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
                env: HashMap::new(),
                timeout_s: None,
                boot_once: true,
                boot_ready_port: Some(port.parse::<u16>().unwrap_or(8080)),
                boot_ready_timeout_s: Some(120),
            },
            skip: false,
        }
    }

    #[test]
    fn compose_writes_scenarios_with_substituted_vars() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path().join("proj");
        fs::create_dir_all(&project)?;
        let archetype_dir = tmp.path().join("arch");
        write_archetype_tree(&archetype_dir)?;

        let entry = fixture_entry("sample-a", "8080");
        let resolved = fixture_resolved(&archetype_dir)?;
        let suite_env = HashMap::new();
        let composed = compose_sample(&entry, &suite_env, Some(&resolved), &project)?;
        assert!(!composed.local);

        let scenario = fs::read_to_string(composed.directory.join("scenarios/chat-stream.yaml"))?;
        assert!(scenario.contains("http://127.0.0.1:8080/console/"));
        assert!(scenario.contains("type: hello"));
        Ok(())
    }

    #[test]
    fn compose_emits_sample_md_with_boot_wiring() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path().join("proj");
        fs::create_dir_all(&project)?;
        let archetype_dir = tmp.path().join("arch");
        write_archetype_tree(&archetype_dir)?;
        let entry = fixture_entry("sample-b", "9090");
        let resolved = fixture_resolved(&archetype_dir)?;
        let composed = compose_sample(&entry, &HashMap::new(), Some(&resolved), &project)?;
        let sample_md = fs::read_to_string(composed.directory.join("SAMPLE.md"))?;
        assert!(sample_md.contains("name: \"sample-b\""));
        assert!(sample_md.contains("command: \"echo hi\""));
        assert!(sample_md.contains("boot_ready_port: 9090"));
        assert!(sample_md.contains("- scenarios/chat-stream.yaml"));
        Ok(())
    }

    #[test]
    fn local_entry_returns_source_path_directly() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path();
        let apps_dir = project.join(".mirroir/apps/legacy");
        fs::create_dir_all(&apps_dir)?;
        fs::write(apps_dir.join("SAMPLE.md"), "version: 1\nplan: {}")?;

        let entry = PlanEntry {
            name: "legacy".to_owned(),
            source: PlanEntrySource::Local {
                path: PathBuf::from("apps/legacy"),
            },
            flows: vec![],
            vars: HashMap::new(),
            boot: PlanEntryBoot {
                command: "echo".to_owned(),
                cwd: None,
                env: HashMap::new(),
                timeout_s: None,
                boot_once: true,
                boot_ready_port: None,
                boot_ready_timeout_s: None,
            },
            skip: false,
        };
        let composed = compose_sample(&entry, &HashMap::new(), None, project)?;
        assert!(composed.local);
        assert_eq!(composed.directory, apps_dir);
        Ok(())
    }

    #[test]
    fn compose_folds_required_env_defaults_into_sample() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path().join("proj");
        fs::create_dir_all(&project)?;
        let archetype_dir = tmp.path().join("arch");
        write_archetype_tree(&archetype_dir)?;
        // Re-author the manifest with a requires.env default + a defaultless var.
        fs::write(
            archetype_dir.join("archetype.md"),
            "```yaml\nversion: 1\nname: test/sample\narchetype_version: 1.0.0\nrequires:\n  env:\n    - name: LLM_MODE\n      default: fake\n    - name: RUNTIME_SECRET\nprovides:\n  flows:\n    - chat-stream\n```\n",
        )?;
        let resolved = fixture_resolved(&archetype_dir)?;

        // Entry omits LLM_MODE → archetype default lands in the synthesized boot.env.
        let entry = fixture_entry("sample-env", "8080");
        let composed = compose_sample(&entry, &HashMap::new(), Some(&resolved), &project)?;
        let sample_md = fs::read_to_string(composed.directory.join("SAMPLE.md"))?;
        // synthesize_sample_md quotes both key and value for boot.env entries.
        assert!(sample_md.contains("\"LLM_MODE\": \"fake\""));
        // A declared var without a default is not invented.
        assert!(!sample_md.contains("RUNTIME_SECRET"));

        // Explicit boot.env wins over the archetype default.
        let mut entry_override = fixture_entry("sample-env-override", "8080");
        entry_override
            .boot
            .env
            .insert("LLM_MODE".to_owned(), "real".to_owned());
        let composed2 =
            compose_sample(&entry_override, &HashMap::new(), Some(&resolved), &project)?;
        let sample_md2 = fs::read_to_string(composed2.directory.join("SAMPLE.md"))?;
        assert!(sample_md2.contains("\"LLM_MODE\": \"real\""));
        assert!(!sample_md2.contains("\"LLM_MODE\": \"fake\""));
        Ok(())
    }
}
