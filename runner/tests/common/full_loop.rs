// ABOUTME: Scaffolding for the end-to-end full-loop suite — the browser gate, the adopter-shaped .mirroir/ tree, the fixture mutations.
// ABOUTME: Keeps tests/e2e_full_loop.rs to the phases it asserts; no unwrap/expect anywhere, every failure is a String.

use std::env;
use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use super::loop_tree::{plant_archetype, plant_plan};
use super::oracle_stub::stub_oracle;
use super::{Run, Sandbox, free_port, repo_path, strip_ansi};

/// SHA-256 of the runner's built-in judge prompt template, the value every
/// `judge:` step pins. Kept in step with `oracle::judge::user_prompt_template_hash`
/// by `samples/web-fixture/scenarios/order-summary.yaml`, which declares the same
/// literal; a change to the template fails both.
pub const JUDGE_PROMPT_HASH: &str =
    "sha256:2fd94adeba57835b2267269c672245aeb82c450908f866bd4c887da010602834";

/// Score the stub oracle returns for every judged response, comfortably above
/// the scenario's `pass_threshold`. Constant across runs so `judge_score_swing`
/// never moves and the drift the suite provokes is the one it rewords.
const STUB_JUDGE_SCORE: &str = "0.95";

/// How long to wait for the stub oracle to hand back the request the runner
/// sent it. The judge call completes before the runner exits, so this only
/// covers the channel handoff.
const ORACLE_HANDOFF: Duration = Duration::from_secs(5);

/// The confirmation `summary.html` renders before the order button is clicked.
pub const UNCLICKED_SUMMARY: &str = "Nothing ordered yet.";

/// The event name the break phase rebinds the order button to — no such event
/// ever fires, so the click leaves the page in its unclicked state while every
/// element, attribute and locator stays exactly where it was.
pub const DEAD_EVENT: &str = "mirroir-no-such-event";

/// Everything the host must already have for the loop's browser leg to run.
pub struct Toolchain {
    /// Absolute path to the `npx` the counting shim execs.
    pub npx: PathBuf,
    /// `MIRROIR_PLAYWRIGHT_HOME` — the directory whose `node_modules/` the
    /// runner symlinks into each Playwright workspace.
    pub playwright_home: PathBuf,
    /// Absolute path to the chromium binary Playwright resolved.
    pub chromium: PathBuf,
    /// `PLAYWRIGHT_BROWSERS_PATH` — the registry the browser binaries live in.
    ///
    /// The suite hands the runner a sandboxed `$HOME` so the trusted oracle
    /// overlay is the one it plants, and Playwright's default registry hangs
    /// off `$HOME`. Naming the registry explicitly is what keeps the sandbox
    /// from hiding the browser this host installed.
    pub browsers_path: PathBuf,
}

/// Whether this host provisioned a browser for the loop.
pub enum BrowserGate {
    /// Node, Playwright and chromium are all present; run the loop.
    Ready(Toolchain),
    /// No browser was provisioned here. Carries the reason, which the caller
    /// must report — a silent no-op is worse than no test.
    NotProvisioned(String),
}

/// Resolve the host's browser toolchain.
///
/// `MIRROIR_PLAYWRIGHT_HOME` is the signal the repository already uses for
/// "this lane provisioned Playwright" — `runner-smoke`, `runner-e2e` and
/// `runner-e2e-allbrowsers` each set it and then `npm install @playwright/test`
/// + `npx playwright install chromium` into it.
///
/// Unset means the lane deliberately has no browser (`runner-fast`), which is
/// reported, not failed. Set but incomplete is a broken provisioning step and
/// fails loudly.
///
/// # Errors
///
/// Returns the reason when `MIRROIR_PLAYWRIGHT_HOME` names a directory without
/// `@playwright/test`, when `npx` / `node` are not on `PATH`, or when chromium
/// itself was never downloaded.
pub fn browser_gate() -> Result<BrowserGate, String> {
    let Some(raw) = env::var_os("MIRROIR_PLAYWRIGHT_HOME") else {
        return Ok(BrowserGate::NotProvisioned(
            "MIRROIR_PLAYWRIGHT_HOME is unset, so this host provisioned no browser".to_owned(),
        ));
    };
    let playwright_home = PathBuf::from(raw);
    let module = playwright_home.join("node_modules").join("@playwright");
    if !module.is_dir() {
        return Err(format!(
            "MIRROIR_PLAYWRIGHT_HOME={} has no node_modules/@playwright: \
             run `npm install @playwright/test` there",
            playwright_home.display()
        ));
    }
    let npx = which("npx").ok_or_else(|| {
        format!(
            "MIRROIR_PLAYWRIGHT_HOME={} is provisioned but no `npx` is on PATH",
            playwright_home.display()
        )
    })?;
    let node = which("node").ok_or_else(|| "no `node` on PATH".to_owned())?;
    let chromium = chromium_path(&node, &playwright_home)?;
    let browsers_path = browsers_root(&chromium).ok_or_else(|| {
        format!(
            "cannot locate the Playwright browser registry above {}",
            chromium.display()
        )
    })?;
    Ok(BrowserGate::Ready(Toolchain {
        npx,
        playwright_home,
        chromium,
        browsers_path,
    }))
}

/// The registry directory holding every installed browser, derived from the
/// chromium binary Playwright reported.
///
/// An explicit `PLAYWRIGHT_BROWSERS_PATH` in this process's environment wins;
/// otherwise the registry is the parent of the `chromium-<revision>/` directory
/// the executable sits under.
fn browsers_root(chromium: &Path) -> Option<PathBuf> {
    if let Some(explicit) = env::var_os("PLAYWRIGHT_BROWSERS_PATH") {
        return Some(PathBuf::from(explicit));
    }
    let mut current = chromium;
    while let Some(parent) = current.parent() {
        let named_for_chromium = parent
            .file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with("chromium"));
        if named_for_chromium {
            return parent.parent().map(Path::to_path_buf);
        }
        current = parent;
    }
    None
}

/// Ask Playwright itself where chromium lives, and insist the file is there.
fn chromium_path(node: &Path, playwright_home: &Path) -> Result<PathBuf, String> {
    let output = Command::new(node)
        .arg("-e")
        .arg("process.stdout.write(require('@playwright/test').chromium.executablePath())")
        .current_dir(playwright_home)
        .output()
        .map_err(|e| format!("ask playwright for its chromium path: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "playwright could not report a chromium path: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).into_owned());
    if !path.exists() {
        return Err(format!(
            "chromium is not installed at {} — run `npx playwright install chromium` \
             under MIRROIR_PLAYWRIGHT_HOME={}",
            path.display(),
            playwright_home.display()
        ));
    }
    Ok(path)
}

/// First executable named `name` on the inherited `PATH`.
fn which(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

/// Write `message` straight to the process's stderr, past libtest's capture.
///
/// `println!` / `eprintln!` inside a test are captured and replayed only when
/// that test fails, so a notice printed with them is invisible on a green run —
/// which is exactly the silent no-op this suite must never become. A write to
/// the file descriptor is not captured.
pub fn announce(message: &str) {
    let mut err = io::stderr();
    let _ = writeln!(err, "{message}");
    let _ = err.flush();
}

/// A consumer repository with a `.mirroir/` plan, a served copy of the web
/// fixture, and a counting shim in front of `npx`.
pub struct LoopFixture<'a> {
    sandbox: &'a Sandbox,
    toolchain: Toolchain,
    /// Absolute path of the plan the runner is pointed at.
    pub config: String,
    /// Port the fixture's static server binds.
    pub port: u16,
    /// The served copy of `summary.html`, the page every phase mutates.
    pub summary_page: PathBuf,
    /// `$HOME` for the child, holding the trusted oracle overlay.
    home: String,
    /// `PATH` for the child: the shim's `bin/`, then the inherited entries.
    path: String,
}

/// One invocation of the loop.
pub struct LoopOutcome {
    /// Exit code; `None` when the child was killed by a signal.
    pub code: Option<i32>,
    /// Everything the invocation printed.
    pub output: String,
    /// The chat-completions request the runner sent the judge, when it got
    /// that far. `None` for a run that failed before the oracle post-hook.
    pub judge_request: Option<String>,
    /// How many times `npx` was invoked during this run.
    pub npx_invocations: usize,
}

impl<'a> LoopFixture<'a> {
    /// Plant the whole consumer repository in `sandbox`.
    ///
    /// # Errors
    ///
    /// Returns the failure text when a port cannot be reserved or any file in
    /// the tree cannot be written.
    pub fn plant(sandbox: &'a Sandbox, toolchain: Toolchain) -> Result<Self, String> {
        let port = free_port()?;
        copy_fixture_site(sandbox)?;
        sandbox.write(
            "drift-defaults.yaml",
            &fs::read_to_string(repo_path("drift-defaults.yaml"))
                .map_err(|e| format!("read the shipped drift-defaults.yaml: {e}"))?,
        )?;
        plant_archetype(sandbox, port)?;
        let config = plant_plan(sandbox, port)?;
        // The child's `$HOME` is a sandbox subdirectory rather than the
        // sandbox root: `resolve_home_root` reads `$HOME/.mirroir/`, and
        // pointing it at the project's own `.mirroir/` would blur the trusted
        // machine config with the repository config the plan lives in. Every
        // invocation writes the trusted oracle overlay into it, which is what
        // creates it.
        let home = sandbox.path().join("home").display().to_string();
        let path = shim_path(sandbox, &toolchain.npx)?;
        Ok(Self {
            sandbox,
            toolchain,
            config,
            port,
            summary_page: sandbox.path().join("site").join("summary.html"),
            home,
            path,
        })
    }

    /// Run the plan the way an adopter does, with `extra` appended to the
    /// invocation.
    ///
    /// # Errors
    ///
    /// Returns the failure text when the oracle stub cannot bind or the binary
    /// cannot be spawned.
    pub fn run(&self, extra: &[&str]) -> Result<LoopOutcome, String> {
        let mut args = vec!["--config", self.config.as_str()];
        args.extend_from_slice(extra);
        self.invoke(&args, false)
    }

    /// `mirroir-run accept` against the same plan, with the CI markers cleared
    /// the way a human's shell has them cleared.
    ///
    /// # Errors
    ///
    /// As [`Self::run`].
    pub fn accept(&self) -> Result<LoopOutcome, String> {
        self.invoke(&["accept", "--config", self.config.as_str()], true)
    }

    fn invoke(&self, args: &[&str], outside_ci: bool) -> Result<LoopOutcome, String> {
        let oracle = stub_oracle(STUB_JUDGE_SCORE)?;
        self.sandbox.write(
            "home/.mirroir/oracles/profiles.yaml",
            &format!(
                concat!(
                    "profiles:\n",
                    "  - name: byte-stable\n",
                    "    base_url: \"http://127.0.0.1:{port}/v1/chat/completions\"\n",
                    "    model: stub\n",
                    "    timeout_s: 30\n"
                ),
                port = oracle.port
            ),
        )?;
        let before = self.npx_invocations()?;
        let playwright_home = self.toolchain.playwright_home.display().to_string();
        let browsers_path = self.toolchain.browsers_path.display().to_string();
        let env: [(&str, &str); 4] = [
            ("HOME", self.home.as_str()),
            ("PATH", self.path.as_str()),
            ("MIRROIR_PLAYWRIGHT_HOME", playwright_home.as_str()),
            ("PLAYWRIGHT_BROWSERS_PATH", browsers_path.as_str()),
        ];
        let run: Run = if outside_ci {
            self.sandbox.run_outside_ci(args, &env)?
        } else {
            self.sandbox.run_with_env(args, &env)?
        };
        let judge_request = oracle.request.recv_timeout(ORACLE_HANDOFF).ok();
        Ok(LoopOutcome {
            code: run.code,
            output: strip_ansi(&run.output()),
            judge_request,
            npx_invocations: self.npx_invocations()? - before,
        })
    }

    /// How many `npx` invocations the shim has recorded so far.
    fn npx_invocations(&self) -> Result<usize, String> {
        let log = self.sandbox.path().join("npx-invocations.log");
        match fs::read_to_string(&log) {
            Ok(body) => Ok(body.lines().count()),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(0),
            Err(err) => Err(format!("read {}: {err}", log.display())),
        }
    }

    /// Absolute path inside the sandbox.
    #[must_use]
    pub fn at(&self, relative: &str) -> PathBuf {
        self.sandbox.path().join(relative)
    }

    /// Where the chromium Playwright will drive lives — reported by the suite
    /// so a run names the browser it actually used.
    #[must_use]
    pub fn chromium(&self) -> &Path {
        &self.toolchain.chromium
    }
}

/// Copy every page of `samples/web-fixture/public/` into `<sandbox>/site/`.
///
/// The suite rewords and breaks pages as it goes; a copy keeps those mutations
/// out of the repository while the baseline stays the shipped fixture.
fn copy_fixture_site(sandbox: &Sandbox) -> Result<(), String> {
    let source = PathBuf::from(repo_path("samples/web-fixture/public"));
    let entries = fs::read_dir(&source).map_err(|e| format!("read {}: {e}", source.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("walk {}: {e}", source.display()))?;
        if !entry
            .file_type()
            .map_err(|e| format!("stat: {e}"))?
            .is_file()
        {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_str().ok_or("a fixture page has a non-UTF-8 name")?;
        let body = fs::read_to_string(entry.path())
            .map_err(|e| format!("read {}: {e}", entry.path().display()))?;
        sandbox.write(&format!("site/{name}"), &body)?;
    }
    Ok(())
}

/// Plant the counting shim in front of `npx` and return the child's `PATH`.
///
/// The shim appends one line per invocation and then `exec`s the real `npx`,
/// so the run is genuine and the count is a fact rather than an inference —
/// which is how "one contiguous web block compiles to ONE invocation" gets
/// asserted instead of assumed.
fn shim_path(sandbox: &Sandbox, npx: &Path) -> Result<String, String> {
    let log = sandbox
        .path()
        .join("npx-invocations.log")
        .display()
        .to_string();
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{log}'\nexec '{}' \"$@\"\n",
        npx.display()
    );
    let bin = sandbox.path().join("bin");
    let shim = bin.join("npx");
    fs::write(&shim, script).map_err(|e| format!("write the npx shim: {e}"))?;
    make_executable(&shim)?;
    let inherited = env::var_os("PATH").unwrap_or_default();
    let mut dirs = vec![bin];
    dirs.extend(env::split_paths(&inherited));
    env::join_paths(dirs)
        .map_err(|e| format!("build the child PATH: {e}"))?
        .into_string()
        .map_err(|_| "the child PATH is not valid UTF-8".to_owned())
}

#[cfg(unix)]
fn make_executable(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt as _;

    let mut perms = fs::metadata(path)
        .map_err(|e| format!("stat {}: {e}", path.display()))?
        .permissions();
    perms.set_mode(0o755);
    fs::set_permissions(path, perms).map_err(|e| format!("chmod {}: {e}", path.display()))
}

#[cfg(not(unix))]
fn make_executable(_path: &Path) -> Result<(), String> {
    Ok(())
}
