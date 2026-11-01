// ABOUTME: Tests for the mirroir-mcp iOS block driver against a stub mirroir-mcp script.
// ABOUTME: Included by ios.rs as its `tests` module; covers reports, budgets, failing steps, resolution, skills.

use std::env;
use std::error::Error as StdError;
use std::ffi::OsString;
use std::fs as std_fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::result::Result as StdResult;
use std::time::Duration;

use nix::errno::Errno;
use nix::sys::signal::kill;
use nix::unistd::Pid;
use tempfile::TempDir;
use tokio::time::sleep;

use super::{MIRROIR_SKILLS_ENV, MirroirMcpRunner};
use crate::compile::report_error::ReportError;
use crate::error::RunnerError;
use crate::ios_error::IosError;
use crate::replay_cross_surface::IOS_CAPTURE_KEY;

type TestResult = StdResult<(), Box<dyn StdError>>;

/// The report `mirroir-mcp test --report-json` writes for one passing skill
/// with a final-screen capture — the exact document `PlaywrightReportWriter`
/// produces on the Swift side.
const PASSING_REPORT: &str = include_str!("fixtures/mirroir-mcp-report.json");

/// A stand-in `mirroir-mcp` that records its arguments and writes `report`
/// (or nothing) to the `--report-json` path, then exits `status`.
fn stub(dir: &Path, report: Option<&str>, status: i32) -> StdResult<OsString, Box<dyn StdError>> {
    let bin = dir.join("mirroir-mcp");
    let write = match report {
        Some(body) => {
            let fixture = dir.join("report.fixture.json");
            std_fs::write(&fixture, body)?;
            format!("cp '{}' \"$3\"\n", fixture.display())
        }
        None => String::new(),
    };
    std_fs::write(
        &bin,
        format!(
            "#!/bin/sh\necho \"$@\" > '{}'\n{write}exit {status}\n",
            dir.join("args").display()
        ),
    )?;
    std_fs::set_permissions(&bin, std_fs::Permissions::from_mode(0o755))?;
    Ok(bin.into_os_string())
}

#[tokio::test]
async fn a_passing_block_returns_its_final_screen_capture() -> TestResult {
    let dir = TempDir::new()?;
    let runner = MirroirMcpRunner::resolve(
        Some(stub(dir.path(), Some(PASSING_REPORT), 0)?),
        &OsString::new(),
    )?;
    let outcome = runner
        .run(
            "version: 1\nname: \"flow\"\nsteps:\n",
            &[],
            &dir.path().join("ws"),
        )
        .await?;
    assert_eq!(outcome.verdict.passed, 1);
    assert_eq!(
        outcome
            .captures
            .cross_surface
            .get(IOS_CAPTURE_KEY)
            .map(String::as_str),
        Some("Alarmes Aucune alarme\n")
    );
    let args = std_fs::read_to_string(dir.path().join("args"))?;
    assert!(
        args.starts_with("test --report-json "),
        "unexpected argv: {args}"
    );
    assert!(
        args.contains(&format!("--capture {IOS_CAPTURE_KEY} ")),
        "no capture key: {args}"
    );
    Ok(())
}

/// Exiting without a report — a refused block, an unreachable device — is
/// an error naming the report it never wrote, never a pass.
#[tokio::test]
async fn exiting_without_a_report_is_an_error() -> TestResult {
    let dir = TempDir::new()?;
    let runner = MirroirMcpRunner::resolve(Some(stub(dir.path(), None, 1)?), &OsString::new())?;
    match runner
        .run("version: 1\n", &[], &dir.path().join("ws"))
        .await
    {
        Err(RunnerError::Ios(IosError::NoReport {
            status: Some(1), ..
        })) => Ok(()),
        other => Err(format!("expected NoReport, got {:?}", other.map(|_| ())).into()),
    }
}

/// A `mirroir-mcp test` that never returns — the hang carnet#24's capture
/// stall can turn into — is killed at its budget, the stderr it wrote so
/// far reaches the error, and neither it nor what it spawned survives.
#[tokio::test]
async fn a_block_that_never_returns_is_killed_at_its_budget() -> TestResult {
    let dir = TempDir::new()?;
    let bin = dir.path().join("mirroir-mcp");
    let pid = dir.path().join("pid");
    let grandchild = dir.path().join("grandchild");
    std_fs::write(
        &bin,
        format!(
            "#!/bin/sh\necho 'step 1 (launch: \"Clock\")' >&2\necho $$ > '{}'\nsleep 1000 &\necho $! > '{}'\nwait\n",
            pid.display(),
            grandchild.display()
        ),
    )?;
    std_fs::set_permissions(&bin, std_fs::Permissions::from_mode(0o755))?;
    // Long enough for the stub to start on a loaded host, so the stderr it
    // writes first is there to read when the kill lands.
    let allowance = Duration::from_secs(3);
    let runner = MirroirMcpRunner::resolve(Some(bin.into_os_string()), &OsString::new())?
        .with_step_allowance(allowance);
    match runner
        .run("version: 1\n", &[], &dir.path().join("ws"))
        .await
    {
        Err(RunnerError::Ios(IosError::BlockTimeout {
            elapsed,
            budget,
            steps: 0,
            stderr_tail,
        })) => {
            assert_eq!(budget, allowance);
            assert!(elapsed >= budget, "killed early: {elapsed:?}");
            assert!(
                stderr_tail.contains("step 1"),
                "stderr {stderr_tail:?} after {elapsed:?}"
            );
        }
        other => {
            return Err(format!("expected BlockTimeout, got {:?}", other.map(|_| ())).into());
        }
    }
    for file in [pid, grandchild] {
        let raw: i32 = std_fs::read_to_string(&file)?.trim().parse()?;
        assert!(
            gone(raw).await,
            "{} ({raw}) outlived the kill",
            file.display()
        );
    }
    Ok(())
}

/// Whether `pid` names no process within a few seconds — an orphan is
/// reaped by init, not by us, so it may linger as a zombie briefly.
async fn gone(pid: i32) -> bool {
    for _ in 0..50 {
        if kill(Pid::from_raw(pid), None) == Err(Errno::ESRCH) {
            return true;
        }
        sleep(Duration::from_millis(100)).await;
    }
    false
}

/// A failing step reaches the error through the shared ingest, named as
/// mirroir-mcp's failure.
#[tokio::test]
async fn a_failing_block_names_the_step() -> TestResult {
    let dir = TempDir::new()?;
    let failing = PASSING_REPORT
        .replace("\"status\" : \"passed\"", "\"status\" : \"failed\", \"error\" : { \"message\" : \"step 2 (tap: \\\"Alarmes\\\"): not found\" }");
    let runner =
        MirroirMcpRunner::resolve(Some(stub(dir.path(), Some(&failing), 1)?), &OsString::new())?;
    match runner
        .run("version: 1\n", &[], &dir.path().join("ws"))
        .await
    {
        Err(RunnerError::Report(error @ ReportError::TestFailures { .. })) => {
            let text = error.to_string();
            assert!(text.starts_with("mirroir-mcp: 1 of 1"), "{text}");
            assert!(
                text.contains("step 2 (tap: \"Alarmes\"): not found"),
                "{text}"
            );
            Ok(())
        }
        other => Err(format!("expected TestFailures, got {:?}", other.map(|_| ())).into()),
    }
}

/// A relative override is checked from the caller's directory but spawned
/// from the block's workspace; it has to be anchored before that move.
#[tokio::test]
async fn a_relative_override_still_runs_from_the_block_workspace() -> TestResult {
    let dir = TempDir::new()?;
    stub(dir.path(), Some(PASSING_REPORT), 0)?;
    let relative = pathdiff_from_cwd(&dir.path().join("mirroir-mcp"))?;
    let runner = MirroirMcpRunner::resolve(Some(relative), &OsString::new())?;
    let outcome = runner
        .run("version: 1\n", &[], &dir.path().join("ws"))
        .await?;
    assert_eq!(outcome.verdict.passed, 1);
    Ok(())
}

/// `target` spelled relative to the current directory: `../` up to the
/// root, then the absolute path — relative however deep the cwd sits.
fn pathdiff_from_cwd(target: &Path) -> StdResult<OsString, Box<dyn StdError>> {
    let cwd = env::current_dir()?;
    let ups = cwd.components().count().saturating_sub(1);
    let mut relative = PathBuf::new();
    for _ in 0..ups {
        relative.push("..");
    }
    relative.push(target.strip_prefix("/")?);
    Ok(relative.into_os_string())
}

/// The block runs from its scratch workspace, where mirroir-mcp's
/// working-directory-relative pattern paths reach nothing: the invocation's
/// skills checkout reaches the child as an absolute `MIRROIR_SKILLS`, even
/// when it was named relative to the caller's directory.
#[tokio::test]
async fn the_skills_checkout_reaches_the_block_as_an_absolute_path() -> TestResult {
    let dir = TempDir::new()?;
    let skills = dir.path().join("mirroir-skills");
    std_fs::create_dir_all(&skills)?;
    let fixture = dir.path().join("report.fixture.json");
    std_fs::write(&fixture, PASSING_REPORT)?;
    let bin = dir.path().join("mirroir-mcp");
    std_fs::write(
        &bin,
        format!(
            "#!/bin/sh\nprintf '%s' \"${MIRROIR_SKILLS_ENV}\" > '{}'\ncp '{}' \"$3\"\n",
            dir.path().join("skills-env").display(),
            fixture.display()
        ),
    )?;
    std_fs::set_permissions(&bin, std_fs::Permissions::from_mode(0o755))?;
    let relative = PathBuf::from(pathdiff_from_cwd(&skills)?);

    let runner = MirroirMcpRunner::resolve(Some(bin.into_os_string()), &OsString::new())?
        .with_skills(Some(&relative))?;
    let outcome = runner
        .run("version: 1\n", &[], &dir.path().join("ws"))
        .await?;

    assert_eq!(outcome.verdict.passed, 1);
    let handed = PathBuf::from(std_fs::read_to_string(dir.path().join("skills-env"))?);
    assert!(
        handed.is_absolute(),
        "a relative checkout reached the block: {}",
        handed.display()
    );
    assert_eq!(handed.canonicalize()?, skills.canonicalize()?);
    Ok(())
}

#[test]
fn an_override_naming_no_file_is_not_installed() -> TestResult {
    match MirroirMcpRunner::resolve(
        Some(OsString::from("/nonexistent/mirroir-mcp")),
        &OsString::new(),
    ) {
        Err(RunnerError::Ios(IosError::NotInstalled)) => Ok(()),
        Err(other) => Err(format!("wrong error: {other}").into()),
        Ok(_) => Err("a missing binary resolved".into()),
    }
}
