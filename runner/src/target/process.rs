/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Process target — implements spawn/kill/wait_port/assert_log{,_clean} step variants.
// ABOUTME: Uses tokio::process::Command + nix SIGTERM, captures stdout/stderr to a temp log file.

use std::collections::HashMap;
use std::fs as stdfs;
use std::io;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use tempfile::TempDir;
use tokio::fs;
use tokio::process::{Child, Command};
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep, timeout};
use tracing::{debug, info, warn};

use crate::error::{Result, RunnerError};
use crate::parser::step::{AssertLogArgs, AssertLogCleanArgs, KillArgs, SpawnArgs, WaitPortArgs};
use crate::target::process_log::{
    build_regex, pump_streams, send_group_sigkill, send_group_sigterm,
};
use crate::target::process_port::wait_for_port;

/// Default poll deadline for `assert_log:` when the YAML omits `timeout_s`.
const ASSERT_LOG_DEFAULT_TIMEOUT_S: u32 = 5;

/// Runtime state for one subprocess that was started by a `spawn:` step.
struct ProcessHandle {
    child: Option<Child>,
    log_path: PathBuf,
    /// Owned tempdir — dropped (and unlinked) when the handle is dropped.
    _log_dir: TempDir,
    log_pump: Option<JoinHandle<io::Result<()>>>,
}

/// In-memory registry of subprocesses managed by the runner.
///
/// Step dispatchers call [`Self::spawn`] / [`Self::kill_process`] /
/// [`Self::wait_port`] / [`Self::assert_log`] / [`Self::assert_log_clean`]
/// in scenario order. A registry instance is scoped to a single scenario
/// run: when it drops, `kill_on_drop(true)` on the underlying [`Child`]
/// ensures no subprocess leaks past the run.
#[derive(Default)]
pub struct ProcessRegistry {
    processes: HashMap<String, ProcessHandle>,
}

impl ProcessRegistry {
    /// Implements the `spawn:` step. Parses `args.command` with shell-words
    /// (no shell layer, signals reach the real child), captures stdout +
    /// stderr to a temp log file, and registers the resulting handle.
    ///
    /// `args.from` (i.e. `from: SAMPLE.md`) is reserved for the SAMPLE.md
    /// integration commit; without an inline `command:`, this method returns
    /// [`RunnerError::SpawnMissingSource`] rather than silently no-op'ing.
    ///
    /// # Errors
    ///
    /// * [`RunnerError::DuplicateProcessId`] when the id is already live.
    /// * [`RunnerError::SpawnMissingSource`] when neither `command` nor `from` is provided.
    /// * [`RunnerError::ProcessSpawn`] on shell-words parse failure or `Command::spawn` failure.
    /// * [`RunnerError::Io`] when the temp log directory cannot be created.
    pub fn spawn(&mut self, args: &SpawnArgs) -> Result<()> {
        if self.processes.contains_key(&args.id) {
            return Err(RunnerError::DuplicateProcessId {
                id: args.id.clone(),
            });
        }
        self.spawn_internal(args)
    }

    /// Idempotent variant of [`Self::spawn`] used in `boot_once: true` sample
    /// runs: when the id is already live, returns `Ok(())` and logs instead of
    /// erroring. Useful when scenarios declare `spawn: { from: SAMPLE.md }`
    /// for portability with per-scenario runs but the sample driver already
    /// owns the shared subprocess.
    ///
    /// # Errors
    ///
    /// Same as [`Self::spawn`] except [`RunnerError::DuplicateProcessId`] is
    /// never returned.
    pub fn ensure_spawned(&mut self, args: &SpawnArgs) -> Result<()> {
        if self.processes.contains_key(&args.id) {
            info!(id = %args.id, "ensure_spawned: id already live; skipping re-spawn");
            return Ok(());
        }
        self.spawn_internal(args)
    }

    fn spawn_internal(&mut self, args: &SpawnArgs) -> Result<()> {
        let Some(command_line) = args.command.as_deref() else {
            return Err(RunnerError::SpawnMissingSource {
                id: args.id.clone(),
            });
        };

        let parts = shell_words::split(command_line).map_err(|err| RunnerError::ProcessSpawn {
            id: args.id.clone(),
            command: command_line.to_owned(),
            source: io::Error::new(io::ErrorKind::InvalidInput, err.to_string()),
        })?;
        let Some((program, prog_args)) = parts.split_first() else {
            return Err(RunnerError::ProcessSpawn {
                id: args.id.clone(),
                command: command_line.to_owned(),
                source: io::Error::new(io::ErrorKind::InvalidInput, "empty command"),
            });
        };

        let log_dir = TempDir::new().map_err(|source| RunnerError::Io {
            context: format!("create tempdir for spawn `{}`", args.id),
            source,
        })?;
        let log_path = log_dir.path().join(format!("{}.log", args.id));
        // Pre-create the log file synchronously so subsequent `assert_log:`
        // steps never race against the async pump task creating it.
        stdfs::File::create(&log_path).map_err(|source| RunnerError::Io {
            context: format!("pre-create log file for spawn `{}`", args.id),
            source,
        })?;

        let mut cmd = Command::new(program);
        cmd.args(prog_args);
        if let Some(cwd) = &args.cwd {
            cmd.current_dir(cwd);
        }
        for (k, v) in &args.env {
            cmd.env(k, v);
        }
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());
        cmd.kill_on_drop(true);
        // Put the child in its own process group (pgid == child pid) so kill can
        // signal the whole tree — a `sh -c '<cmd>'` forks `<cmd>`, and killing
        // only the shell would orphan it (and leave the stdout/stderr pipe open,
        // hanging the log-pump join). Group teardown also stops real boot trees
        // (server + forked workers) leaking across samples.
        #[cfg(unix)]
        cmd.process_group(0);

        let mut child = cmd.spawn().map_err(|source| RunnerError::ProcessSpawn {
            id: args.id.clone(),
            command: command_line.to_owned(),
            source,
        })?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| RunnerError::ProcessControl {
                id: args.id.clone(),
                context: "captured stdout missing".to_owned(),
                source: io::Error::other("Stdio::piped did not yield a handle"),
            })?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| RunnerError::ProcessControl {
                id: args.id.clone(),
                context: "captured stderr missing".to_owned(),
                source: io::Error::other("Stdio::piped did not yield a handle"),
            })?;

        let pump_path = log_path.clone();
        let log_pump = tokio::spawn(pump_streams(stdout, stderr, pump_path));

        info!(
            id = %args.id,
            command = %command_line,
            log = %log_path.display(),
            "spawned subprocess"
        );

        self.processes.insert(
            args.id.clone(),
            ProcessHandle {
                child: Some(child),
                log_path,
                _log_dir: log_dir,
                log_pump: Some(log_pump),
            },
        );
        Ok(())
    }

    /// Implements the `kill:` step. Sends SIGTERM (unix), waits `grace_s`
    /// seconds for graceful exit, then SIGKILLs and waits again. The log
    /// pump task is awaited so subsequent [`Self::assert_log`] calls see
    /// the final output.
    ///
    /// The handle stays in the registry with `child = None` afterwards, so
    /// post-mortem `assert_log:` steps can still read the captured log.
    /// Re-spawning the same id is rejected via [`RunnerError::DuplicateProcessId`].
    ///
    /// # Errors
    ///
    /// * [`RunnerError::UnknownProcess`] when no spawn matches the id.
    /// * [`RunnerError::ProcessControl`] when SIGKILL fails.
    pub async fn kill_process(&mut self, args: &KillArgs) -> Result<()> {
        let handle =
            self.processes
                .get_mut(&args.id)
                .ok_or_else(|| RunnerError::UnknownProcess {
                    id: args.id.clone(),
                })?;
        let Some(mut child) = handle.child.take() else {
            // Already torn down by a prior `kill:` step — treat as idempotent.
            info!(id = %args.id, "kill: child already terminated; skipping");
            return Ok(());
        };

        // Graceful-shutdown semantics: wait up to `grace_s` for *natural*
        // exit first, then SIGTERM, then SIGKILL. Sending SIGTERM as the
        // first move races fast subprocesses that haven't yet flushed their
        // stdout — `/bin/sh -c 'echo X'` typically loses output if SIGTERMed
        // before exec'ing `echo`.
        let grace = Duration::from_secs(u64::from(args.grace_s));
        let natural = matches!(timeout(grace, child.wait()).await, Ok(Ok(_)));

        let graceful = if natural {
            true
        } else {
            // Signal the whole process GROUP, not just the direct child: a
            // `sh -c '<cmd>'` forks `<cmd>` as a child, and that grandchild
            // inherits the stdout/stderr pipe. Killing only the shell orphans
            // the grandchild, which keeps the pipe open and blocks the log-pump
            // join below until the grandchild exits on its own. Group signalling
            // also stops real boot trees (server + workers) leaking across
            // samples.
            send_group_sigterm(&args.id, &child);
            let sigterm_grace = Duration::from_secs(u64::from(args.grace_s));
            let exited_via_sigterm =
                matches!(timeout(sigterm_grace, child.wait()).await, Ok(Ok(_)));
            if !exited_via_sigterm {
                debug!(id = %args.id, "SIGTERM grace expired, sending SIGKILL");
                send_group_sigkill(&args.id, &child);
                let _ = child.wait().await;
            }
            exited_via_sigterm
        };

        if let Some(pump) = handle.log_pump.take()
            && let Err(join_err) = pump.await
        {
            warn!(id = %args.id, error = %join_err, "log pump task did not join cleanly");
        }

        info!(id = %args.id, graceful, "subprocess terminated");
        Ok(())
    }

    /// Implements the `wait_port:` step. Polls both the IPv4 (`127.0.0.1`) and
    /// IPv6 (`[::1]`) loopback addresses for `<port>` at 100ms intervals up to
    /// `args.timeout_s`. Checking both matters because dev servers differ in
    /// which loopback they bind — Vite, for example, binds `[::1]` only when
    /// told to listen on `localhost`, so an IPv4-only probe would never see it.
    /// `expect: open` passes once either address connects; `expect: closed`
    /// passes once both refuse.
    ///
    /// # Errors
    ///
    /// [`RunnerError::WaitPortTimeout`] when the expected state is not
    /// observed before the deadline.
    pub async fn wait_port(&self, args: &WaitPortArgs) -> Result<()> {
        wait_for_port(args).await
    }

    /// Implements the `assert_log:` step.
    ///
    /// Polls the captured log every ~100ms until the pattern matches or
    /// `args.timeout_s` (defaulting to 5 s) elapses. This mirrors
    /// Playwright's "expect-with-retry" model so authors don't have to
    /// manually sync `assert_log` with a `kill:` step.
    ///
    /// # Errors
    ///
    /// * [`RunnerError::UnknownProcess`] when the id is not registered.
    /// * [`RunnerError::Io`] when the log file cannot be read.
    /// * [`RunnerError::RegexFlags`] on unsupported flag characters.
    /// * [`RunnerError::RegexCompile`] when the pattern is invalid.
    /// * [`RunnerError::LogAssertion`] when no line matches before the deadline.
    pub async fn assert_log(&self, args: &AssertLogArgs) -> Result<()> {
        let re = build_regex(&args.pattern, args.flags.as_deref())?;
        let timeout_s = args.timeout_s.unwrap_or(ASSERT_LOG_DEFAULT_TIMEOUT_S);
        let deadline = Instant::now() + Duration::from_secs(u64::from(timeout_s));
        loop {
            let body = self.read_log(&args.id).await?;
            if re.is_match(&body) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(RunnerError::LogAssertion {
                    id: args.id.clone(),
                    reason: format!(
                        "pattern `{}` did not match any captured line within {}s",
                        args.pattern, timeout_s
                    ),
                });
            }
            sleep(Duration::from_millis(100)).await;
        }
    }

    /// Implements the `assert_log_clean:` step. Reads the captured log and
    /// fails when any `deny` pattern matches a line that no `allow` pattern
    /// also matches.
    ///
    /// # Errors
    ///
    /// Mirrors [`Self::assert_log`] plus the deny/allow regex compilation paths.
    pub async fn assert_log_clean(&self, args: &AssertLogCleanArgs) -> Result<()> {
        let body = self.read_log(&args.id).await?;
        let deny_regexes = args
            .deny
            .iter()
            .map(|p| build_regex(&p.pattern, p.flags.as_deref()))
            .collect::<Result<Vec<_>>>()?;
        let allow_regexes = args
            .allow
            .iter()
            .map(|p| build_regex(&p.pattern, p.flags.as_deref()))
            .collect::<Result<Vec<_>>>()?;

        for (idx, line) in body.lines().enumerate() {
            let denied = deny_regexes.iter().any(|re| re.is_match(line));
            if !denied {
                continue;
            }
            let allowed = allow_regexes.iter().any(|re| re.is_match(line));
            if !allowed {
                return Err(RunnerError::LogAssertion {
                    id: args.id.clone(),
                    reason: format!("deny matched line {} (no allow exempt): {line}", idx + 1),
                });
            }
        }
        Ok(())
    }

    async fn read_log(&self, id: &str) -> Result<String> {
        let handle = self
            .processes
            .get(id)
            .ok_or_else(|| RunnerError::UnknownProcess { id: id.to_owned() })?;
        let body = fs::read_to_string(&handle.log_path)
            .await
            .map_err(|source| RunnerError::Io {
                context: format!("read log for `{id}`"),
                source,
            })?;
        debug!(
            id = %id,
            path = %handle.log_path.display(),
            bytes = body.len(),
            "read captured log"
        );
        Ok(body)
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn spawn_args(id: &str, command: &str) -> SpawnArgs {
        SpawnArgs {
            id: id.to_owned(),
            from: None,
            command: Some(command.to_owned()),
            cwd: None,
            env: HashMap::new(),
            timeout_s: None,
            expect_exit: None,
            capture_stdout: None,
        }
    }

    #[tokio::test]
    async fn kill_terminates_long_running_subprocess() -> TestResult {
        let mut reg = ProcessRegistry::default();
        reg.spawn(&spawn_args("sleeper", "/bin/sh -c 'sleep 30'"))?;
        let start = Instant::now();
        reg.kill_process(&KillArgs {
            id: "sleeper".to_owned(),
            grace_s: 1,
            cleanup: None,
        })
        .await?;
        let elapsed = start.elapsed();
        if elapsed >= Duration::from_secs(5) {
            return Err(format!("kill took {elapsed:?} — should be sub-second").into());
        }
        Ok(())
    }

    #[tokio::test]
    async fn duplicate_id_rejected() -> TestResult {
        let mut reg = ProcessRegistry::default();
        reg.spawn(&spawn_args("dup", "/bin/sh -c 'sleep 5'"))?;
        let again = reg.spawn(&spawn_args("dup", "/bin/sh -c 'sleep 5'"));
        let Err(RunnerError::DuplicateProcessId { id }) = again else {
            return Err("expected DuplicateProcessId".into());
        };
        if id != "dup" {
            return Err(format!("wrong id `{id}`").into());
        }
        reg.kill_process(&KillArgs {
            id: "dup".to_owned(),
            grace_s: 1,
            cleanup: None,
        })
        .await?;
        Ok(())
    }

    #[tokio::test]
    async fn unknown_kill_id_errors() -> TestResult {
        let mut reg = ProcessRegistry::default();
        let res = reg
            .kill_process(&KillArgs {
                id: "ghost".to_owned(),
                grace_s: 1,
                cleanup: None,
            })
            .await;
        let Err(RunnerError::UnknownProcess { id }) = res else {
            return Err("expected UnknownProcess".into());
        };
        if id != "ghost" {
            return Err(format!("wrong id `{id}`").into());
        }
        Ok(())
    }

    #[tokio::test]
    async fn missing_command_returns_spawn_missing_source() -> TestResult {
        let mut reg = ProcessRegistry::default();
        let args = SpawnArgs {
            id: "from-only".to_owned(),
            from: Some("SAMPLE.md".to_owned()),
            command: None,
            cwd: None,
            env: HashMap::new(),
            timeout_s: None,
            expect_exit: None,
            capture_stdout: None,
        };
        let res = reg.spawn(&args);
        if !matches!(res, Err(RunnerError::SpawnMissingSource { .. })) {
            return Err(format!("expected SpawnMissingSource, got {res:?}").into());
        }
        Ok(())
    }
}
