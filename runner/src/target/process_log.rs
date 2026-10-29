// ABOUTME: Subprocess plumbing for the process and ios targets — stream pumping and draining, group signalling, regex flags.
// ABOUTME: Pure helpers behind spawn (stdout/stderr capture), kill (SIGTERM/SIGKILL), the ios block's kill, and assert_log (regex).

use std::io;
use std::path::PathBuf;

use regex::{Regex, RegexBuilder};
use tokio::fs;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStderr, ChildStdout};
use tokio::task::JoinHandle;
use tracing::{debug, warn};

#[cfg(unix)]
use nix::sys::signal::{Signal, kill};
#[cfg(unix)]
use nix::unistd::Pid;

use crate::error::{Result, RunnerError};

/// Send `signal` to the child's entire process group (negative pid). The child
/// leads its own group (spawned with `process_group(0)`), so forked
/// grandchildren — e.g. the `sleep` a `sh -c 'sleep 30'` forks — are signalled
/// too, instead of being orphaned with the stdout/stderr pipe still open.
/// Errors (already-gone group, etc.) are logged, not propagated.
#[cfg(unix)]
fn signal_group(id: &str, child: &Child, signal: Signal) {
    let Some(pid) = child.id() else {
        warn!(id = %id, "child has no pid; skipping {signal:?}");
        return;
    };
    let pid_i32 = i32::try_from(pid).unwrap_or(i32::MAX);
    // Negative pid targets the process group whose id == the child's pid.
    if let Err(err) = kill(Pid::from_raw(-pid_i32), signal) {
        warn!(id = %id, error = %err, "{signal:?} to process group failed");
    } else {
        debug!(id = %id, "sent {signal:?} to process group");
    }
}

/// Send `SIGTERM` to the child's process group. No-op on non-unix platforms.
#[cfg(unix)]
pub fn send_group_sigterm(id: &str, child: &Child) {
    signal_group(id, child, Signal::SIGTERM);
}

/// Send `SIGKILL` to the child's process group. No-op on non-unix platforms.
#[cfg(unix)]
pub fn send_group_sigkill(id: &str, child: &Child) {
    signal_group(id, child, Signal::SIGKILL);
}

/// Send `SIGTERM` to the child's process group. No-op on non-unix platforms.
#[cfg(not(unix))]
pub fn send_group_sigterm(_id: &str, _child: &Child) {
    // Non-unix platforms have no process groups; kill_on_drop handles teardown.
}

/// Send `SIGKILL` to the child's process group. No-op on non-unix platforms.
#[cfg(not(unix))]
pub fn send_group_sigkill(_id: &str, _child: &Child) {
    // Non-unix platforms have no process groups; kill_on_drop handles teardown.
}

/// Pump stdout + stderr from a running [`Child`] into a single log file.
///
/// # Errors
///
/// Propagates any I/O error from opening, reading, or writing the log file.
pub async fn pump_streams(
    stdout: ChildStdout,
    stderr: ChildStderr,
    log_path: PathBuf,
) -> io::Result<()> {
    let out_path = log_path.clone();
    let out = tokio::spawn(pump_one(stdout, out_path));
    let err_path = log_path;
    let err = tokio::spawn(pump_one_err(stderr, err_path));
    let out_res = out.await.map_err(io::Error::other)?;
    let err_res = err.await.map_err(io::Error::other)?;
    out_res?;
    err_res
}

async fn pump_one(stream: ChildStdout, log_path: PathBuf) -> io::Result<()> {
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .await?;
    let mut reader = BufReader::new(stream);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', &mut buf).await?;
        if n == 0 {
            break;
        }
        file.write_all(&buf).await?;
        file.flush().await?;
    }
    Ok(())
}

async fn pump_one_err(stream: ChildStderr, log_path: PathBuf) -> io::Result<()> {
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .await?;
    let mut reader = BufReader::new(stream);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', &mut buf).await?;
        if n == 0 {
            break;
        }
        file.write_all(&buf).await?;
        file.flush().await?;
    }
    Ok(())
}

/// Build a `regex::Regex` from a pattern + optional POSIX-style flag string.
///
/// Supported flags: `i` case-insensitive, `m` multi-line, `s` dot-matches-newline,
/// `x` ignore-whitespace, `U` swap-greed. Anything else returns
/// [`RunnerError::RegexFlags`].
///
/// # Errors
///
/// * [`RunnerError::RegexFlags`] on an unsupported flag character.
/// * [`RunnerError::RegexCompile`] when the pattern is invalid.
pub fn build_regex(pattern: &str, flags: Option<&str>) -> Result<Regex> {
    let mut builder = RegexBuilder::new(pattern);
    if let Some(flag_str) = flags {
        for c in flag_str.chars() {
            match c {
                'i' => {
                    builder.case_insensitive(true);
                }
                'm' => {
                    builder.multi_line(true);
                }
                's' => {
                    builder.dot_matches_new_line(true);
                }
                'x' => {
                    builder.ignore_whitespace(true);
                }
                'U' => {
                    builder.swap_greed(true);
                }
                other => {
                    return Err(RunnerError::RegexFlags {
                        flags: flag_str.to_owned(),
                        reason: format!("unsupported flag `{other}`"),
                    });
                }
            }
        }
    }
    builder.build().map_err(|source| RunnerError::RegexCompile {
        pattern: pattern.to_owned(),
        source,
    })
}

/// Read `stream` to its end on a task of its own, so a child that writes more
/// than a pipe holds never blocks waiting for a reader.
pub fn drain<R>(stream: Option<R>) -> JoinHandle<Vec<u8>>
where
    R: AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut buf = Vec::new();
        if let Some(mut stream) = stream
            && let Err(error) = stream.read_to_end(&mut buf).await
        {
            warn!(%error, "reading subprocess output failed");
        }
        buf
    })
}

/// What a [`drain`] task read; empty, with a warning, if the task failed.
pub async fn joined(task: JoinHandle<Vec<u8>>) -> Vec<u8> {
    match task.await {
        Ok(buf) => buf,
        Err(error) => {
            warn!(%error, "subprocess output reader did not join");
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::error::Error as StdError;
    use std::result::Result as StdResult;
    use std::time::Duration;

    use tokio::time::sleep;

    use crate::error::RunnerError;
    use crate::parser::step::{AssertLogArgs, AssertLogCleanArgs, KillArgs, SpawnArgs};
    use crate::parser::step_process_args::LogPattern;
    use crate::target::process::ProcessRegistry;

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
    async fn spawn_writes_command_stdout_to_log() -> TestResult {
        let mut reg = ProcessRegistry::default();
        reg.spawn(&spawn_args("echo-once", "/bin/sh -c 'echo hello-mirroir'"))?;
        // Let the pump drain.
        sleep(Duration::from_millis(200)).await;
        reg.assert_log(&AssertLogArgs {
            id: "echo-once".to_owned(),
            pattern: "hello-mirroir".to_owned(),
            flags: None,
            timeout_s: Some(2),
        })
        .await?;
        reg.kill_process(&KillArgs {
            id: "echo-once".to_owned(),
            grace_s: 1,
            cleanup: None,
        })
        .await?;
        Ok(())
    }

    #[tokio::test]
    async fn assert_log_clean_passes_when_allow_exempts_deny() -> TestResult {
        let mut reg = ProcessRegistry::default();
        reg.spawn(&spawn_args(
            "rate-limited",
            "/bin/sh -c 'echo \"Disabled retry on ERROR.RATE_LIMIT\"; echo ok'",
        ))?;
        sleep(Duration::from_millis(200)).await;
        reg.assert_log_clean(&AssertLogCleanArgs {
            id: "rate-limited".to_owned(),
            deny: vec![LogPattern {
                pattern: r"\bERROR\b".to_owned(),
                flags: None,
            }],
            allow: vec![LogPattern {
                pattern: "Disabled retry on ERROR\\.RATE_LIMIT".to_owned(),
                flags: None,
            }],
        })
        .await?;
        reg.kill_process(&KillArgs {
            id: "rate-limited".to_owned(),
            grace_s: 1,
            cleanup: None,
        })
        .await?;
        Ok(())
    }

    #[tokio::test]
    async fn assert_log_clean_fails_on_bare_error() -> TestResult {
        let mut reg = ProcessRegistry::default();
        reg.spawn(&spawn_args(
            "noisy",
            "/bin/sh -c 'echo \"ERROR something exploded\"'",
        ))?;
        sleep(Duration::from_millis(200)).await;
        let res = reg
            .assert_log_clean(&AssertLogCleanArgs {
                id: "noisy".to_owned(),
                deny: vec![LogPattern {
                    pattern: r"\bERROR\b".to_owned(),
                    flags: None,
                }],
                allow: vec![],
            })
            .await;
        if !matches!(res, Err(RunnerError::LogAssertion { .. })) {
            return Err(format!("expected LogAssertion, got {res:?}").into());
        }
        reg.kill_process(&KillArgs {
            id: "noisy".to_owned(),
            grace_s: 1,
            cleanup: None,
        })
        .await?;
        Ok(())
    }

    #[tokio::test]
    async fn assert_log_after_kill_sees_full_captured_output() -> TestResult {
        // Regression for the `--run-scenario` smoke path: spawn → kill → assert_log
        // with no explicit sleep, mirroring how scenario YAML is authored.
        let mut reg = ProcessRegistry::default();
        reg.spawn(&spawn_args(
            "fast-echo",
            "/bin/sh -c 'echo hello-from-mirroir-run'",
        ))?;
        reg.kill_process(&KillArgs {
            id: "fast-echo".to_owned(),
            grace_s: 2,
            cleanup: None,
        })
        .await?;
        reg.assert_log(&AssertLogArgs {
            id: "fast-echo".to_owned(),
            pattern: "hello-from-mirroir-run".to_owned(),
            flags: None,
            timeout_s: Some(2),
        })
        .await?;
        Ok(())
    }
}
