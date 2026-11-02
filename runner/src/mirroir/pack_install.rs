// ABOUTME: `mirroir-run pack install` — fetch an archetype pack and land it at ~/.mirroir/skills/<pack>/<version>/.
// ABOUTME: Clones into a staging dir, validates INDEX.md and every listed archetype, then renames into place.

use std::fs;
use std::path::{self, Component, Path, PathBuf};

use clap::{Args, Subcommand};
use tempfile::Builder;
use tracing::info;

use crate::error::{Result, RunnerError};
use crate::mirroir::error::MirroirError;
use crate::mirroir::git::{checkout_head, run_git};
use crate::mirroir::resolve::{
    ARCHETYPE_MANIFEST_FILE, PACK_ARCHETYPES_DIR, pack_directory, pack_version_directory,
    skills_root,
};
use crate::mirroir::resolve_version::parse_exact_version;
use crate::mirroir::run_io::resolve_home_root;
use crate::parser::archetype::parse_archetype_manifest;
use crate::parser::pack_index::{PACK_INDEX_FILE, PackIndex, parse_pack_index};
use crate::verdict::RunVerdict;

/// Prefix of the staging directory a fetch lands in before it is validated.
/// It sits inside `~/.mirroir/skills/` so the final move is a same-filesystem
/// rename; a failed install leaves nothing behind but this, which is removed.
const STAGING_PREFIX: &str = ".pack-install-";

/// `mirroir-run pack …` — manage the archetype packs installed on this machine.
#[derive(Args, Debug)]
pub struct PackArgs {
    /// The pack operation.
    #[command(subcommand)]
    pub command: PackCommand,
}

/// Pack operations.
#[derive(Subcommand, Debug)]
pub enum PackCommand {
    /// Fetch a pack and install it at `~/.mirroir/skills/<pack>/<pack_version>/`,
    /// where `<pack>/<archetype>@<version>` references in `mirroir.yaml` resolve.
    Install(PackInstallArgs),
}

/// Arguments of `mirroir-run pack install`.
#[derive(Args, Debug)]
pub struct PackInstallArgs {
    /// Git URL or local path of the pack repository.
    pub source: String,

    /// Branch or tag to install. Defaults to the repository's default branch.
    #[arg(long = "ref")]
    pub git_ref: Option<String>,
}

/// What an install did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledPack {
    /// The pack's `INDEX.md`.
    pub index: PackIndex,
    /// The installed pack-version directory.
    pub directory: PathBuf,
    /// The commit installed there.
    pub commit: String,
    /// Whether this call wrote the directory; `false` when the same commit
    /// was already installed.
    pub fresh: bool,
}

/// Dispatch a `pack` subcommand against `$HOME`.
///
/// # Errors
///
/// Anything [`install_pack`] returns, and
/// [`MirroirError::HomeDirUnavailable`] when `$HOME` is unset.
pub fn run_pack(args: &PackArgs) -> Result<RunVerdict> {
    match &args.command {
        PackCommand::Install(install) => {
            let home_root = resolve_home_root()?;
            let installed = install_pack(&install.source, install.git_ref.as_deref(), &home_root)?;
            info!(
                pack = %installed.index.name,
                version = %installed.index.pack_version,
                commit = %installed.commit,
                archetypes = ?installed.index.archetypes,
                directory = %installed.directory.display(),
                "{}",
                if installed.fresh { "pack installed" } else { "pack already installed at this commit" }
            );
            Ok(RunVerdict::Pass)
        }
    }
}

/// Fetch `source` at `git_ref` and install it under `home_root`.
///
/// The checkout lands in a staging directory first and moves into place only
/// after its `INDEX.md` and every archetype it lists parse — a pack that would
/// fail at resolve time is refused at install time instead. Installing the
/// commit that is already there is a no-op; installing a different commit
/// over an installed version is refused, because lockfiles pin what a version
/// holds.
///
/// # Errors
///
/// * [`RunnerError::Io`] when the fetch fails or the filesystem refuses a step.
/// * [`MirroirError::PackInvalid`] when the checkout is not an installable pack.
/// * [`MirroirError::PackVersionConflict`] when the version is installed from
///   another commit.
pub fn install_pack(
    source: &str,
    git_ref: Option<&str>,
    home_root: &Path,
) -> Result<InstalledPack> {
    let root = skills_root(home_root);
    fs::create_dir_all(&root).map_err(|source| RunnerError::Io {
        context: format!("create {}", root.display()),
        source,
    })?;
    let staging = Builder::new()
        .prefix(STAGING_PREFIX)
        .tempdir_in(&root)
        .map_err(|source| RunnerError::Io {
            context: format!("create a staging directory in {}", root.display()),
            source,
        })?;
    let checkout = staging.path().join("checkout");
    let checkout_arg = checkout.to_string_lossy();
    let mut clone = vec!["clone", "--quiet", "--depth=1"];
    if let Some(reference) = git_ref {
        clone.extend(["--branch", reference]);
    }
    // git runs inside the staging directory, so a relative local path is
    // anchored to the caller's directory before it moves there.
    let local = Path::new(source);
    let fetched = if local.exists() {
        path::absolute(local)
            .map_err(|source| RunnerError::Io {
                context: format!("resolve {}", local.display()),
                source,
            })?
            .to_string_lossy()
            .into_owned()
    } else {
        source.to_owned()
    };
    clone.extend(["--", &fetched, &checkout_arg]);
    run_git(staging.path(), &clone)?;
    let commit = run_git(&checkout, &["rev-parse", "HEAD"])?;
    let index = validate_checkout(source, &checkout)?;

    let directory = pack_version_directory(home_root, &index.name, &index.pack_version);
    if directory.exists() {
        let installed = checkout_head(&directory)
            .unwrap_or_else(|| "a directory that is no git checkout".to_owned());
        if installed == commit {
            return Ok(InstalledPack {
                index,
                directory,
                commit,
                fresh: false,
            });
        }
        return Err(MirroirError::PackVersionConflict {
            directory,
            installed,
            incoming: commit,
        }
        .into());
    }
    let parent = pack_directory(home_root, &index.name);
    fs::create_dir_all(&parent).map_err(|source| RunnerError::Io {
        context: format!("create {}", parent.display()),
        source,
    })?;
    fs::rename(&checkout, &directory).map_err(|source| RunnerError::Io {
        context: format!("move {} to {}", checkout.display(), directory.display()),
        source,
    })?;
    Ok(InstalledPack {
        index,
        directory,
        commit,
        fresh: true,
    })
}

/// Parse the checkout's `INDEX.md` and check that it can be installed: a
/// name and version that are single directory names, and every listed
/// archetype present with an `archetype.md` that names it.
fn validate_checkout(source: &str, checkout: &Path) -> Result<PackIndex> {
    let invalid = |reason: String| -> RunnerError {
        MirroirError::PackInvalid {
            source_ref: source.to_owned(),
            reason,
        }
        .into()
    };
    let index_path = checkout.join(PACK_INDEX_FILE);
    let raw = fs::read_to_string(&index_path).map_err(|error| {
        invalid(format!(
            "no readable {PACK_INDEX_FILE} at its root ({error})"
        ))
    })?;
    let index = parse_pack_index(&index_path.display().to_string(), &raw)?;

    if !is_single_name(&index.name) {
        return Err(invalid(format!(
            "pack name `{}` is not a single directory name",
            index.name
        )));
    }
    if index.pack_version.starts_with('v') || parse_exact_version(&index.pack_version).is_none() {
        return Err(invalid(format!(
            "pack_version `{}` is not an exact MAJOR.MINOR.PATCH version",
            index.pack_version
        )));
    }
    if index.archetypes.is_empty() {
        return Err(invalid(format!("{PACK_INDEX_FILE} lists no archetypes")));
    }
    for name in &index.archetypes {
        if !Path::new(name)
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
        {
            return Err(invalid(format!(
                "archetype `{name}` is not a relative path"
            )));
        }
        let manifest_path = checkout
            .join(PACK_ARCHETYPES_DIR)
            .join(name)
            .join(ARCHETYPE_MANIFEST_FILE);
        let manifest_raw = fs::read_to_string(&manifest_path).map_err(|error| {
            invalid(format!(
                "listed archetype `{name}` has no readable {ARCHETYPE_MANIFEST_FILE} ({error})"
            ))
        })?;
        let manifest =
            parse_archetype_manifest(&manifest_path.display().to_string(), &manifest_raw)?;
        if manifest.name != *name {
            return Err(invalid(format!(
                "archetype directory `{name}` declares itself as `{}`",
                manifest.name
            )));
        }
    }
    Ok(index)
}

/// Whether `name` is one plain directory name: no separator, no `.`/`..`,
/// not hidden.
fn is_single_name(name: &str) -> bool {
    let mut components = Path::new(name).components();
    matches!(components.next(), Some(Component::Normal(_)))
        && components.next().is_none()
        && !name.starts_with('.')
}

#[cfg(test)]
#[path = "pack_install_tests.rs"]
mod tests;
