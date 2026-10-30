// ABOUTME: Lockfile generation, freshness check, and --locked/--frozen enforcement.
// ABOUTME: Generation gathers git source info + sha256 of archetype tree; freshness compares config vs lockfile.

use std::fs;
use std::path::Path;

use tracing::warn;

use crate::error::{Result, RunnerError};
use crate::mirroir::error::MirroirError;
use crate::mirroir::lock_checksum::checksum_drift_reasons;
use crate::parser::lockfile::{Lockfile, parse_lockfile, serialize_lockfile};

pub use crate::mirroir::lock_freshness::{FreshnessVerdict, check_lockfile_fresh, format_ref};
pub use crate::mirroir::lock_generate::regenerate_lockfile;

/// How strict to be when the lockfile is stale relative to `mirroir.yaml`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LockfileMode {
    /// Local-dev default — auto-regenerate stale lockfile with a stderr warning.
    Default,
    /// CI gate — error on stale lockfile.
    Locked,
    /// Hermetic offline — error on stale OR on any network requirement.
    Frozen,
}

/// Enforce the freshness verdict according to the chosen mode.
///
/// Two questions are asked, and both feed the same verdict: does the lockfile
/// still describe the same ref set and version pins as `mirroir.yaml`
/// (`verdict`, from [`check_lockfile_fresh`]), and does each locked
/// archetype's tree still hash to the `checksum:` the lockfile recorded
/// ([`checksum_drift_reasons`])? A pin that did not move over content that did
/// is exactly what a lockfile exists to catch, so the checksum is recomputed
/// here rather than trusted.
///
/// `Default` is local-dev mode: both kinds of drift are a warning naming
/// `mirroir-run accept`, which re-records the lockfile along with every other
/// baseline. `Locked` and `Frozen` are the CI gates and refuse.
///
/// # Errors
///
/// * [`MirroirError::LockfileStale`] when anything drifted AND mode is
///   `Locked` or `Frozen`.
/// * [`RunnerError::Io`] when a locked archetype's tree cannot be re-hashed.
pub fn enforce_freshness(
    verdict: &FreshnessVerdict,
    mode: LockfileMode,
    lockfile: &Lockfile,
    project_root: &Path,
    home_root: &Path,
) -> Result<()> {
    let mut reasons = match verdict {
        FreshnessVerdict::Fresh => Vec::new(),
        FreshnessVerdict::Stale { reasons } => reasons.clone(),
    };
    reasons.extend(checksum_drift_reasons(lockfile, project_root, home_root)?);

    if reasons.is_empty() {
        return Ok(());
    }
    match mode {
        LockfileMode::Default => {
            warn!(
                reasons = %reasons.join("; "),
                "the lockfile disagrees with the archetype trees on disk; `mirroir-run accept` re-records it"
            );
            Ok(())
        }
        LockfileMode::Locked | LockfileMode::Frozen => Err(MirroirError::LockfileStale {
            reason: reasons.join("; "),
        }
        .into()),
    }
}

/// Read a lockfile from disk; convenience wrapper for callers.
///
/// # Errors
///
/// * [`RunnerError::Io`] when the file can't be read.
/// * [`RunnerError::YamlParse`] / [`RunnerError::UnsupportedVersion`] from parsing.
pub fn read_lockfile(path: &Path) -> Result<Lockfile> {
    let raw = fs::read_to_string(path).map_err(|source| RunnerError::Io {
        context: format!("read lockfile at {}", path.display()),
        source,
    })?;
    parse_lockfile(&path.display().to_string(), &raw)
}

/// Write a lockfile to disk (serialized via [`serialize_lockfile`]).
///
/// # Errors
///
/// * [`RunnerError::Io`] when the file can't be written.
/// * [`RunnerError::YamlParse`] when serialization fails.
pub fn write_lockfile(path: &Path, lockfile: &Lockfile) -> Result<()> {
    let yaml = serialize_lockfile(lockfile)?;
    fs::write(path, yaml).map_err(|source| RunnerError::Io {
        context: format!("write lockfile at {}", path.display()),
        source,
    })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use chrono::Utc;

    use super::*;
    use crate::mirroir::lock_generate::checksum_directory;
    use crate::parser::lockfile::{LockedArchetype, LockedOrigin, ResolvedRecord};
    use crate::parser::version::ArtifactKind;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn empty_lockfile() -> Lockfile {
        Lockfile {
            version: ArtifactKind::Lockfile.current(),
            generated_at: Utc::now(),
            generated_by: "test".to_owned(),
            archetypes: Vec::new(),
        }
    }

    /// Enforcement against a lockfile with no entries: only the verdict is in
    /// play, since there is no recorded tree to re-hash.
    fn enforce(verdict: &FreshnessVerdict, mode: LockfileMode) -> Result<()> {
        enforce_freshness(
            verdict,
            mode,
            &empty_lockfile(),
            Path::new("/nonexistent"),
            Path::new("/nonexistent"),
        )
    }

    #[test]
    fn enforce_default_passes_on_stale() -> TestResult {
        let v = FreshnessVerdict::Stale {
            reasons: vec!["drift".to_owned()],
        };
        enforce(&v, LockfileMode::Default)?;
        Ok(())
    }

    #[test]
    fn enforce_locked_errors_on_stale() {
        let v = FreshnessVerdict::Stale {
            reasons: vec!["drift".to_owned()],
        };
        assert!(matches!(
            enforce(&v, LockfileMode::Locked),
            Err(RunnerError::Mirroir(MirroirError::LockfileStale { .. }))
        ));
    }

    #[test]
    fn enforce_frozen_errors_on_stale() {
        let v = FreshnessVerdict::Stale {
            reasons: vec!["drift".to_owned()],
        };
        assert!(matches!(
            enforce(&v, LockfileMode::Frozen),
            Err(RunnerError::Mirroir(MirroirError::LockfileStale { .. }))
        ));
    }

    /// The hole this closes: the ref set matches, the version pin matches, the
    /// freshness verdict is `Fresh` — and one byte inside the locked tree
    /// changed. `--frozen` used to exit 0 on that.
    #[test]
    fn a_fresh_verdict_still_fails_frozen_when_the_locked_tree_moved() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let dir = tmp.path().join(".mirroir").join("archetypes/custom");
        fs::create_dir_all(&dir)?;
        fs::write(dir.join("archetype.md"), "original\n")?;

        let mut lock = empty_lockfile();
        lock.archetypes.push(LockedArchetype {
            reference: "./archetypes/custom".to_owned(),
            resolved: ResolvedRecord {
                kind: LockedOrigin::ProjectLocal,
                pack: None,
                name: "./archetypes/custom".to_owned(),
                version: None,
                source: None,
                checksum: checksum_directory(&dir)?,
            },
        });

        // Truthful lockfile: every mode is satisfied.
        for mode in [
            LockfileMode::Default,
            LockfileMode::Locked,
            LockfileMode::Frozen,
        ] {
            enforce_freshness(
                &FreshnessVerdict::Fresh,
                mode,
                &lock,
                tmp.path(),
                Path::new("/nonexistent"),
            )?;
        }

        fs::write(dir.join("archetype.md"), "originaL\n")?;
        for mode in [LockfileMode::Locked, LockfileMode::Frozen] {
            match enforce_freshness(
                &FreshnessVerdict::Fresh,
                mode,
                &lock,
                tmp.path(),
                Path::new("/nonexistent"),
            ) {
                Err(RunnerError::Mirroir(MirroirError::LockfileStale { reason })) => {
                    assert!(
                        reason.contains("now hashes to"),
                        "the refusal does not name the checksum drift: {reason}"
                    );
                }
                other => return Err(format!("{mode:?} accepted an edited tree: {other:?}").into()),
            }
        }
        // Local dev warns and carries on rather than blocking iteration.
        enforce_freshness(
            &FreshnessVerdict::Fresh,
            LockfileMode::Default,
            &lock,
            tmp.path(),
            Path::new("/nonexistent"),
        )?;
        Ok(())
    }

    #[test]
    fn read_write_roundtrip_via_disk() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let path = tmp.path().join("mirroir.lock");
        let lock = empty_lockfile();
        write_lockfile(&path, &lock)?;
        let parsed = read_lockfile(&path)?;
        assert_eq!(parsed.version, lock.version);
        Ok(())
    }
}
