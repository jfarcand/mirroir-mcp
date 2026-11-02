// ABOUTME: Archetype reference resolution — turn an ArchetypeRef into an on-disk directory + manifest.
// ABOUTME: Dispatches on the ref's declared kind (project-local / pack / user-global) to one resolver — not a fallback cascade.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{Result, RunnerError};
use crate::mirroir::error::MirroirError;
use crate::mirroir::resolve_version::resolve_version_from_constraint;
use crate::parser::archetype::{ArchetypeManifest, parse_archetype_manifest};
use crate::parser::mirroir::{ArchetypeRef, ArchetypeRefKind};

/// Filename of the archetype manifest at the root of an archetype directory.
pub const ARCHETYPE_MANIFEST_FILE: &str = "archetype.md";

/// Directory inside a pack checkout that holds its archetypes.
pub const PACK_ARCHETYPES_DIR: &str = "archetypes";

/// Result of resolving an [`ArchetypeRef`] against its declared-kind resolver.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedArchetype {
    /// Where the archetype was found (pack / project-local / user-global).
    pub origin: ArchetypeOrigin,
    /// Parsed manifest. The runner uses `provides.flows` for flow validation
    /// and `requires.vars` for compose-time defaults.
    pub manifest: ArchetypeManifest,
    /// Absolute path to the archetype directory on disk.
    pub directory: PathBuf,
}

/// Where a resolved archetype lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArchetypeOrigin {
    /// Pack-installed: `~/.mirroir/skills/<pack>/<version>/archetypes/<name>/`.
    Pack {
        /// Pack identifier (e.g., `mirroir-skills`).
        pack: String,
        /// Archetype name within the pack (e.g., `atmosphere/ai-console`).
        name: String,
        /// Resolved exact version (e.g., `1.0.3`).
        version: String,
    },
    /// Project-local archetype under `<project>/.mirroir/<rel-path>`.
    ProjectLocal {
        /// Path as declared in the ref (`./archetypes/foo` etc.).
        path: String,
    },
    /// User-global: `~/.mirroir/archetypes/<name>/<version>/`.
    UserGlobal {
        /// Archetype name as it lives under `~/.mirroir/archetypes/`.
        name: String,
        /// Resolved exact version.
        version: String,
    },
}

/// The on-disk directory an [`ArchetypeOrigin`] lives in.
///
/// Single source of truth for the install layout: the three resolvers below
/// build their origin first and ask this function where it goes, and the
/// lockfile's checksum verification asks the same question of a recorded
/// [`crate::parser::lockfile::ResolvedRecord`]. One layout, one function.
#[must_use]
pub fn origin_directory(
    origin: &ArchetypeOrigin,
    project_root: &Path,
    home_root: &Path,
) -> PathBuf {
    match origin {
        ArchetypeOrigin::Pack {
            pack,
            name,
            version,
        } => pack_version_directory(home_root, pack, version)
            .join(PACK_ARCHETYPES_DIR)
            .join(name),
        ArchetypeOrigin::ProjectLocal { path } => project_root
            .join(".mirroir")
            .join(strip_leading_dot_slash(path)),
        ArchetypeOrigin::UserGlobal { name, version } => home_root
            .join(".mirroir")
            .join("archetypes")
            .join(name)
            .join(version),
    }
}

/// Where installed packs live: `~/.mirroir/skills/`.
#[must_use]
pub fn skills_root(home_root: &Path) -> PathBuf {
    home_root.join(".mirroir").join("skills")
}

/// Where every installed version of `pack` lives:
/// `~/.mirroir/skills/<pack>/`.
#[must_use]
pub fn pack_directory(home_root: &Path, pack: &str) -> PathBuf {
    skills_root(home_root).join(pack)
}

/// The checkout of one installed pack version:
/// `~/.mirroir/skills/<pack>/<version>/`. `pack install` writes it, the
/// resolver reads archetypes under it, and lockfile generation reads its git
/// provenance from it.
#[must_use]
pub fn pack_version_directory(home_root: &Path, pack: &str, version: &str) -> PathBuf {
    pack_directory(home_root, pack).join(version)
}

/// Resolve an [`ArchetypeRef`] to an on-disk archetype.
///
/// * `project_root` — repository root (the directory containing `.mirroir/`).
/// * `home_root` — value of `$HOME` (or an injected tempdir during tests).
/// * `locked_version` — when `Some`, exact version pin from the lockfile.
///   This overrides any constraint in `archetype_ref.version` and skips the
///   "highest installed match" scan.
///
/// # Errors
///
/// * [`MirroirError::ArchetypeNotFound`] — no on-disk match.
/// * Anything [`parse_archetype_manifest`] returns when reading the archetype's
///   `archetype.md`.
pub fn resolve_archetype(
    archetype_ref: &ArchetypeRef,
    project_root: &Path,
    home_root: &Path,
    locked_version: Option<&str>,
) -> Result<ResolvedArchetype> {
    match archetype_ref.kind {
        ArchetypeRefKind::ProjectLocal => resolve_project_local(archetype_ref, project_root),
        ArchetypeRefKind::Pack => resolve_pack(archetype_ref, home_root, locked_version),
        ArchetypeRefKind::UserGlobal => {
            resolve_user_global(archetype_ref, home_root, locked_version)
        }
    }
}

fn resolve_project_local(
    archetype_ref: &ArchetypeRef,
    project_root: &Path,
) -> Result<ResolvedArchetype> {
    // ArchetypeRef.name carries the literal `./<path>` for project-local refs.
    let origin = ArchetypeOrigin::ProjectLocal {
        path: archetype_ref.name.clone(),
    };
    let candidate = origin_directory(&origin, project_root, Path::new(""));
    let manifest_path = candidate.join(ARCHETYPE_MANIFEST_FILE);
    if !manifest_path.is_file() {
        return Err(MirroirError::ArchetypeNotFound {
            reference: archetype_ref.name.clone(),
            searched: vec![candidate],
        }
        .into());
    }
    let manifest = load_manifest_from_path(&manifest_path)?;
    Ok(ResolvedArchetype {
        origin,
        manifest,
        directory: candidate,
    })
}

fn resolve_pack(
    archetype_ref: &ArchetypeRef,
    home_root: &Path,
    locked_version: Option<&str>,
) -> Result<ResolvedArchetype> {
    let pack = archetype_ref.pack.as_deref().ok_or_else(|| {
        RunnerError::Mirroir(MirroirError::ArchetypeNotFound {
            reference: archetype_ref.name.clone(),
            searched: vec![],
        })
    })?;
    let pack_root = pack_directory(home_root, pack);

    let resolved_version = resolve_version_from_constraint(
        &pack_root,
        archetype_ref.version.as_deref(),
        locked_version,
    )?;
    let reference = format!(
        "{pack}/{name}@{resolved_version}",
        name = archetype_ref.name
    );
    let origin = ArchetypeOrigin::Pack {
        pack: pack.to_owned(),
        name: archetype_ref.name.clone(),
        version: resolved_version,
    };
    let archetype_dir = origin_directory(&origin, Path::new(""), home_root);
    let manifest_path = archetype_dir.join(ARCHETYPE_MANIFEST_FILE);
    if !manifest_path.is_file() {
        return Err(MirroirError::ArchetypeNotFound {
            reference,
            searched: vec![archetype_dir],
        }
        .into());
    }
    let manifest = load_manifest_from_path(&manifest_path)?;
    Ok(ResolvedArchetype {
        origin,
        manifest,
        directory: archetype_dir,
    })
}

fn resolve_user_global(
    archetype_ref: &ArchetypeRef,
    home_root: &Path,
    locked_version: Option<&str>,
) -> Result<ResolvedArchetype> {
    let archetype_root = home_root
        .join(".mirroir")
        .join("archetypes")
        .join(&archetype_ref.name);
    let resolved_version = resolve_version_from_constraint(
        &archetype_root,
        archetype_ref.version.as_deref(),
        locked_version,
    )?;
    let reference = format!("user/{name}@{resolved_version}", name = archetype_ref.name);
    let origin = ArchetypeOrigin::UserGlobal {
        name: archetype_ref.name.clone(),
        version: resolved_version,
    };
    let archetype_dir = origin_directory(&origin, Path::new(""), home_root);
    let manifest_path = archetype_dir.join(ARCHETYPE_MANIFEST_FILE);
    if !manifest_path.is_file() {
        return Err(MirroirError::ArchetypeNotFound {
            reference,
            searched: vec![archetype_dir],
        }
        .into());
    }
    let manifest = load_manifest_from_path(&manifest_path)?;
    Ok(ResolvedArchetype {
        origin,
        manifest,
        directory: archetype_dir,
    })
}

fn load_manifest_from_path(path: &Path) -> Result<ArchetypeManifest> {
    let raw = fs::read_to_string(path).map_err(|source| RunnerError::Io {
        context: format!("read archetype manifest {}", path.display()),
        source,
    })?;
    parse_archetype_manifest(&path.display().to_string(), &raw)
}

/// Pick the version to use from the installed directories under `root`.
///
/// Resolution priority (highest wins):
/// 1. `locked_version` — exact pin from the lockfile.
/// 2. `ref_constraint` — version constraint from the ref (`v1`, `1.2`, `1.2.3`).
/// 3. Floating "latest": highest semver-parseable directory.
///
/// Returns `MirroirArchetypeNotFound` when the root doesn't exist, contains no
/// versioned directories, or contains none that satisfy the constraint.
fn strip_leading_dot_slash(s: &str) -> &str {
    s.strip_prefix("./").unwrap_or(s)
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::fs;
    use std::result::Result as StdResult;

    use super::*;
    use crate::parser::mirroir::ArchetypeRef;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    use std::fmt::Write as _;
    use std::io;

    fn write_archetype(dir: &Path, name: &str, version: &str, flows: &[&str]) -> io::Result<()> {
        fs::create_dir_all(dir)?;
        let mut flows_yaml = String::new();
        for f in flows {
            // `Write` impl on `String` is infallible; the result is folded into a panic-free buffer.
            let _ = writeln!(flows_yaml, "    - {f}");
        }
        let manifest = format!(
            "```yaml\nversion: 1\nname: {name}\narchetype_version: {version}\nprovides:\n  flows:\n{flows_yaml}```\n"
        );
        fs::write(dir.join("archetype.md"), manifest)?;
        Ok(())
    }

    #[test]
    fn resolves_project_local_archetype() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let project = tmp.path();
        let custom = project
            .join(".mirroir")
            .join("archetypes")
            .join("custom-flow");
        write_archetype(&custom, "custom/flow", "0.1.0", &["smoke"])?;

        let r = ArchetypeRef::parse("./archetypes/custom-flow")?;
        let resolved = resolve_archetype(&r, project, Path::new("/nonexistent"), None)?;
        assert!(matches!(
            resolved.origin,
            ArchetypeOrigin::ProjectLocal { .. }
        ));
        assert_eq!(resolved.manifest.name, "custom/flow");
        assert_eq!(resolved.manifest.provides.flows, vec!["smoke"]);
        Ok(())
    }

    #[test]
    fn resolves_pack_archetype_with_exact_version() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let home = tmp.path();
        let dir = home
            .join(".mirroir")
            .join("skills")
            .join("mirroir-skills")
            .join("1.0.3")
            .join("archetypes")
            .join("atmosphere/ai-console");
        write_archetype(&dir, "atmosphere/ai-console", "1.0.3", &["chat-stream"])?;

        let r = ArchetypeRef::parse("mirroir-skills/atmosphere/ai-console@1.0.3")?;
        let resolved = resolve_archetype(&r, Path::new("/proj"), home, None)?;
        match &resolved.origin {
            ArchetypeOrigin::Pack {
                pack,
                name,
                version,
            } => {
                assert_eq!(pack, "mirroir-skills");
                assert_eq!(name, "atmosphere/ai-console");
                assert_eq!(version, "1.0.3");
            }
            other => return Err(format!("expected Pack, got {other:?}").into()),
        }
        Ok(())
    }

    #[test]
    fn resolves_pack_archetype_with_floating_major_picks_highest() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let home = tmp.path();
        for v in &["1.0.0", "1.0.3", "1.1.0", "2.0.0"] {
            let dir = home
                .join(".mirroir/skills/mirroir-skills")
                .join(v)
                .join("archetypes/foo/bar");
            write_archetype(&dir, "foo/bar", v, &["s"])?;
        }
        let r = ArchetypeRef::parse("mirroir-skills/foo/bar@v1")?;
        let resolved = resolve_archetype(&r, Path::new("/proj"), home, None)?;
        match &resolved.origin {
            ArchetypeOrigin::Pack { version, .. } => assert_eq!(version, "1.1.0"),
            other => return Err(format!("expected Pack, got {other:?}").into()),
        }
        Ok(())
    }

    #[test]
    fn resolves_pack_archetype_with_floating_minor() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let home = tmp.path();
        for v in &["1.0.0", "1.0.5", "1.1.0", "1.1.7"] {
            let dir = home
                .join(".mirroir/skills/mirroir-skills")
                .join(v)
                .join("archetypes/foo/bar");
            write_archetype(&dir, "foo/bar", v, &["s"])?;
        }
        let r = ArchetypeRef::parse("mirroir-skills/foo/bar@v1.0")?;
        let resolved = resolve_archetype(&r, Path::new("/proj"), home, None)?;
        match &resolved.origin {
            ArchetypeOrigin::Pack { version, .. } => assert_eq!(version, "1.0.5"),
            other => return Err(format!("expected Pack, got {other:?}").into()),
        }
        Ok(())
    }

    #[test]
    fn locked_version_overrides_ref_constraint() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let home = tmp.path();
        for v in &["1.0.0", "1.0.5", "2.0.0"] {
            let dir = home
                .join(".mirroir/skills/mirroir-skills")
                .join(v)
                .join("archetypes/foo/bar");
            write_archetype(&dir, "foo/bar", v, &["s"])?;
        }
        // Ref says @v2, but locked says use 1.0.5 exactly.
        let r = ArchetypeRef::parse("mirroir-skills/foo/bar@v2")?;
        let resolved = resolve_archetype(&r, Path::new("/proj"), home, Some("1.0.5"))?;
        match &resolved.origin {
            ArchetypeOrigin::Pack { version, .. } => assert_eq!(version, "1.0.5"),
            other => return Err(format!("expected Pack, got {other:?}").into()),
        }
        Ok(())
    }

    #[test]
    fn missing_archetype_returns_not_found() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let r = ArchetypeRef::parse("mirroir-skills/foo/bar@1.0.0")?;
        match resolve_archetype(&r, Path::new("/proj"), tmp.path(), None) {
            Err(RunnerError::Mirroir(MirroirError::ArchetypeNotFound { .. })) => Ok(()),
            other => Err(format!("expected MirroirArchetypeNotFound, got {other:?}").into()),
        }
    }

    #[test]
    fn resolves_user_global_archetype() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let home = tmp.path();
        let dir = home.join(".mirroir/archetypes/internal-dashboard/1.0.0");
        write_archetype(&dir, "internal-dashboard", "1.0.0", &["smoke"])?;

        let r = ArchetypeRef::parse("user/internal-dashboard@1.0.0")?;
        let resolved = resolve_archetype(&r, Path::new("/proj"), home, None)?;
        match &resolved.origin {
            ArchetypeOrigin::UserGlobal { name, version } => {
                assert_eq!(name, "internal-dashboard");
                assert_eq!(version, "1.0.0");
            }
            other => return Err(format!("expected UserGlobal, got {other:?}").into()),
        }
        Ok(())
    }
}
