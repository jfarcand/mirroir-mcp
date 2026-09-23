// ABOUTME: The sandbox copy of samples/web-fixture/ the parity suite drives — the port rewrite and the fixture mutations.
// ABOUTME: One place to read what the cross-surface gate is pointed at, and what "reworded" means for it.

use std::fs;
use std::path::{Path, PathBuf};

use super::{Sandbox, repo_path};

/// The sample the suite copies, relative to the crate root.
pub const SAMPLE_SOURCE: &str = "samples/web-fixture";

/// Port the shipped sample hard-codes. Rewritten to a reserved one in the
/// sandbox copy so a busy 18902 cannot decide the suite's verdict.
const FIXTURE_PORT: &str = "18902";

/// The web half of the gate: written by every run, never an input to one.
pub const WEB_BASELINE: &str = "parity.web.txt";

/// The iOS half: committed, and the file `accept` must leave alone.
pub const IOS_BASELINE: &str = "parity.ios.txt";

/// The page the shipped scenario opens.
pub const PAGE: &str = "parity.html";

/// The page the drift phase repoints it at — same DOM, same attributes, other
/// words.
pub const REWORDED_PAGE: &str = "parity-reworded.html";

/// The `url:` fragment the reword rewrites. Slash-prefixed and
/// quote-terminated so the scenario's prose, which names both pages, is left
/// alone.
const URL_PAGE: &str = "/parity.html\"";

/// What [`URL_PAGE`] becomes.
const URL_REWORDED_PAGE: &str = "/parity-reworded.html\"";

/// Copy `samples/web-fixture/` into `<sandbox>/sample/`, rewriting the port,
/// and return the copy's directory.
///
/// A copy keeps the suite's mutations — the repointed `url:`, the baselines
/// `accept` rewrites — out of the repository, while the shipped files stay the
/// thing under test.
///
/// # Errors
///
/// Returns the failure text when the shipped sample cannot be read or the copy
/// cannot be written.
pub fn plant_sample(sandbox: &Sandbox, port: u16) -> Result<PathBuf, String> {
    copy_into(
        &PathBuf::from(repo_path(SAMPLE_SOURCE)),
        sandbox,
        Path::new("sample"),
        port,
    )?;
    Ok(sandbox.path().join("sample"))
}

fn copy_into(dir: &Path, sandbox: &Sandbox, relative: &Path, port: u16) -> Result<(), String> {
    let entries = fs::read_dir(dir).map_err(|e| format!("read {}: {e}", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("walk {}: {e}", dir.display()))?;
        let name = entry.file_name();
        let name = name
            .to_str()
            .ok_or("a file in the sample has a non-UTF-8 name")?;
        let child = relative.join(name);
        if entry
            .file_type()
            .map_err(|e| format!("stat {name}: {e}"))?
            .is_dir()
        {
            copy_into(&entry.path(), sandbox, &child, port)?;
            continue;
        }
        // The web half is the run's output, never its input. A copy left in the
        // repository by an earlier `--sample` run must not stand in for the
        // scrape the first phase exists to observe.
        if name == WEB_BASELINE {
            continue;
        }
        let body = fs::read_to_string(entry.path())
            .map_err(|e| format!("read {}: {e}", entry.path().display()))?;
        let target = child
            .to_str()
            .ok_or("a sandbox destination path is not valid UTF-8")?;
        sandbox.write(target, &body.replace(FIXTURE_PORT, &port.to_string()))?;
    }
    Ok(())
}

/// Repoint the copied scenario's `target.url` at the reworded page.
///
/// Every assertion the scenario makes still holds there — same heading, same
/// panel, same `data-test` attributes. Only the panel's words moved.
///
/// # Errors
///
/// Returns the failure text when the scenario no longer opens the baseline
/// page exactly once, which means the fixture moved and the suite's premise
/// with it.
pub fn reword_scenario(scenario: &Path) -> Result<(), String> {
    let body =
        fs::read_to_string(scenario).map_err(|e| format!("read {}: {e}", scenario.display()))?;
    let occurrences = body.matches(URL_PAGE).count();
    if occurrences != 1 {
        return Err(format!(
            "{} opens `{URL_PAGE}` {occurrences} times; expected exactly one",
            scenario.display()
        ));
    }
    fs::write(scenario, body.replace(URL_PAGE, URL_REWORDED_PAGE))
        .map_err(|e| format!("write {}: {e}", scenario.display()))
}

/// The iOS surface exactly as this repository ships it — the bytes `accept`
/// must not move.
///
/// # Errors
///
/// Returns the failure text when the shipped baseline cannot be read.
pub fn shipped_ios_baseline() -> Result<String, String> {
    let path = repo_path(&format!("{SAMPLE_SOURCE}/baselines/{IOS_BASELINE}"));
    fs::read_to_string(&path).map_err(|e| format!("read {path}: {e}"))
}

/// The lines `page`'s parity panel renders, in order, read out of the shipped
/// fixture page itself.
///
/// Keeps the pages load-bearing the way [`super::fixture_summary_text`] does
/// for the drift pair: reword a line and the suite's expectation moves with it.
///
/// # Errors
///
/// Returns the failure text when the page no longer renders a `<main>` panel of
/// `<p>` lines, which means the fixture moved.
pub fn panel_lines(page: &str) -> Result<Vec<String>, String> {
    let path = repo_path(&format!("{SAMPLE_SOURCE}/public/{page}"));
    let body = fs::read_to_string(&path).map_err(|e| format!("read {path}: {e}"))?;
    let start = body
        .find("<main")
        .ok_or_else(|| format!("{page} renders no <main> panel"))?;
    let end = start
        + body[start..]
            .find("</main>")
            .ok_or_else(|| format!("{page}: the panel is unterminated"))?;
    let mut lines = Vec::new();
    for chunk in body[start..end].split("<p>").skip(1) {
        let close = chunk
            .find("</p>")
            .ok_or_else(|| format!("{page}: a panel line is unterminated"))?;
        lines.push(chunk[..close].trim().to_owned());
    }
    if lines.is_empty() {
        return Err(format!("{page}: the panel renders no lines"));
    }
    Ok(lines)
}
