// ABOUTME: `cross_surface:` step validation and dispatch — write each surface's capture, then compare pairwise.
// ABOUTME: Accept mode rewrites every captured file and reports the compared files no capture produces.

use std::collections::HashSet;
use std::fs;
use std::path::Path;

use tracing::{info, warn};

use crate::compile::report::RunCaptures;
use crate::cross_surface_error::CrossSurfaceError;
use crate::error::{Result, RunnerError};
use crate::oracle::baseline::BaselineMode;
use crate::oracle::drift::{Fingerprint, jaccard_similarity};
use crate::parser::step::CrossSurfaceArgs;
use crate::parser::step_args::{CaptureSurface, CrossSurfaceCapture};

/// Key an iOS block files its final-screen capture under in the
/// `mirroir-captures` attachment. A web capture is keyed by its step index,
/// because a web block scrapes at each capture's position; an iOS block records
/// one final screen that every `surface: ios` capture reads.
pub const IOS_CAPTURE_KEY: &str = "ios";

/// Check a `cross_surface:` step's shape before anything runs.
///
/// `opened` answers whether the scenario opens a block for a surface, so a
/// capture from a surface nothing drives is refused at plan time rather than
/// after the run, where it would surface as a missing capture.
///
/// # Errors
///
/// * [`CrossSurfaceError::TooFewFiles`] when fewer than two files are listed.
/// * [`CrossSurfaceError::CaptureTargetNotListed`] when a capture writes a file
///   the step does not compare.
/// * [`CrossSurfaceError::DuplicateCaptureTarget`] when two captures write one file.
/// * [`CrossSurfaceError::WebCaptureWithoutSelector`] /
///   [`CrossSurfaceError::IosCaptureWithSelector`] when a capture's selector
///   does not fit its surface.
/// * [`CrossSurfaceError::CaptureWithoutBlock`] when no block runs the
///   captured surface.
pub fn validate_cross_surface(
    index: usize,
    args: &CrossSurfaceArgs,
    opened: impl Fn(CaptureSurface) -> bool,
) -> Result<()> {
    if args.response_files.len() < 2 {
        return Err(CrossSurfaceError::TooFewFiles {
            count: args.response_files.len(),
        }
        .into());
    }
    let mut targets = HashSet::with_capacity(args.captures.len());
    for capture in &args.captures {
        // A capture aimed outside the compared set leaves its text unread, and
        // the comparison silently falls back to whatever sits at the listed
        // path — a stale file passes.
        if !args.response_files.contains(&capture.to) {
            return Err(CrossSurfaceError::CaptureTargetNotListed {
                to: capture.to.clone(),
                response_files: args.response_files.clone(),
            }
            .into());
        }
        if !targets.insert(capture.to.as_str()) {
            return Err(CrossSurfaceError::DuplicateCaptureTarget {
                index,
                to: capture.to.clone(),
            }
            .into());
        }
        let has_selector = capture
            .selector
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty());
        match capture.surface {
            CaptureSurface::Web if !has_selector => {
                return Err(CrossSurfaceError::WebCaptureWithoutSelector { index }.into());
            }
            CaptureSurface::Ios if capture.selector.is_some() => {
                return Err(CrossSurfaceError::IosCaptureWithSelector { index }.into());
            }
            CaptureSurface::Web | CaptureSurface::Ios => {}
        }
        if !opened(capture.surface) {
            return Err(CrossSurfaceError::CaptureWithoutBlock {
                index,
                surface: capture.surface,
            }
            .into());
        }
    }
    Ok(())
}

/// Dispatch a `cross_surface:` step: write each declared capture from the
/// blocks' attachments, then read every response file and fail on the first
/// pair whose Jaccard similarity falls below the configured threshold.
///
/// `index` is the step's position in the scenario — the key a web block filed
/// its capture under. The step's shape was checked by
/// [`validate_cross_surface`] when the plan was built.
///
/// In [`BaselineMode::Accept`] the captures are still written — that write *is*
/// the regeneration of each captured surface — and the pairwise similarities
/// are reported rather than enforced. A compared file no capture produces is a
/// committed one; accept names it instead of overwriting it.
///
/// # Errors
///
/// * [`CrossSurfaceError::NotCaptured`] when a declared capture carries no
///   text in its block's attachment.
/// * [`RunnerError::Io`] when a response file can't be read or a
///   capture can't be written.
/// * [`CrossSurfaceError::EmptySurface`] when a listed file carries no
///   comparable text, in either baseline mode.
/// * [`CrossSurfaceError::Mismatch`] when a pair falls below threshold in
///   [`BaselineMode::Compare`].
pub fn dispatch_cross_surface(
    index: usize,
    args: &CrossSurfaceArgs,
    captures: &RunCaptures,
    baselines: BaselineMode,
) -> Result<()> {
    for capture in &args.captures {
        write_capture(index, capture, captures)?;
    }

    if baselines == BaselineMode::Accept {
        report_files_no_capture_writes(args);
    }

    let threshold = args.min_similarity;
    let mut surfaces: Vec<(String, Fingerprint)> = Vec::with_capacity(args.response_files.len());
    for path in &args.response_files {
        let body = fs::read_to_string(path).map_err(|source| RunnerError::Io {
            context: format!("read cross_surface.response_files entry `{path}`"),
            source,
        })?;
        // Rejected before any pair is scored, in both baseline modes: Jaccard
        // reads two empty token sets as identical — the right answer for drift
        // against a recorded baseline, and a free pass here.
        let fingerprint = Fingerprint::of(&body);
        if fingerprint.is_empty() {
            return Err(CrossSurfaceError::EmptySurface { path: path.clone() }.into());
        }
        surfaces.push((path.clone(), fingerprint));
    }

    // Compute pairwise Jaccard similarity. Fail on the first pair below threshold.
    for i in 0..surfaces.len() {
        for j in (i + 1)..surfaces.len() {
            let sim = jaccard_similarity(&surfaces[i].1, &surfaces[j].1);
            info!(
                a = %surfaces[i].0,
                b = %surfaces[j].0,
                similarity = sim,
                threshold,
                "cross_surface pairwise check"
            );
            if sim < threshold {
                if baselines == BaselineMode::Accept {
                    // Accept regenerates what the run captured and reports the
                    // rest: a pair still below threshold means a committed file
                    // has to change, and the next ordinary run fails on it.
                    warn!(
                        a = %surfaces[i].0,
                        b = %surfaces[j].0,
                        similarity = sim,
                        threshold,
                        "cross_surface pair is still below threshold after accept"
                    );
                    continue;
                }
                return Err(CrossSurfaceError::Mismatch {
                    a: surfaces[i].0.clone(),
                    b: surfaces[j].0.clone(),
                    observed: sim,
                    threshold,
                }
                .into());
            }
        }
    }
    info!(
        files = args.response_files.len(),
        threshold, "cross_surface: all pairs above threshold"
    );
    Ok(())
}

/// Write one capture's text from the attachment its block carried.
fn write_capture(
    index: usize,
    capture: &CrossSurfaceCapture,
    captures: &RunCaptures,
) -> Result<()> {
    let key = match capture.surface {
        CaptureSurface::Web => index.to_string(),
        CaptureSurface::Ios => IOS_CAPTURE_KEY.to_owned(),
    };
    let Some(text) = captures.cross_surface.get(&key) else {
        return Err(CrossSurfaceError::NotCaptured {
            index,
            surface: capture.surface,
            to: capture.to.clone(),
        }
        .into());
    };
    // A capture is a run output, so its directory need not be committed.
    if let Some(dir) = Path::new(&capture.to).parent() {
        fs::create_dir_all(dir).map_err(|source| RunnerError::Io {
            context: format!(
                "create the directory for cross_surface capture `{}`",
                capture.to
            ),
            source,
        })?;
    }
    fs::write(&capture.to, text).map_err(|source| RunnerError::Io {
        context: format!("write cross_surface capture to `{}`", capture.to),
        source,
    })?;
    info!(
        index,
        surface = %capture.surface,
        to = %capture.to,
        bytes = text.len(),
        "cross_surface capture written"
    );
    Ok(())
}

/// Name every compared file no capture wrote, so the human knows which files
/// accept did not regenerate: a committed file changes only by hand.
fn report_files_no_capture_writes(args: &CrossSurfaceArgs) {
    for path in &args.response_files {
        if args.captures.iter().any(|capture| capture.to == *path) {
            continue;
        }
        let present = Path::new(path).is_file();
        warn!(
            file = %path,
            present,
            "accept left this cross_surface file alone: no capture in this step writes it"
        );
    }
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use serde_yaml::from_str;
    use tempfile::tempdir;

    use super::*;

    type TestResult = StdResult<(), String>;

    fn capture(surface: CaptureSurface, selector: Option<&str>, to: &str) -> CrossSurfaceCapture {
        CrossSurfaceCapture {
            surface,
            selector: selector.map(str::to_owned),
            to: to.to_owned(),
        }
    }

    fn args(files: &[&str], captures: Vec<CrossSurfaceCapture>) -> CrossSurfaceArgs {
        CrossSurfaceArgs {
            response_files: files.iter().map(|f| (*f).to_owned()).collect(),
            min_similarity: 0.5,
            captures,
        }
    }

    fn both_open(_: CaptureSurface) -> bool {
        true
    }

    fn validation_error(result: Result<()>) -> StdResult<CrossSurfaceError, String> {
        match result {
            Err(RunnerError::CrossSurface(error)) => Ok(error),
            other => Err(format!("expected a CrossSurface error, got {other:?}")),
        }
    }

    #[test]
    fn capture_target_outside_response_files_is_rejected() -> TestResult {
        // Typo: the capture writes `b.web.txt`, the step compares `b.txt`.
        let step = args(
            &["a.txt", "b.txt"],
            vec![capture(CaptureSurface::Web, Some("main"), "b.web.txt")],
        );
        match validation_error(validate_cross_surface(2, &step, both_open))? {
            CrossSurfaceError::CaptureTargetNotListed { to, .. } if to == "b.web.txt" => Ok(()),
            other => Err(format!("wrong error: {other}")),
        }
    }

    #[test]
    fn a_web_capture_needs_a_selector_and_an_ios_capture_takes_none() -> TestResult {
        let web = args(
            &["a.txt", "b.txt"],
            vec![capture(CaptureSurface::Web, None, "b.txt")],
        );
        match validation_error(validate_cross_surface(1, &web, both_open))? {
            CrossSurfaceError::WebCaptureWithoutSelector { index: 1 } => {}
            other => return Err(format!("wrong web error: {other}")),
        }
        let ios = args(
            &["a.txt", "b.txt"],
            vec![capture(CaptureSurface::Ios, Some("main"), "b.txt")],
        );
        match validation_error(validate_cross_surface(1, &ios, both_open))? {
            CrossSurfaceError::IosCaptureWithSelector { index: 1 } => Ok(()),
            other => Err(format!("wrong ios error: {other}")),
        }
    }

    #[test]
    fn two_captures_into_one_file_are_rejected() -> TestResult {
        let step = args(
            &["a.txt", "b.txt"],
            vec![
                capture(CaptureSurface::Web, Some("main"), "b.txt"),
                capture(CaptureSurface::Ios, None, "b.txt"),
            ],
        );
        match validation_error(validate_cross_surface(0, &step, both_open))? {
            CrossSurfaceError::DuplicateCaptureTarget { to, .. } if to == "b.txt" => Ok(()),
            other => Err(format!("wrong error: {other}")),
        }
    }

    /// A capture from a surface the scenario never opens is refused before the
    /// run, not discovered as a missing capture after it.
    #[test]
    fn a_capture_from_a_surface_with_no_block_is_rejected() -> TestResult {
        let step = args(
            &["a.txt", "b.txt"],
            vec![capture(CaptureSurface::Ios, None, "b.txt")],
        );
        let web_only = |surface: CaptureSurface| surface == CaptureSurface::Web;
        match validation_error(validate_cross_surface(3, &step, web_only))? {
            CrossSurfaceError::CaptureWithoutBlock {
                index: 3,
                surface: CaptureSurface::Ios,
            } => Ok(()),
            other => Err(format!("wrong error: {other}")),
        }
    }

    #[test]
    fn declared_capture_missing_from_the_attachment_is_rejected() -> TestResult {
        let step = args(
            &["a.txt", "b.txt"],
            vec![capture(CaptureSurface::Web, Some("main"), "b.txt")],
        );
        match dispatch_cross_surface(4, &step, &RunCaptures::default(), BaselineMode::Compare) {
            Err(RunnerError::CrossSurface(CrossSurfaceError::NotCaptured {
                index: 4, to, ..
            })) if to == "b.txt" => Ok(()),
            other => Err(format!("expected NotCaptured, got {other:?}")),
        }
    }

    /// Both surfaces captured live: the web scrape keyed by the step index,
    /// the iOS final screen under the fixed iOS key — written, then compared.
    #[test]
    fn a_web_and_an_ios_capture_are_both_written_and_compared() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        let web = dir.path().join("flow.web.txt").display().to_string();
        let ios = dir.path().join("flow.ios.txt").display().to_string();
        let step = args(
            &[&web, &ios],
            vec![
                capture(CaptureSurface::Web, Some("main"), &web),
                capture(CaptureSurface::Ios, None, &ios),
            ],
        );
        let mut captures = RunCaptures::default();
        captures
            .cross_surface
            .insert("2".to_owned(), "Order total 42 dollars".to_owned());
        captures.cross_surface.insert(
            IOS_CAPTURE_KEY.to_owned(),
            "Order total 42 dollars Ship".to_owned(),
        );
        dispatch_cross_surface(2, &step, &captures, BaselineMode::Compare)
            .map_err(|e| format!("valid captures rejected: {e}"))?;
        let written = fs::read_to_string(&ios).map_err(|e| e.to_string())?;
        if written != "Order total 42 dollars Ship" {
            return Err(format!("ios capture not written: {written}"));
        }
        Ok(())
    }

    /// A capture lands in a directory no one committed — `baselines/` of a
    /// sample whose only baseline is written by the run itself.
    #[test]
    fn a_capture_creates_its_directory() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        let expected = dir.path().join("expected.txt").display().to_string();
        fs::write(&expected, "General Wi-Fi Bluetooth").map_err(|e| e.to_string())?;
        let live = dir
            .path()
            .join("baselines/live.ios.txt")
            .display()
            .to_string();
        let step = args(
            &[&live, &expected],
            vec![capture(CaptureSurface::Ios, None, &live)],
        );
        let mut captures = RunCaptures::default();
        captures.cross_surface.insert(
            IOS_CAPTURE_KEY.to_owned(),
            "General Wi-Fi Bluetooth".to_owned(),
        );
        dispatch_cross_surface(0, &step, &captures, BaselineMode::Compare)
            .map_err(|e| format!("capture into a fresh directory failed: {e}"))
    }

    #[test]
    fn captures_parse_and_are_optional() -> TestResult {
        let with: CrossSurfaceArgs = from_str(
            "response_files: [a.txt, b.txt]\nmin_similarity: 0.5\ncaptures:\n  - { surface: web, selector: main, to: a.txt }\n  - { surface: ios, to: b.txt }\n",
        )
        .map_err(|e| e.to_string())?;
        if with.captures.len() != 2 || with.captures[1].surface != CaptureSurface::Ios {
            return Err(format!("captures not parsed: {:?}", with.captures));
        }
        let without: CrossSurfaceArgs =
            from_str("response_files: [a.txt, b.txt]\nmin_similarity: 0.5\n")
                .map_err(|e| e.to_string())?;
        if !without.captures.is_empty() {
            return Err("captures should default to empty".to_owned());
        }
        Ok(())
    }

    /// The singular `capture:` is not a synonym: an unknown key is refused
    /// rather than dropped, which would compare stale files.
    #[test]
    fn the_singular_capture_key_is_refused() -> TestResult {
        match from_str::<CrossSurfaceArgs>(
            "response_files: [a.txt, b.txt]\nmin_similarity: 0.5\ncapture:\n  selector: main\n  to: b.txt\n",
        ) {
            Err(e) if e.to_string().contains("capture") => Ok(()),
            Err(e) => Err(format!("rejected for the wrong reason: {e}")),
            Ok(args) => Err(format!("an unknown key parsed: {args:?}")),
        }
    }

    #[test]
    fn a_step_without_min_similarity_does_not_parse() -> TestResult {
        // The threshold is the gate: no default stands in for one the scenario
        // never declared.
        match from_str::<CrossSurfaceArgs>("response_files: [a.txt, b.txt]\n") {
            Err(e) if e.to_string().contains("min_similarity") => Ok(()),
            Err(e) => Err(format!("rejected for the wrong reason: {e}")),
            Ok(args) => Err(format!("an undeclared threshold parsed: {args:?}")),
        }
    }
}
