// ABOUTME: Compares the screens an `ios` block left against its `<scenario>.compiled.json` reference.
// ABOUTME: Similarity is Swift's: equal hashes are 1.0, else Jaccard of the structural-text sets.

use std::collections::{BTreeMap, BTreeSet};

use tracing::info;

use crate::error::Result;
use crate::oracle::drift::jaccard_index;
use crate::oracle::drift_log::{DriftFinding, ReferenceGap};
use crate::oracle::thresholds::{DriftMetric, DriftPolicy};
use crate::parser::compiled::{CompiledSkill, DeviceInfo, ScreenFingerprint};

/// The key `mirroir-mcp test` files the screen read before step 0 under.
pub const START_SCREEN: &str = "start";

/// One `ios` block's screens, ready to compare against its reference.
#[derive(Debug, Clone, Copy)]
pub struct ScreenCheck<'a> {
    /// The compiled reference recorded next to the scenario.
    pub reference: &'a CompiledSkill,
    /// Hex SHA-256 of the scenario file's bytes as this run read them.
    pub source_sha256: &'a str,
    /// The screens this run observed: [`START_SCREEN`] and one per block step
    /// index that ran.
    pub observed: &'a BTreeMap<String, ScreenFingerprint>,
    /// The mirroring window this run read its screens in, as the report
    /// filed it beside them.
    pub observed_device: Option<&'a DeviceInfo>,
    /// Scenario index of the block's step 0, to name steps as the scenario
    /// file reads them.
    pub block_start: usize,
}

/// Similarity of two screens (0.0–1.0), identical to Swift
/// `StructuralFingerprint.similarity`: equal hashes are the same screen;
/// otherwise the Jaccard index of the structural-text sets, where two empty
/// sets are the same (empty) screen.
#[must_use]
pub fn screen_similarity(lhs: &ScreenFingerprint, rhs: &ScreenFingerprint) -> f64 {
    if lhs.hash == rhs.hash {
        return 1.0;
    }
    let left: BTreeSet<&str> = lhs.structural_texts.iter().map(String::as_str).collect();
    let right: BTreeSet<&str> = rhs.structural_texts.iter().map(String::as_str).collect();
    jaccard_index(&left, &right)
}

/// Every way the block's screens moved away from the reference.
///
/// The `fingerprint_similarity` floor is resolved only when a pair of screens
/// is actually compared, so a reference with nothing comparable needs no
/// threshold. A screen on one side only, a scenario file whose digest no
/// longer matches the reference's, and screens read in a window other than
/// the reference's are findings in their own right: the comparison they would have allowed is never silently skipped.
///
/// # Errors
///
/// [`crate::oracle::error::OracleError::ThresholdUnspecified`] when a pair is
/// compared and no layer declares `fingerprint_similarity`.
pub fn compare_screens(policy: &DriftPolicy, check: ScreenCheck<'_>) -> Result<Vec<DriftFinding>> {
    let mut findings = Vec::new();
    let reference = check.reference;
    if reference.source.sha256 != check.source_sha256 {
        findings.push(DriftFinding::Reference {
            gap: ReferenceGap::SourceChanged,
            detail: format!(
                "the scenario's sha256 is {} but its compiled reference was recorded from {}",
                check.source_sha256, reference.source.sha256
            ),
        });
    }
    if let Some(detail) = device_change(&reference.device, check.observed_device) {
        findings.push(DriftFinding::Reference {
            gap: ReferenceGap::DeviceChanged,
            detail,
        });
    }

    let mut expected: BTreeMap<String, (String, &ScreenFingerprint)> = BTreeMap::new();
    if let Some(start) = reference.screen_fingerprint.as_ref() {
        expected.insert(
            START_SCREEN.to_owned(),
            ("the start screen".to_owned(), start),
        );
    }
    for step in &reference.steps {
        if let Some(arrival) = reference.arrival(step.index) {
            let name = step_name(
                check.block_start,
                step.index,
                &step.kind,
                step.label.as_deref(),
            );
            expected.insert(step.index.to_string(), (name, arrival));
        }
    }

    for (key, (name, recorded)) in &expected {
        let Some(observed) = check.observed.get(key) else {
            findings.push(DriftFinding::Reference {
                gap: ReferenceGap::ScreenUnobserved,
                detail: format!("{name}: the reference recorded a screen this run never read"),
            });
            continue;
        };
        let similarity = screen_similarity(recorded, observed);
        let floor = policy.resolve(DriftMetric::FingerprintSimilarity, None)?;
        info!(screen = %key, similarity, floor, "drift check: fingerprint_similarity (screen)");
        if similarity < floor {
            findings.push(DriftFinding::Metric {
                metric: DriftMetric::FingerprintSimilarity,
                observed: similarity,
                threshold: floor,
                detail: format!("{name}: {}", text_delta(recorded, observed)),
            });
        }
    }
    for key in check.observed.keys().filter(|k| !expected.contains_key(*k)) {
        findings.push(DriftFinding::Reference {
            gap: ReferenceGap::ScreenUnreferenced,
            detail: format!("ios block screen `{key}`: observed, but the reference recorded none"),
        });
    }
    Ok(findings)
}

/// Why this run's window cannot stand in for the reference's: a different
/// size or orientation lays the same screen out differently. Nil when they
/// match, or when the run reported no window — mirroir-mcp files one beside
/// any screen it read, so a run without one has no screen either and every
/// recorded screen is already a `screen_unobserved` finding.
fn device_change(recorded: &DeviceInfo, observed: Option<&DeviceInfo>) -> Option<String> {
    let describe =
        |d: &DeviceInfo| format!("{}x{} {}", d.window_width, d.window_height, d.orientation);
    let observed = observed?;
    if observed == recorded {
        return None;
    }
    Some(format!(
        "the screens were read in a {} window but the reference was recorded in a {} one",
        describe(observed),
        describe(recorded)
    ))
}

/// `ios block step 2 (scenario step 5, tap: "World Clock")`.
fn step_name(block_start: usize, index: usize, kind: &str, label: Option<&str>) -> String {
    let scenario_index = block_start + index;
    let step = label.map_or_else(|| kind.to_owned(), |label| format!("{kind}: \"{label}\""));
    format!("ios block step {index} (scenario step {scenario_index}, {step})")
}

/// The texts the reference had and this run lacks, and the reverse.
fn text_delta(recorded: &ScreenFingerprint, observed: &ScreenFingerprint) -> String {
    let before: BTreeSet<&str> = recorded
        .structural_texts
        .iter()
        .map(String::as_str)
        .collect();
    let after: BTreeSet<&str> = observed
        .structural_texts
        .iter()
        .map(String::as_str)
        .collect();
    let quote = |texts: Vec<&&str>| -> String {
        if texts.is_empty() {
            return "none".to_owned();
        }
        texts
            .iter()
            .map(|t| format!("\"{t}\""))
            .collect::<Vec<_>>()
            .join(", ")
    };
    format!(
        "missing {}; new {}; icons {} → {}",
        quote(before.difference(&after).collect()),
        quote(after.difference(&before).collect()),
        recorded.icon_count,
        observed.icon_count
    )
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;
    use crate::compile::report::parse_report_body;
    use crate::compile::report_error::ReportEngine;
    use crate::error::RunnerError;
    use crate::oracle::error::OracleError;
    use crate::oracle::thresholds::{DriftThresholds, MinThreshold};
    use crate::parser::compiled::sha256_hex;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    const COMPILED: &str =
        include_str!("../../tests/fixtures/compiled/world-clock.ios.compiled.json");
    const SCENARIO: &[u8] = include_bytes!("../../tests/fixtures/compiled/world-clock.ios.yaml");
    const MATCH: &str = include_str!("../../tests/fixtures/compiled/report-match.json");
    const DRIFT: &str = include_str!("../../tests/fixtures/compiled/report-drift.json");

    fn policy(min: f64) -> DriftPolicy {
        DriftPolicy::new(
            None,
            None,
            Some(DriftThresholds {
                fingerprint_similarity: Some(MinThreshold { min }),
                ..DriftThresholds::default()
            }),
        )
    }

    fn reference() -> StdResult<CompiledSkill, Box<dyn StdError>> {
        Ok(serde_json::from_str(COMPILED)?)
    }

    fn screens(report: &str) -> StdResult<BTreeMap<String, ScreenFingerprint>, Box<dyn StdError>> {
        Ok(
            parse_report_body(ReportEngine::MirroirMcp, "r.json", report)?
                .captures
                .screens,
        )
    }

    fn fp(hash: &str, texts: &[&str]) -> ScreenFingerprint {
        ScreenFingerprint {
            hash: hash.to_owned(),
            icon_count: 0,
            structural_texts: texts.iter().map(|t| (*t).to_owned()).collect(),
        }
    }

    #[test]
    fn similarity_is_swifts_hash_then_jaccard() {
        assert!((screen_similarity(&fp("a", &["x"]), &fp("a", &["y"])) - 1.0).abs() < f64::EPSILON);
        let jaccard = screen_similarity(&fp("a", &["x", "y", "z"]), &fp("b", &["y", "z", "w"]));
        assert!((jaccard - 0.5).abs() < f64::EPSILON, "{jaccard}");
        assert!((screen_similarity(&fp("a", &[]), &fp("b", &[])) - 1.0).abs() < f64::EPSILON);
        assert!(screen_similarity(&fp("a", &["x"]), &fp("b", &[])).abs() < f64::EPSILON);
    }

    #[test]
    fn the_matching_report_has_no_findings() -> TestResult {
        let reference = reference()?;
        let observed = screens(MATCH)?;
        let check = ScreenCheck {
            reference: &reference,
            source_sha256: &sha256_hex(SCENARIO),
            observed: &observed,
            observed_device: Some(&reference.device),
            block_start: 0,
        };
        let findings = compare_screens(&policy(0.85), check)?;
        assert!(findings.is_empty(), "{findings:?}");
        Ok(())
    }

    /// Cupertino became London after the tap: Jaccard 6/8 = 0.75, under 0.85.
    #[test]
    fn the_drifted_report_names_the_step_and_the_texts() -> TestResult {
        let reference = reference()?;
        let observed = screens(DRIFT)?;
        let check = ScreenCheck {
            reference: &reference,
            source_sha256: &sha256_hex(SCENARIO),
            observed: &observed,
            observed_device: Some(&reference.device),
            block_start: 0,
        };
        let findings = compare_screens(&policy(0.85), check)?;
        let [
            DriftFinding::Metric {
                metric,
                observed,
                detail,
                ..
            },
        ] = findings.as_slice()
        else {
            return Err(format!("expected one metric finding, got {findings:?}").into());
        };
        assert_eq!(*metric, DriftMetric::FingerprintSimilarity);
        assert!((observed - 0.75).abs() < 1e-9, "{observed}");
        assert!(detail.contains("ios block step 2"), "{detail}");
        assert!(
            detail.contains("missing \"Cupertino\"; new \"London\""),
            "{detail}"
        );
        let at_the_floor = compare_screens(&policy(0.75), check)?;
        assert!(at_the_floor.is_empty(), "{at_the_floor:?}");
        Ok(())
    }

    #[test]
    fn unpaired_screens_and_a_changed_source_are_findings() -> TestResult {
        let reference = reference()?;
        let mut observed = screens(MATCH)?;
        observed.remove("3");
        observed.insert("9".to_owned(), fp("z", &["extra"]));
        let check = ScreenCheck {
            reference: &reference,
            source_sha256: "0000",
            observed: &observed,
            observed_device: Some(&reference.device),
            block_start: 4,
        };
        let findings = compare_screens(&policy(0.85), check)?;
        let labels: Vec<&str> = findings.iter().map(DriftFinding::metric_label).collect();
        assert_eq!(
            labels,
            vec![
                "compiled_source_changed",
                "screen_unobserved",
                "screen_unreferenced"
            ]
        );
        let unobserved = findings
            .get(1)
            .map(DriftFinding::detail)
            .unwrap_or_default();
        assert!(
            unobserved.contains("scenario step 7, wait_for: \"Cupertino\""),
            "{unobserved}"
        );
        Ok(())
    }

    /// A comparison that is due with no layer declaring the floor is refused
    /// by name, never guessed.
    #[test]
    fn a_due_comparison_with_no_floor_is_refused() -> TestResult {
        let reference = reference()?;
        let observed = screens(MATCH)?;
        let check = ScreenCheck {
            reference: &reference,
            source_sha256: &sha256_hex(SCENARIO),
            observed: &observed,
            observed_device: Some(&reference.device),
            block_start: 0,
        };
        match compare_screens(&DriftPolicy::default(), check) {
            Err(RunnerError::Oracle(OracleError::ThresholdUnspecified { metric })) => {
                assert_eq!(metric, DriftMetric::FingerprintSimilarity);
                Ok(())
            }
            other => Err(format!("expected ThresholdUnspecified, got {other:?}").into()),
        }
    }

    /// Screens read in another window are not compared silently: the window
    /// change is its own finding, beside whatever the screens scored.
    #[test]
    fn a_different_window_is_a_finding() -> TestResult {
        let reference = reference()?;
        let observed = screens(MATCH)?;
        let mut landscape = reference.device.clone();
        landscape.orientation = "landscape".to_owned();
        let check = ScreenCheck {
            reference: &reference,
            source_sha256: &sha256_hex(SCENARIO),
            observed: &observed,
            observed_device: Some(&landscape),
            block_start: 0,
        };
        let findings = compare_screens(&policy(0.85), check)?;
        let labels: Vec<&str> = findings.iter().map(DriftFinding::metric_label).collect();
        assert_eq!(labels, vec!["compiled_device_changed"]);
        let detail = findings
            .first()
            .map(DriftFinding::detail)
            .unwrap_or_default();
        assert!(detail.contains("landscape window"), "{detail}");
        Ok(())
    }
}
