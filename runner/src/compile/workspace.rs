// ABOUTME: Resolves and materializes a scenario's Playwright workspace on disk.
// ABOUTME: target/playwright/<sample>/<scenario>/ — the same path `--emit` writes and a run executes.

use std::env;
use std::io;
use std::path::{Path, PathBuf};

use tokio::fs;
use tracing::debug;

use crate::compile::error::PlaywrightError;
use crate::compile::playwright_config::{JSON_REPORT_FILE, emit_playwright_config};
use crate::error::Result;
use crate::parser::step::Browser;

/// Name of the emitted Playwright config, in a run workspace and in `--emit`
/// output alike.
pub const CONFIG_FILE: &str = "playwright.config.ts";

/// Directory, relative to the invocation cwd, that every compiled Playwright
/// artifact is written under.
pub const PLAYWRIGHT_OUTPUT_ROOT: &str = "target/playwright";

/// Root, under the invocation directory, of every `ios` block's workspace.
const IOS_OUTPUT_ROOT: &str = "target/mirroir-ios";

/// Characters kept verbatim in a directory component. Everything else — path
/// separators, spaces, the em dashes scenario names carry — collapses to `-`.
fn is_safe(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')
}

/// Reduce `name` to a single filesystem-safe path component.
///
/// Runs of unsafe characters collapse to one `-`, and leading / trailing `-`
/// are trimmed, so `web — order summary` becomes `web-order-summary`.
#[must_use]
pub fn slug(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for c in name.chars() {
        if is_safe(c) {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        "scenario".to_owned()
    } else {
        trimmed.to_owned()
    }
}

/// Where one scenario's compiled Playwright artifacts are written: the spec,
/// the config, the JSON + HTML reports, and the trace / video / screenshot
/// Playwright keeps for a failing test.
///
/// `--emit` writes this directory and a run executes it, so the preview a
/// human reads is the code that runs — not a separate rendering of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaywrightWorkspace {
    /// Absolute directory holding every artifact for this scenario.
    pub dir: PathBuf,
    /// Name of the `.spec.ts` file inside [`Self::dir`].
    pub spec_file: String,
}

impl PlaywrightWorkspace {
    /// Resolve the workspace for `scenario` under `cwd`.
    ///
    /// A scenario that belongs to a sample nests under the sample's own
    /// directory, so two samples may each carry a `login.yaml` without
    /// colliding.
    #[must_use]
    pub fn for_scenario(cwd: &Path, sample: Option<&str>, scenario: &str) -> Self {
        let mut dir = cwd.join(PLAYWRIGHT_OUTPUT_ROOT);
        if let Some(sample) = sample {
            dir.push(slug(sample));
        }
        dir.push(slug(scenario));
        Self {
            dir,
            spec_file: format!("{}.spec.ts", slug(scenario)),
        }
    }

    /// Where an `ios` block's file and report go for the same scenario:
    /// beside the Playwright tree, never inside it — the web workspace is
    /// recreated empty on every run and would take the iOS artifacts with it.
    #[must_use]
    pub fn ios_block_dir(cwd: &Path, sample: Option<&str>, scenario: &str) -> PathBuf {
        let mut dir = cwd.join(IOS_OUTPUT_ROOT);
        if let Some(sample) = sample {
            dir.push(slug(sample));
        }
        dir.push(slug(scenario));
        dir
    }

    /// Full path to the compiled spec.
    #[must_use]
    pub fn spec_path(&self) -> PathBuf {
        self.dir.join(&self.spec_file)
    }

    /// Full path to the emitted Playwright config.
    #[must_use]
    pub fn config_path(&self) -> PathBuf {
        self.dir.join(CONFIG_FILE)
    }

    /// Full path to the JSON report Playwright writes.
    #[must_use]
    pub fn report_path(&self) -> PathBuf {
        self.dir.join(JSON_REPORT_FILE)
    }

    /// Recreate the directory empty and write `spec_ts` + the config for
    /// `browsers` into it.
    ///
    /// Clearing first is what keeps a run's artifacts honest: a stale
    /// `trace.zip` from the previous run of the same scenario would otherwise
    /// sit next to a fresh report and read as this run's evidence.
    ///
    /// # Errors
    ///
    /// * [`PlaywrightError::Workspace`] when the directory or a file can't be
    ///   written.
    /// * [`crate::error::RunnerError::Format`] from the config emitter.
    pub async fn materialize(&self, spec_ts: &str, browsers: &[Browser]) -> Result<()> {
        self.clear().await?;
        fs::create_dir_all(&self.dir)
            .await
            .map_err(|source| PlaywrightError::Workspace {
                context: format!("create {}", self.dir.display()),
                source,
            })?;
        write_file(&self.config_path(), &emit_playwright_config(browsers)?).await?;
        write_file(&self.spec_path(), spec_ts).await?;
        link_playwright_home(&self.dir).await
    }

    async fn clear(&self) -> Result<()> {
        match fs::remove_dir_all(&self.dir).await {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(source) => Err(PlaywrightError::Workspace {
                context: format!("clear {}", self.dir.display()),
                source,
            }
            .into()),
        }
    }
}

async fn write_file(path: &Path, body: &str) -> Result<()> {
    fs::write(path, body)
        .await
        .map_err(|source| PlaywrightError::Workspace {
            context: format!("write {}", path.display()),
            source,
        })
        .map_err(Into::into)
}

/// If `MIRROIR_PLAYWRIGHT_HOME` points at a directory containing
/// `node_modules/@playwright/test`, symlink that `node_modules/` into the
/// workspace so the emitted `playwright.config.ts` can resolve its imports.
///
/// Silently no-ops when the env var is unset or the target dir is missing —
/// in those cases the runner relies on `npx` to find Playwright via its own
/// cache (works only when @playwright/test is installed globally).
async fn link_playwright_home(workspace_root: &Path) -> Result<()> {
    let Some(home) = env::var_os("MIRROIR_PLAYWRIGHT_HOME") else {
        return Ok(());
    };
    let src = PathBuf::from(home).join("node_modules");
    if !src.is_dir() {
        debug!(src = %src.display(), "MIRROIR_PLAYWRIGHT_HOME has no node_modules; skipping link");
        return Ok(());
    }
    let dst = workspace_root.join("node_modules");
    #[cfg(unix)]
    {
        fs::symlink(&src, &dst)
            .await
            .map_err(|source| PlaywrightError::Workspace {
                context: format!("symlink {} → {}", src.display(), dst.display()),
                source,
            })?;
        debug!(src = %src.display(), dst = %dst.display(), "linked playwright home");
    }
    #[cfg(not(unix))]
    {
        // Non-unix platforms aren't a target right now; left as a no-op.
        let _ = (src, dst);
    }
    Ok(())
}

/// The identifying stem of a scenario or sample path — its file name without
/// the extension. Falls back to `scenario` for a path that has none.
#[must_use]
pub fn path_stem(path: &Path) -> String {
    path.file_stem().map_or_else(
        || "scenario".to_owned(),
        |s| s.to_string_lossy().into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{PlaywrightWorkspace, path_stem, slug};

    #[test]
    fn slug_collapses_everything_a_directory_cannot_hold() {
        assert_eq!(slug("login"), "login");
        assert_eq!(slug("web-fixture — sign in"), "web-fixture-sign-in");
        assert_eq!(slug("a/b\\c"), "a-b-c");
        assert_eq!(slug("///"), "scenario");
    }

    #[test]
    fn a_sample_scenario_nests_under_its_sample() {
        let nested =
            PlaywrightWorkspace::for_scenario(Path::new("/w"), Some("web-fixture"), "login");
        assert_eq!(
            nested.dir,
            Path::new("/w/target/playwright/web-fixture/login")
        );
        assert_eq!(
            nested.spec_path(),
            Path::new("/w/target/playwright/web-fixture/login/login.spec.ts")
        );
        let standalone = PlaywrightWorkspace::for_scenario(Path::new("/w"), None, "login");
        assert_eq!(standalone.dir, Path::new("/w/target/playwright/login"));
    }

    #[test]
    fn stem_names_follow_the_scenario_file() {
        assert_eq!(path_stem(Path::new("scenarios/login.yaml")), "login");
        assert_eq!(path_stem(Path::new("samples/web-fixture")), "web-fixture");
    }
}
