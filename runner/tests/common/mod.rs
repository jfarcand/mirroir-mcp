// ABOUTME: Shared helpers for mirroir-run's integration tests — hermetic invocations of the built binary.
// ABOUTME: No unwrap/expect anywhere: every fallible call maps into a String the test returns as its error.

// Each integration-test binary compiles this module separately, so a helper
// only one binary needs reads as dead code in the others.
#![allow(dead_code)]

use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

pub mod full_loop;
pub mod loop_tree;
pub mod oracle_stub;
pub mod parity_tree;

/// One `mirroir-run` invocation's outcome.
pub struct Run {
    /// Process exit code; `None` when the child was killed by a signal.
    pub code: Option<i32>,
    /// Captured stdout.
    pub stdout: String,
    /// Captured stderr — where `tracing` writes.
    pub stderr: String,
}

impl Run {
    /// True when the runner did not exit 0, i.e. it refused to call the run a pass.
    pub fn is_failure(&self) -> bool {
        self.code != Some(0)
    }

    /// Everything the invocation printed, for substring assertions.
    pub fn output(&self) -> String {
        format!("{}{}", self.stdout, self.stderr)
    }
}

/// A scratch directory for scenario files, plus a `bin/` that becomes the
/// child's `PATH` — empty unless a test plants a stub there.
pub struct Sandbox {
    dir: TempDir,
}

impl Sandbox {
    /// Create the scratch directory and its `bin/`.
    pub fn new() -> Result<Self, String> {
        let dir = TempDir::new().map_err(|e| format!("create tempdir: {e}"))?;
        fs::create_dir(dir.path().join("bin")).map_err(|e| format!("create bin dir: {e}"))?;
        Ok(Self { dir })
    }

    /// The sandbox root.
    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    /// Write `body` to `<sandbox>/<relative>`, creating parent directories,
    /// and return the absolute path.
    pub fn write(&self, relative: &str, body: &str) -> Result<String, String> {
        let path = self.dir.path().join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
        }
        fs::write(&path, body).map_err(|e| format!("write {relative}: {e}"))?;
        path.into_os_string()
            .into_string()
            .map_err(|_| format!("path for {relative} is not valid UTF-8"))
    }

    /// Write a scenario YAML into the sandbox and return its absolute path.
    pub fn scenario(&self, name: &str, body: &str) -> Result<String, String> {
        self.write(name, body)
    }

    /// Plant a stub `npx` on the sandbox's `PATH` that writes `report_json`
    /// where the runner expects Playwright's JSON reporter output, and exits 0.
    ///
    /// This is how a test drives the full invoke → report-ingest → post-hook
    /// path without Node, a browser download, or a network.
    pub fn stub_npx(&self, report_json: &str) -> Result<(), String> {
        let canned = self.write("canned-report.json", report_json)?;
        // The runner's PATH is the sandbox's own bin/, so the stub restores a
        // system PATH for itself before reaching for `cp`, and writes relative
        // to the workspace cwd Playwright would have been invoked in.
        let script = format!(
            "#!/bin/sh\nPATH=/bin:/usr/bin\nexport PATH\nexec cp '{canned}' ./playwright-report.json\n"
        );
        let npx = self.dir.path().join("bin").join("npx");
        fs::write(&npx, script).map_err(|e| format!("write stub npx: {e}"))?;
        make_executable(&npx)
    }

    /// Invoke the freshly built `mirroir-run` with `args`.
    ///
    /// `PATH` is set to the sandbox's `bin/`, so the runner resolves only what
    /// the test planted there. With nothing planted, a web block fails fast
    /// with `PlaywrightNotInstalled` instead of downloading a browser
    /// mid-test — which keeps these tests hermetic and identical on a laptop
    /// and on a CI lane that has no Node.
    pub fn run(&self, args: &[&str]) -> Result<Run, String> {
        self.run_with_env(args, &[])
    }

    /// Like [`Self::run_with_env`], with every CI marker `mirroir-run accept`
    /// refuses on cleared from the child's environment.
    ///
    /// `accept` is a human's signature and refuses to run in CI. These tests
    /// run *in* CI, so the markers the host runner exports are removed here.
    /// The list mirrors `CI_MARKERS` in `src/accept.rs`; a marker added there
    /// and not here surfaces as this suite failing on that CI, which is the
    /// loud failure, not a silent one.
    pub fn run_outside_ci(&self, args: &[&str], env: &[(&str, &str)]) -> Result<Run, String> {
        const CI_MARKERS: &[&str] = &[
            "CI",
            "CONTINUOUS_INTEGRATION",
            "BUILD_NUMBER",
            "GITHUB_ACTIONS",
            "GITLAB_CI",
            "BITBUCKET_BUILD_NUMBER",
            "BUILDKITE",
            "CIRCLECI",
            "TRAVIS",
            "TEAMCITY_VERSION",
            "JENKINS_URL",
            "TF_BUILD",
        ];
        // Markers are cleared first so an explicit `env` entry still wins — the
        // refusal test sets one on purpose.
        let mut command = self.command(args, &[]);
        for marker in CI_MARKERS {
            command.env_remove(marker);
        }
        for (key, value) in env {
            command.env(key, value);
        }
        Self::finish(command, args)
    }

    /// Like [`Self::run`], with additional environment variables.
    ///
    /// The child's working directory is the sandbox, so the `.harness/`
    /// review artifacts a run writes — `last-green.json`, `drift-log.md` —
    /// land here and never in the repository.
    pub fn run_with_env(&self, args: &[&str], env: &[(&str, &str)]) -> Result<Run, String> {
        Self::finish(self.command(args, env), args)
    }

    /// Build the child command shared by both invocation helpers.
    fn command(&self, args: &[&str], env: &[(&str, &str)]) -> Command {
        let mut command = Command::new(binary());
        command
            .args(args)
            .current_dir(self.dir.path())
            .env("PATH", self.dir.path().join("bin"))
            // A developer's real Playwright checkout must not leak in.
            .env_remove("MIRROIR_PLAYWRIGHT_HOME")
            // A drift-defaults.yaml from the developer's own environment must
            // not decide a test's verdict.
            .env_remove("MIRROIR_SKILLS");
        for (key, value) in env {
            command.env(key, value);
        }
        command
    }

    /// Run the prepared command and capture its outcome.
    fn finish(mut command: Command, args: &[&str]) -> Result<Run, String> {
        let output = command
            .output()
            .map_err(|e| format!("spawn mirroir-run {args:?}: {e}"))?;
        Ok(Run {
            code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }

    /// Read the `.spec.ts` an `--emit playwright` run wrote for `stem` under
    /// the sandbox's `target/playwright/` tree.
    pub fn emitted_spec(&self, stem: &str) -> Result<String, String> {
        let path = self
            .dir
            .path()
            .join("target/playwright")
            .join(stem)
            .join(format!("{stem}.spec.ts"));
        fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))
    }
}

/// Build a passing Playwright JSON report whose `mirroir-captures` attachment
/// files `response` as the judged text for step `judge_index`.
///
/// The Playwright JSON reporter base64-encodes attachment bodies, so the tests
/// build one the same way the real reporter would.
pub fn passing_report_with_judge(
    spec: &str,
    title: &str,
    judge_index: &str,
    response: &str,
) -> String {
    let captures = serde_json::json!({
        "metrics": {},
        "judge": { judge_index: response },
        "cross_surface": {},
    })
    .to_string();
    let body = base64_encode(captures.as_bytes());
    format!(
        r#"{{"suites":[{{"title":"{spec}","specs":[{{"title":"{title}","tests":[{{"projectName":"chromium","results":[{{"status":"passed","attachments":[{{"name":"mirroir-captures","contentType":"application/json","body":"{body}"}}]}}]}}]}}],"suites":[]}}]}}"#
    )
}

/// Minimal base64 encoder for the attachment bodies above.
pub fn base64_encode(raw: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(raw.len().div_ceil(3) * 4);
    for chunk in raw.chunks(3) {
        let b0 = u32::from(chunk[0]);
        let b1 = chunk.get(1).map_or(0, |b| u32::from(*b));
        let b2 = chunk.get(2).map_or(0, |b| u32::from(*b));
        let triple = (b0 << 16) | (b1 << 8) | b2;
        for index in 0..4 {
            if index <= chunk.len() {
                let shift = 18 - 6 * index;
                out.push(char::from(ALPHABET[((triple >> shift) & 0x3F) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(unix)]
fn make_executable(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;

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

/// Path to the `mirroir-run` binary Cargo built for this test run.
fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mirroir-run"))
}

/// Absolute path to a file shipped in this repository.
pub fn repo_path(relative: &str) -> String {
    format!("{}/{relative}", env!("CARGO_MANIFEST_DIR"))
}

/// The text `summary.html` / `summary-reworded.html` render into
/// `[data-test=order-summary]` after the order button is clicked.
///
/// Read out of the fixture page itself so the pages stay load-bearing: reword
/// one and the drift suite's inputs change with it.
pub fn fixture_summary_text(page: &str) -> Result<String, String> {
    let path = repo_path(&format!("samples/web-fixture/public/{page}"));
    let body = fs::read_to_string(&path).map_err(|e| format!("read {path}: {e}"))?;
    let marker = "textContent =";
    let start = body
        .find(marker)
        .ok_or_else(|| format!("{page} no longer assigns textContent"))?
        + marker.len();
    let rest = &body[start..];
    let open = rest
        .find('\'')
        .ok_or_else(|| format!("{page}: no quoted confirmation text"))?;
    let close = rest[open + 1..]
        .find('\'')
        .ok_or_else(|| format!("{page}: unterminated confirmation text"))?;
    Ok(rest[open + 1..open + 1 + close].to_owned())
}

/// Reserve a loopback port by binding and releasing it.
///
/// # Errors
///
/// Returns the failure text when loopback cannot be bound, or when the bound
/// listener will not report its own address.
pub fn free_port() -> Result<u16, String> {
    let listener =
        TcpListener::bind("127.0.0.1:0").map_err(|e| format!("reserve a fixture port: {e}"))?;
    listener
        .local_addr()
        .map(|addr| addr.port())
        .map_err(|e| format!("read the reserved port: {e}"))
}

/// Drop every ANSI escape sequence from `raw`.
///
/// The runner's `tracing` subscriber colorizes its output, which splices escape
/// codes between a field's name and its value — `id=fixture` reaches a pipe as
/// `\x1b[3mid\x1b[0m\x1b[2m=\x1b[0mfixture`. Assertions read the plain text, and
/// so does a human reading a failure dump.
#[must_use]
pub fn strip_ansi(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        // CSI sequences run until a byte in 0x40..=0x7E; anything else after
        // ESC is a two-character sequence whose second character we drop.
        if chars.next() == Some('[') {
            for terminator in chars.by_ref() {
                if ('\u{40}'..='\u{7e}').contains(&terminator) {
                    break;
                }
            }
        }
    }
    out
}
