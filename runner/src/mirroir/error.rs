// ABOUTME: Structured error type for the `.mirroir/` consumer pipeline — discovery, resolve, lock, compose.
// ABOUTME: Converts into RunnerError via #[from]; every variant carries the fields its message needs.

use std::io;
use std::path::PathBuf;

use thiserror::Error;

/// Errors raised while driving a consumer repository's `.mirroir/` plan.
///
/// The `.mirroir/` pipeline — config discovery, archetype resolution, lockfile
/// freshness, compose, plan aggregation — owns this enum so
/// [`crate::error::RunnerError`] stays the runner-wide surface. Every variant
/// converts into [`crate::error::RunnerError::Mirroir`] through `#[from]`, so
/// `?` propagates them unchanged.
#[derive(Debug, Error)]
pub enum MirroirError {
    /// An archetype reference in `mirroir.yaml` could not be parsed.
    ///
    /// Valid forms: `<pack>/<name>[@<version>]`, `./<path>`, `user/<name>[@<version>]`.
    /// Bare `<name>` refs are rejected to eliminate pack/user collision ambiguity.
    #[error("invalid archetype reference `{value}`: {reason}")]
    InvalidArchetypeRef {
        /// The reference string from `mirroir.yaml`.
        value: String,
        /// Human-readable explanation of why parsing failed.
        reason: String,
    },

    /// A plan entry declares more than one archetype. Cross-archetype
    /// composition is on the roadmap but not implemented in v1.
    #[error(
        "plan entry `{entry_name}` declares {count} archetypes; v1 supports exactly one (cross-archetype composition is planned)"
    )]
    CompositionUnsupported {
        /// `name` field of the offending plan entry.
        entry_name: String,
        /// Number of archetypes declared.
        count: usize,
    },

    /// A plan entry has both `archetypes:` and `local:` set, or neither.
    /// Exactly one is required.
    #[error("plan entry `{entry_name}`: {reason}")]
    PlanEntryAmbiguous {
        /// `name` field of the offending plan entry.
        entry_name: String,
        /// "both archetypes and local set" or "neither archetypes nor local set".
        reason: String,
    },

    /// `mirroir-run` walked from `searched_from` to the filesystem root and
    /// never found a `.mirroir/mirroir.yaml`. Run inside a consumer repo, or
    /// pass `--config <PATH>` explicitly.
    #[error("no `.mirroir/mirroir.yaml` found walking up from `{searched_from}`")]
    ConfigNotFound {
        /// Starting directory of the walk.
        searched_from: PathBuf,
    },

    /// An archetype reference could not be resolved to a directory on disk.
    #[error("archetype `{reference}` not found (searched: {searched:?})")]
    ArchetypeNotFound {
        /// The reference string from `mirroir.yaml`.
        reference: String,
        /// Directories the resolver inspected.
        searched: Vec<PathBuf>,
    },

    /// A plan entry referenced a local sample that doesn't exist on disk.
    #[error("plan entry `{sample}` declared `local: {expected_path}` but the path does not exist")]
    SampleMissing {
        /// Plan entry name.
        sample: String,
        /// The resolved path that was missing.
        expected_path: PathBuf,
    },

    /// At least one sample in a `mirroir-run` invocation reported failures.
    #[error("mirroir plan: {failed} of {total} plan entries failed")]
    PlanFailures {
        /// Number of plan entries whose sample failed.
        failed: usize,
        /// Total plan entries accounted for, replayed or skipped.
        total: usize,
    },

    /// The composed `.build/<sample>/` could not be built for the named sample.
    #[error("compose failed for sample `{sample}`: {context}")]
    ComposeFailed {
        /// Plan entry name being composed.
        sample: String,
        /// Human-readable description of the compose step that failed.
        context: String,
        /// Underlying I/O error from the compose subprocess (file write, etc.).
        #[source]
        source: io::Error,
    },

    /// The lockfile drifted from `mirroir.yaml` and the run mode is `--locked`.
    #[error("lockfile is stale relative to mirroir.yaml: {reason}")]
    LockfileStale {
        /// What drifted (ref added, ref removed, version changed, …).
        reason: String,
    },

    /// `--frozen` mode requires the lockfile to be present and not require
    /// network fetch; one of those conditions was violated.
    #[error("frozen mode violation: {reason}")]
    FrozenViolation {
        /// What violated the frozen invariant.
        reason: String,
    },

    /// `mirroir.lock` was expected but is missing. Run `mirroir-run` without
    /// `--locked` to regenerate, or commit a lockfile.
    #[error("mirroir.lock not found at `{path}` (required by --locked)")]
    LockfileMissing {
        /// Where the lockfile was expected.
        path: PathBuf,
    },

    /// The scenario set in effect selected none of the plan's entries, while
    /// other tiers do hold entries. The plan declares work; the invocation
    /// filtered all of it out, so there is nothing to replay and nothing to
    /// call a pass.
    #[error(
        "scenario set `{selected}` selected 0 of the plan's {total} entries; entries are declared under: {populated}. Name a set that covers them — `default_set:` in mirroir.yaml, or `--scenarios` on the command line"
    )]
    SelectionMatchedNothing {
        /// The set that was in effect: `must_pass`, `nice_to_pass`, or `all`.
        selected: String,
        /// Plan entries declared across every tier.
        total: usize,
        /// Comma-separated tiers that do hold entries.
        populated: String,
    },

    /// `mirroir.yaml` declares no plan entries in any tier. Unlike
    /// [`Self::SelectionMatchedNothing`] no scenario set can rescue this run —
    /// the config itself declares no work.
    #[error("`{config}` declares no plan entries; a run with nothing to replay is not a pass")]
    PlanEmpty {
        /// The `mirroir.yaml` that was loaded.
        config: PathBuf,
    },

    /// Every plan entry the scenario set selected is marked `skip: true`, so
    /// the run replayed no sample. The selection itself was valid — which is
    /// why [`Self::SelectionMatchedNothing`] did not fire — but a run that
    /// replayed nothing is not a pass.
    #[error(
        "none of the plan's {total} entries was replayed: every entry the scenario set selected is marked `skip: true`; a run that replayed nothing is not a pass. Remove `skip:` from an entry, or select a set that holds one without it"
    )]
    NothingReplayed {
        /// Plan entries accounted for, every one of them skipped.
        total: usize,
    },

    /// `HOME` environment variable is not set; can't locate `~/.mirroir/`.
    #[error("cannot resolve user home directory ($HOME is unset)")]
    HomeDirUnavailable,
}
