// ABOUTME: Oracle / verdict step argument types — judge, drift, http, report, cross_surface.
// ABOUTME: Split from step.rs to keep the grammar file under the 500-line ceiling; behavior unchanged.

use std::fmt;
use std::result::Result as StdResult;

use serde::Deserialize;

/// Arguments for `judge` — LLM oracle step. Captured at scenario time; evaluated by the Rust post-hook.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct JudgeArgs {
    /// Judge profile name (resolves against `oracles/profiles.yaml`).
    pub profile: String,
    /// SHA-256 of the user-prompt template; pinned for reproducibility.
    pub user_prompt_template_hash: String,
    /// CSS selector that locates the response text in the captured DOM.
    pub response_selector: String,
    /// Minimum score for PASS, before tolerance.
    pub pass_threshold: f64,
    /// Tolerance band around `pass_threshold` to absorb hosted-model stochasticity.
    #[serde(default)]
    pub pass_threshold_tolerance: Option<f64>,
    /// Human-readable signal (not load-bearing — for log readability).
    #[serde(default)]
    pub expected_signal: Option<String>,
    /// Optional drift-detection configuration over the response text.
    #[serde(default)]
    pub response_drift: Option<ResponseDriftConfig>,
    /// Inline response text to judge. Mutually exclusive with `response_file`.
    /// Used when the scenario captures the response in a step preceding the
    /// `judge:` step (e.g. via an `http:` probe or an explicit capture step).
    #[serde(default)]
    pub response_text: Option<String>,
    /// Path to a file containing the response text. Useful when a preceding
    /// step wrote the text to disk — a `cross_surface:` capture's `to`, or a
    /// producer outside this run. Text the page itself produced arrives on the
    /// `mirroir-captures` attachment instead and needs no file.
    #[serde(default)]
    pub response_file: Option<String>,
    /// Path to the text this step drifts from, in place of the
    /// `.harness/last-green.json` entry. Read on an ordinary run; rewritten
    /// with what the run judged under `mirroir-run accept`.
    #[serde(default)]
    pub drift_baseline_file: Option<String>,
}

/// Configuration for response-text drift detection between runs.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ResponseDriftConfig {
    /// Maximum Levenshtein-pct delta vs. previous-green response. Above triggers DRIFT.
    pub max_levenshtein_pct: f64,
}

/// Arguments for `http` — REST probe with optional response assertions.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct HttpArgs {
    /// HTTP method.
    pub method: HttpMethod,
    /// Target URL.
    pub url: String,
    /// Optional required status code (e.g. `200`).
    #[serde(default)]
    pub expect_status: Option<u16>,
    /// Optional substrings the response body must contain.
    #[serde(default)]
    pub expect_body_contains: Vec<String>,
    /// Optional request timeout in seconds (defaults to 30 s when omitted).
    #[serde(default)]
    pub timeout_s: Option<u32>,
}

/// HTTP method for the `http` step.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "UPPERCASE")]
pub enum HttpMethod {
    /// `GET`.
    Get,
    /// `POST`.
    Post,
    /// `PUT`.
    Put,
    /// `DELETE`.
    Delete,
    /// `HEAD`.
    Head,
    /// `PATCH`.
    Patch,
}

/// Arguments for `report` — emit a final verdict for the scenario.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReportArgs {
    /// Verdict to emit.
    pub verdict: ReportVerdict,
}

/// Scenario verdicts producible by an explicit `report` step.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReportVerdict {
    /// Scenario passed.
    Pass,
    /// Scenario failed.
    Fail,
    /// Scenario passed structurally but drifted from baseline.
    Drift,
    /// Cross-surface invariant verified.
    CrossSurfacePass,
}

/// Arguments for `cross_surface` — verify pairwise equivalence of N captured
/// responses (one per surface). Each entry is a path to a file a surface
/// wrote, so a web block's scrape, an iOS block's final screen, or a committed
/// file can all feed into the same equivalence check.
///
/// Unknown keys are refused: a misspelt `captures:` would otherwise leave the
/// step comparing whatever stale files sit at the listed paths.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CrossSurfaceArgs {
    /// Filesystem paths whose contents are compared pairwise.
    pub response_files: Vec<String>,
    /// Minimum pairwise fingerprint similarity in `[0, 1]`. Required: the
    /// threshold *is* the gate, so the scenario declares how close the surfaces
    /// have to be rather than inheriting a number nobody chose.
    pub min_similarity: f64,
    /// Files this run writes before comparing, one per captured surface: a web
    /// block scrapes a selector, an iOS block records its final screen. Each
    /// produces one of the `response_files` instead of a hand-committed copy.
    #[serde(default)]
    pub captures: Vec<CrossSurfaceCapture>,
}

/// One surface's capture, written to `to` during replay.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CrossSurfaceCapture {
    /// The block whose run produces the text.
    pub surface: CaptureSurface,
    /// For `surface: web`, the CSS / Playwright selector whose text is scraped.
    /// An iOS capture is the block's final screen and takes none.
    #[serde(default)]
    pub selector: Option<String>,
    /// File path the captured text is written to. Must be one of
    /// `response_files`. `${MIRROIR_SAMPLE_DIR}` is resolved at load time.
    pub to: String,
}

/// The surface a `cross_surface` capture reads.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CaptureSurface {
    /// Scraped from the page by the scenario's Playwright invocation.
    Web,
    /// The final screen of the scenario's iOS block, read by mirroir-mcp's OCR.
    Ios,
}

impl CaptureSurface {
    /// The surface as a scenario spells it.
    #[must_use]
    pub const fn as_yaml(self) -> &'static str {
        match self {
            Self::Web => "web",
            Self::Ios => "ios",
        }
    }
}

impl fmt::Display for CaptureSurface {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_yaml())
    }
}

impl<'de> Deserialize<'de> for ReportArgs {
    fn deserialize<D>(deserializer: D) -> StdResult<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Repr {
            Shorthand(ReportVerdict),
            Full { verdict: ReportVerdict },
        }
        Ok(match Repr::deserialize(deserializer)? {
            Repr::Shorthand(v) => Self { verdict: v },
            Repr::Full { verdict } => Self { verdict },
        })
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use serde_yaml::Deserializer;
    use serde_yaml::with::singleton_map_recursive;

    use super::{HttpMethod, ReportArgs, ReportVerdict};
    use crate::parser::step::SkillStep;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn parse(yaml: &str) -> StdResult<SkillStep, serde_yaml::Error> {
        singleton_map_recursive::deserialize(Deserializer::from_str(yaml))
    }

    fn fail<T>(reason: String) -> StdResult<T, Box<dyn StdError>> {
        Err(reason.into())
    }

    #[test]
    fn judge_full_shape() -> TestResult {
        let yaml = r#"
judge:
  profile: fast-ci
  user_prompt_template_hash: "sha256:abc"
  response_selector: "[data-test=message-agent]"
  pass_threshold: 0.9
  pass_threshold_tolerance: 0.05
  response_drift:
    max_levenshtein_pct: 0.2
"#;
        let SkillStep::Judge(args) = parse(yaml)? else {
            return fail("expected Judge variant".to_owned());
        };
        assert_eq!(args.profile, "fast-ci");
        assert!((args.pass_threshold - 0.9).abs() < f64::EPSILON);
        assert_eq!(args.pass_threshold_tolerance, Some(0.05));
        assert!(args.response_drift.is_some());
        Ok(())
    }

    #[test]
    fn http_get_with_assertions() -> TestResult {
        let yaml = r#"
http:
  method: GET
  url: "http://localhost:8081/api/transport-info"
  expect_status: 200
  expect_body_contains: ["webtransport", "websocket"]
"#;
        let SkillStep::Http(args) = parse(yaml)? else {
            return fail("expected Http variant".to_owned());
        };
        assert_eq!(args.method, HttpMethod::Get);
        assert_eq!(args.expect_status, Some(200));
        assert_eq!(
            args.expect_body_contains,
            vec!["webtransport".to_owned(), "websocket".to_owned()]
        );
        Ok(())
    }

    #[test]
    fn report_shorthand_and_full() -> TestResult {
        let short = parse("report: pass")?;
        let full = parse("report: { verdict: drift }")?;
        assert!(matches!(
            short,
            SkillStep::Report(ReportArgs {
                verdict: ReportVerdict::Pass
            })
        ));
        assert!(matches!(
            full,
            SkillStep::Report(ReportArgs {
                verdict: ReportVerdict::Drift
            })
        ));
        Ok(())
    }
}
