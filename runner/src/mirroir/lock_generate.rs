// ABOUTME: Lockfile generation — resolves every plan archetype ref and records source/version/checksum.
// ABOUTME: Walks the archetype tree for a deterministic sha256 and gathers best-effort git provenance.

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use chrono::Utc;
use sha2::{Digest, Sha256};

use crate::error::{Result, RunnerError};
use crate::mirroir::lock::format_ref;
use crate::mirroir::resolve::{ArchetypeOrigin, ResolvedArchetype, resolve_archetype};
use crate::parser::lockfile::{GitSource, LockedArchetype, LockedOrigin, Lockfile, ResolvedRecord};
use crate::parser::mirroir::{MirroirConfig, PlanEntrySource};
use crate::parser::version::ArtifactKind;

/// Regenerate the lockfile from scratch: walk every archetype ref in the
/// config, resolve it on disk, gather source/version/checksum info, and build
/// a new [`Lockfile`] in memory. Caller persists it via `write_lockfile`.
///
/// # Errors
///
/// * Anything [`resolve_archetype`] returns.
/// * [`RunnerError::Io`] when computing the directory checksum fails.
pub fn regenerate_lockfile(
    config: &MirroirConfig,
    project_root: &Path,
    home_root: &Path,
) -> Result<Lockfile> {
    let mut archetypes = Vec::new();
    let mut seen_refs: HashSet<String> = HashSet::new();

    for entry in config
        .plan
        .must_pass
        .iter()
        .chain(config.plan.nice_to_pass.iter())
    {
        if let PlanEntrySource::Archetypes { references } = &entry.source {
            for r in references {
                let reference = format_ref(r);
                if !seen_refs.insert(reference.clone()) {
                    // Same ref already locked; skip duplicate.
                    continue;
                }
                let resolved = resolve_archetype(r, project_root, home_root, None)?;
                let record = build_locked_record(&resolved)?;
                archetypes.push(LockedArchetype {
                    reference,
                    resolved: record,
                });
            }
        }
    }

    archetypes.sort_by(|a, b| a.reference.cmp(&b.reference));

    Ok(Lockfile {
        version: ArtifactKind::Lockfile.current(),
        generated_at: Utc::now(),
        generated_by: format!("mirroir-run {}", env!("CARGO_PKG_VERSION")),
        archetypes,
    })
}

fn build_locked_record(resolved: &ResolvedArchetype) -> Result<ResolvedRecord> {
    let checksum = checksum_directory(&resolved.directory)?;
    match &resolved.origin {
        ArchetypeOrigin::Pack {
            pack,
            name,
            version,
        } => {
            // Best-effort: walk up to the pack-version dir and read git info.
            let pack_version_root = resolved
                .directory
                .ancestors()
                .nth(2) // skip "archetypes" and "<name-components>"; walk varies — use deepest .git
                .unwrap_or(&resolved.directory)
                .to_path_buf();
            let source = gather_git_source(&pack_version_root).ok();
            Ok(ResolvedRecord {
                kind: LockedOrigin::Pack,
                pack: Some(pack.clone()),
                name: name.clone(),
                version: Some(version.clone()),
                source,
                checksum,
            })
        }
        ArchetypeOrigin::ProjectLocal { path } => Ok(ResolvedRecord {
            kind: LockedOrigin::ProjectLocal,
            pack: None,
            name: path.clone(),
            version: None,
            source: None,
            checksum,
        }),
        ArchetypeOrigin::UserGlobal { name, version } => Ok(ResolvedRecord {
            kind: LockedOrigin::UserGlobal,
            pack: None,
            name: name.clone(),
            version: Some(version.clone()),
            source: None,
            checksum,
        }),
    }
}

/// SHA-256 of all files in `dir` (recursive). Filenames are folded into the
/// hash in sorted order to produce a deterministic content checksum.
///
/// Generation records the result in each [`ResolvedRecord::checksum`];
/// [`crate::mirroir::lock::enforce_freshness`] recomputes it against the tree
/// on disk, which is what makes an edited archetype fail `--locked` /
/// `--frozen` instead of replaying silently.
///
/// # Errors
///
/// [`RunnerError::Io`] when the directory cannot be walked or a file read.
pub fn checksum_directory(dir: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    let mut entries: Vec<PathBuf> = Vec::new();
    collect_files(dir, dir, &mut entries)?;
    entries.sort();
    for rel in entries {
        let abs = dir.join(&rel);
        let bytes = fs::read(&abs).map_err(|source| RunnerError::Io {
            context: format!("read for checksum {}", abs.display()),
            source,
        })?;
        // Include path + content so structurally-different trees hash differently.
        hasher.update(rel.to_string_lossy().as_bytes());
        hasher.update([0u8]);
        hasher.update(&bytes);
    }
    let digest = hasher.finalize();
    Ok(format!("sha256:{}", hex::encode(digest)))
}

fn collect_files(root: &Path, current: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    let entries = fs::read_dir(current).map_err(|source| RunnerError::Io {
        context: format!("read_dir {}", current.display()),
        source,
    })?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_files(root, &path, out)?;
        } else if path.is_file() {
            let rel = path.strip_prefix(root).unwrap_or(&path).to_path_buf();
            out.push(rel);
        }
    }
    Ok(())
}

fn gather_git_source(dir: &Path) -> Result<GitSource> {
    let url = run_git(dir, &["remote", "get-url", "origin"])?;
    let commit = run_git(dir, &["rev-parse", "HEAD"])?;
    let tag = run_git(dir, &["describe", "--tags", "--exact-match", "HEAD"]).ok();
    Ok(GitSource { url, tag, commit })
}

fn run_git(dir: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .map_err(|source| RunnerError::Io {
            context: format!("git {} (cwd={})", args.join(" "), dir.display()),
            source,
        })?;
    if !output.status.success() {
        return Err(RunnerError::Io {
            context: format!(
                "git {} exit {:?} cwd={}",
                args.join(" "),
                output.status.code(),
                dir.display()
            ),
            source: io::Error::other(format!(
                "git stderr: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    #[test]
    fn checksum_directory_is_deterministic() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let dir = tmp.path();
        fs::write(dir.join("a.txt"), "alpha")?;
        fs::create_dir(dir.join("sub"))?;
        fs::write(dir.join("sub").join("b.txt"), "beta")?;

        let h1 = checksum_directory(dir)?;
        let h2 = checksum_directory(dir)?;
        assert_eq!(h1, h2);
        assert!(h1.starts_with("sha256:"));

        // Change a byte and verify the checksum changes.
        fs::write(dir.join("a.txt"), "alphaX")?;
        let h3 = checksum_directory(dir)?;
        assert_ne!(h1, h3);
        Ok(())
    }
}
