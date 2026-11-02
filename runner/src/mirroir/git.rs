// ABOUTME: The git invocations the `.mirroir/` pipeline makes — clone, HEAD lookup, and checkout provenance.
// ABOUTME: Shared by lockfile generation (provenance) and `pack install` (fetch + commit identity).

use std::io;
use std::path::Path;
use std::process::Command;

use crate::error::{Result, RunnerError};
use crate::parser::lockfile::GitSource;

/// The entry that marks a directory as the root of a git checkout.
const GIT_DIR: &str = ".git";

/// The `HEAD` commit of the checkout rooted at `dir`, or `None` when `dir`
/// is not itself a checkout root.
///
/// A directory nested inside some other repository — a hand-copied pack under
/// a `$HOME` kept in git — answers `git rev-parse` with that repository's
/// commit, so the root is checked before git is asked.
#[must_use]
pub fn checkout_head(dir: &Path) -> Option<String> {
    if !dir.join(GIT_DIR).exists() {
        return None;
    }
    run_git(dir, &["rev-parse", "HEAD"]).ok()
}

/// The provenance of the git checkout rooted at `dir`: its `origin` URL, its
/// `HEAD` commit, and the tag `HEAD` sits exactly on, when there is one.
///
/// # Errors
///
/// [`RunnerError::Io`] when `dir` is not a checkout root or has no `origin`.
pub fn gather_git_source(dir: &Path) -> Result<GitSource> {
    if !dir.join(GIT_DIR).exists() {
        return Err(RunnerError::Io {
            context: format!("{} is not a git checkout root", dir.display()),
            source: io::Error::from(io::ErrorKind::NotFound),
        });
    }
    let url = run_git(dir, &["remote", "get-url", "origin"])?;
    let commit = run_git(dir, &["rev-parse", "HEAD"])?;
    let tag = run_git(dir, &["describe", "--tags", "--exact-match", "HEAD"]).ok();
    Ok(GitSource { url, tag, commit })
}

/// Run `git <args>` in `dir` and return its trimmed standard output.
///
/// # Errors
///
/// [`RunnerError::Io`] when git cannot be spawned or exits non-zero; the
/// context carries the arguments, the exit code, and git's stderr.
pub fn run_git(dir: &Path, args: &[&str]) -> Result<String> {
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
