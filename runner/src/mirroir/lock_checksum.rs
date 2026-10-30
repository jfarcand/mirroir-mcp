// ABOUTME: Recomputes each locked archetype's tree checksum and reports the records that no longer match.
// ABOUTME: This is what gives `--locked` / `--frozen` teeth: an edited pack is caught, not replayed.

use std::path::Path;

use tracing::info;

use crate::error::Result;
use crate::mirroir::lock_generate::checksum_directory;
use crate::mirroir::resolve::{ArchetypeOrigin, origin_directory};
use crate::parser::lockfile::{LockedOrigin, Lockfile, ResolvedRecord};

/// Recompute every locked archetype's directory checksum and return one
/// human-readable reason per record whose tree no longer hashes to what the
/// lockfile recorded.
///
/// The lockfile records `checksum: sha256:…` for each resolution. Comparing
/// ref strings and version pins alone accepts a tree whose *contents* changed
/// under a pin that did not — a locally edited archetype, a pack rewritten in
/// place, a tampered install — so the bytes are hashed again here and compared.
///
/// A record whose directory is gone is reported too: the lockfile claims a
/// resolution the disk cannot supply.
///
/// # Errors
///
/// [`crate::error::RunnerError::Io`] when an existing archetype directory
/// cannot be walked or one of its files cannot be read.
pub fn checksum_drift_reasons(
    lockfile: &Lockfile,
    project_root: &Path,
    home_root: &Path,
) -> Result<Vec<String>> {
    let mut reasons = Vec::new();
    for locked in &lockfile.archetypes {
        let reference = locked.reference.as_str();
        let Some(origin) = record_origin(&locked.resolved) else {
            reasons.push(format!(
                "ref `{reference}` is locked as a pack entry with no pack/version recorded"
            ));
            continue;
        };
        let directory = origin_directory(&origin, project_root, home_root);
        if !directory.is_dir() {
            reasons.push(format!(
                "ref `{reference}` is locked but its tree is absent at {}",
                directory.display()
            ));
            continue;
        }
        let observed = checksum_directory(&directory)?;
        if observed == locked.resolved.checksum {
            info!(reference, "lockfile checksum verified");
            continue;
        }
        reasons.push(format!(
            "ref `{reference}` is locked at checksum {locked_sum} but {dir} now hashes to {observed}",
            locked_sum = locked.resolved.checksum,
            dir = directory.display(),
        ));
    }
    Ok(reasons)
}

/// Rebuild the [`ArchetypeOrigin`] a record describes, so the install layout
/// is read from `origin_directory` rather than re-derived here.
///
/// Returns `None` for a record whose kind demands fields it does not carry —
/// a pack or user-global entry with no version, or a pack entry with no pack.
fn record_origin(record: &ResolvedRecord) -> Option<ArchetypeOrigin> {
    match record.kind {
        LockedOrigin::Pack => Some(ArchetypeOrigin::Pack {
            pack: record.pack.clone()?,
            name: record.name.clone(),
            version: record.version.clone()?,
        }),
        LockedOrigin::ProjectLocal => Some(ArchetypeOrigin::ProjectLocal {
            path: record.name.clone(),
        }),
        LockedOrigin::UserGlobal => Some(ArchetypeOrigin::UserGlobal {
            name: record.name.clone(),
            version: record.version.clone()?,
        }),
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::fs;
    use std::result::Result as StdResult;

    use chrono::Utc;

    use super::*;
    use crate::parser::lockfile::LockedArchetype;
    use crate::parser::version::ArtifactKind;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    /// A project-local archetype tree with one file, plus the lockfile that
    /// records its true checksum.
    fn locked_project_local(project_root: &Path) -> StdResult<Lockfile, Box<dyn StdError>> {
        let dir = project_root.join(".mirroir").join("archetypes/custom");
        fs::create_dir_all(&dir)?;
        fs::write(dir.join("archetype.md"), "the archetype body\n")?;
        let checksum = checksum_directory(&dir)?;
        Ok(Lockfile {
            version: ArtifactKind::Lockfile.current(),
            generated_at: Utc::now(),
            generated_by: "test".to_owned(),
            archetypes: vec![LockedArchetype {
                reference: "./archetypes/custom".to_owned(),
                resolved: ResolvedRecord {
                    kind: LockedOrigin::ProjectLocal,
                    pack: None,
                    name: "./archetypes/custom".to_owned(),
                    version: None,
                    source: None,
                    checksum,
                },
            }],
        })
    }

    #[test]
    fn an_untouched_tree_reports_no_drift() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let lock = locked_project_local(tmp.path())?;
        let reasons = checksum_drift_reasons(&lock, tmp.path(), Path::new("/nonexistent"))?;
        assert!(reasons.is_empty(), "unexpected drift: {reasons:?}");
        Ok(())
    }

    /// One byte. The ref string is identical, the version pin is identical,
    /// and the set-diff freshness check sees nothing — only the checksum does.
    #[test]
    fn one_edited_byte_is_reported() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let lock = locked_project_local(tmp.path())?;
        let file = tmp
            .path()
            .join(".mirroir")
            .join("archetypes/custom/archetype.md");
        fs::write(&file, "the archetype bodY\n")?;

        let reasons = checksum_drift_reasons(&lock, tmp.path(), Path::new("/nonexistent"))?;
        assert_eq!(reasons.len(), 1, "expected one reason, got {reasons:?}");
        assert!(
            reasons[0].contains("now hashes to"),
            "reason does not name the checksum drift: {}",
            reasons[0]
        );
        Ok(())
    }

    /// A file added to the tree changes the tree, even though every file that
    /// was there is untouched.
    #[test]
    fn an_added_file_is_reported() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let lock = locked_project_local(tmp.path())?;
        fs::write(
            tmp.path()
                .join(".mirroir")
                .join("archetypes/custom/extra.yaml"),
            "version: 1\n",
        )?;
        let reasons = checksum_drift_reasons(&lock, tmp.path(), Path::new("/nonexistent"))?;
        assert_eq!(reasons.len(), 1, "expected one reason, got {reasons:?}");
        Ok(())
    }

    #[test]
    fn a_missing_tree_is_reported_rather_than_erroring() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let lock = locked_project_local(tmp.path())?;
        fs::remove_dir_all(tmp.path().join(".mirroir").join("archetypes/custom"))?;
        let reasons = checksum_drift_reasons(&lock, tmp.path(), Path::new("/nonexistent"))?;
        assert_eq!(reasons.len(), 1, "expected one reason, got {reasons:?}");
        assert!(
            reasons[0].contains("tree is absent"),
            "reason does not name the missing tree: {}",
            reasons[0]
        );
        Ok(())
    }

    #[test]
    fn a_pack_record_without_a_version_is_reported_as_malformed() -> TestResult {
        let lock = Lockfile {
            version: ArtifactKind::Lockfile.current(),
            generated_at: Utc::now(),
            generated_by: "test".to_owned(),
            archetypes: vec![LockedArchetype {
                reference: "mirroir-skills/foo/bar@v1".to_owned(),
                resolved: ResolvedRecord {
                    kind: LockedOrigin::Pack,
                    pack: Some("mirroir-skills".to_owned()),
                    name: "foo/bar".to_owned(),
                    version: None,
                    source: None,
                    checksum: "sha256:xx".to_owned(),
                },
            }],
        };
        let reasons =
            checksum_drift_reasons(&lock, Path::new("/nonexistent"), Path::new("/nonexistent"))?;
        assert_eq!(reasons.len(), 1, "expected one reason, got {reasons:?}");
        assert!(
            reasons[0].contains("no pack/version recorded"),
            "reason does not name the malformed record: {}",
            reasons[0]
        );
        Ok(())
    }

    /// A pack tree on disk verifies through the same install layout the
    /// resolver uses — the point of routing both through `origin_directory`.
    #[test]
    fn a_pack_tree_verifies_under_the_home_root() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let home = tmp.path();
        let dir =
            home.join(".mirroir/skills/mirroir-skills/1.0.3/archetypes/atmosphere/ai-console");
        fs::create_dir_all(&dir)?;
        fs::write(dir.join("archetype.md"), "console\n")?;
        let checksum = checksum_directory(&dir)?;
        let mut lock = Lockfile {
            version: ArtifactKind::Lockfile.current(),
            generated_at: Utc::now(),
            generated_by: "test".to_owned(),
            archetypes: vec![LockedArchetype {
                reference: "mirroir-skills/atmosphere/ai-console@v1".to_owned(),
                resolved: ResolvedRecord {
                    kind: LockedOrigin::Pack,
                    pack: Some("mirroir-skills".to_owned()),
                    name: "atmosphere/ai-console".to_owned(),
                    version: Some("1.0.3".to_owned()),
                    source: None,
                    checksum,
                },
            }],
        };
        assert!(
            checksum_drift_reasons(&lock, Path::new("/nonexistent"), home)?.is_empty(),
            "a pack tree recorded truthfully must verify"
        );

        lock.archetypes[0].resolved.checksum = "sha256:deadbeef".to_owned();
        assert_eq!(
            checksum_drift_reasons(&lock, Path::new("/nonexistent"), home)?.len(),
            1
        );
        Ok(())
    }
}
