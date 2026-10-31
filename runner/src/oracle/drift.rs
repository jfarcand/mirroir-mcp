// ABOUTME: Drift detection — fingerprint Jaccard + response Levenshtein delta vs. baseline.
// ABOUTME: Pure functions; no I/O. Consumers persist baselines + thresholds out-of-band.

use std::collections::BTreeSet;
use std::mem;

use crate::parser::step::ResponseDriftConfig;

/// Token-set view of a response text used for Jaccard similarity.
///
/// Tokens are whitespace-separated, lowercased, with surrounding ASCII
/// punctuation trimmed. Order is normalized via `BTreeSet` so two
/// responses with the same token bag compare equal at the fingerprint
/// level regardless of word order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fingerprint {
    tokens: BTreeSet<String>,
}

impl Fingerprint {
    /// Compute a fingerprint of the given text.
    #[must_use]
    pub fn of(text: &str) -> Self {
        let tokens: BTreeSet<String> = text
            .split_whitespace()
            .map(|w| {
                w.trim_matches(|c: char| c.is_ascii_punctuation())
                    .to_lowercase()
            })
            .filter(|w| !w.is_empty())
            .collect();
        Self { tokens }
    }

    /// Number of unique tokens captured.
    #[cfg(test)]
    #[must_use]
    pub fn len(&self) -> usize {
        self.tokens.len()
    }

    /// True when the text carried no tokens — blank, whitespace-only, or
    /// nothing but punctuation. A caller that needs evidence, rather than a
    /// similarity score, checks this before comparing: two empty fingerprints
    /// are vacuously identical.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.tokens.is_empty()
    }
}

/// Jaccard similarity between two fingerprints: `|A ∩ B| / |A ∪ B|`.
///
/// Returns 1.0 when both fingerprints are empty (vacuously identical).
/// Returns 0.0 when only one side is empty.
#[must_use]
pub fn jaccard_similarity(a: &Fingerprint, b: &Fingerprint) -> f64 {
    jaccard_index(&a.tokens, &b.tokens)
}

/// Jaccard index of two sets: `|A ∩ B| / |A ∪ B|`, with two empty sets
/// vacuously identical (1.0). The one Jaccard every drift metric uses.
#[must_use]
pub fn jaccard_index<T: Ord>(a: &BTreeSet<T>, b: &BTreeSet<T>) -> f64 {
    let union = a.union(b).count();
    if union == 0 {
        return 1.0;
    }
    a.intersection(b).count() as f64 / union as f64
}

/// Levenshtein edit distance between `a` and `b`, normalized to `[0, 1]`
/// by dividing by `max(len(a), len(b))`. Returns 0.0 when both are empty.
#[must_use]
pub fn levenshtein_pct(a: &str, b: &str) -> f64 {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let n = a_chars.len();
    let m = b_chars.len();
    if n == 0 && m == 0 {
        return 0.0;
    }
    let distance = levenshtein_distance(&a_chars, &b_chars);
    distance as f64 / n.max(m) as f64
}

fn levenshtein_distance(a: &[char], b: &[char]) -> usize {
    let n = a.len();
    let m = b.len();
    if n == 0 {
        return m;
    }
    if m == 0 {
        return n;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut cur: Vec<usize> = vec![0; m + 1];
    for i in 1..=n {
        cur[0] = i;
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            let del = prev[j] + 1;
            let ins = cur[j - 1] + 1;
            let sub = prev[j - 1] + cost;
            cur[j] = del.min(ins).min(sub);
        }
        mem::swap(&mut prev, &mut cur);
    }
    prev[m]
}

/// Drift verdict for a single (baseline, current) comparison.
#[derive(Debug, Clone, PartialEq)]
pub enum DriftVerdict {
    /// Response is within configured thresholds.
    Match {
        /// Jaccard similarity of token-set fingerprints, in `[0, 1]`.
        fingerprint_similarity: f64,
        /// Normalized Levenshtein distance, in `[0, 1]`.
        levenshtein_pct: f64,
    },
    /// Response diverged from baseline above one or more thresholds.
    Drift {
        /// Jaccard similarity that was observed.
        fingerprint_similarity: f64,
        /// Levenshtein delta that was observed.
        levenshtein_pct: f64,
        /// Human-readable summary of which threshold(s) tripped.
        reason: String,
    },
}

/// Compare a current response text to a baseline using the scenario's
/// `response_drift` config. Both fingerprints and Levenshtein distance are
/// computed; only Levenshtein is thresholded (per the design spec —
/// fingerprint similarity is reported for diagnostics).
#[must_use]
pub fn detect_drift(baseline: &str, current: &str, config: &ResponseDriftConfig) -> DriftVerdict {
    let baseline_fp = Fingerprint::of(baseline);
    let current_fp = Fingerprint::of(current);
    let fingerprint_similarity = jaccard_similarity(&baseline_fp, &current_fp);
    let lev = levenshtein_pct(baseline, current);
    if lev > config.max_levenshtein_pct {
        DriftVerdict::Drift {
            fingerprint_similarity,
            levenshtein_pct: lev,
            reason: format!(
                "levenshtein {lev:.3} > max {threshold:.3}",
                threshold = config.max_levenshtein_pct
            ),
        }
    } else {
        DriftVerdict::Match {
            fingerprint_similarity,
            levenshtein_pct: lev,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn approx_eq(a: f64, b: f64, eps: f64) -> bool {
        (a - b).abs() < eps
    }

    #[test]
    fn fingerprint_normalises_whitespace_case_and_punctuation() {
        let fp = Fingerprint::of("Hello, World! hello?");
        assert_eq!(fp.len(), 2); // "hello" once, "world" once.
    }

    #[test]
    fn jaccard_identical_text_is_one() {
        let a = Fingerprint::of("the quick brown fox");
        let b = Fingerprint::of("the quick brown fox");
        let sim = jaccard_similarity(&a, &b);
        assert!(approx_eq(sim, 1.0, 1e-9), "got {sim}");
    }

    #[test]
    fn jaccard_disjoint_text_is_zero() {
        let a = Fingerprint::of("apple banana cherry");
        let b = Fingerprint::of("dog elephant fish");
        let sim = jaccard_similarity(&a, &b);
        assert!(approx_eq(sim, 0.0, 1e-9), "got {sim}");
    }

    #[test]
    fn jaccard_half_overlap() {
        let a = Fingerprint::of("alpha beta gamma");
        let b = Fingerprint::of("beta gamma delta");
        let sim = jaccard_similarity(&a, &b);
        // intersection: {beta, gamma} = 2; union: {alpha, beta, gamma, delta} = 4 → 0.5
        assert!(approx_eq(sim, 0.5, 1e-9), "got {sim}");
    }

    #[test]
    fn jaccard_both_empty_is_one() {
        let a = Fingerprint::of("");
        let b = Fingerprint::of("   \n\t ");
        let sim = jaccard_similarity(&a, &b);
        assert!(approx_eq(sim, 1.0, 1e-9), "got {sim}");
    }

    #[test]
    fn levenshtein_identical_is_zero() {
        assert!(approx_eq(levenshtein_pct("kitten", "kitten"), 0.0, 1e-9));
    }

    #[test]
    fn levenshtein_classic_kitten_sitting_is_three_over_seven() {
        // distance = 3 (k→s, e→i, +g), max(6,7) = 7
        let pct = levenshtein_pct("kitten", "sitting");
        assert!(
            approx_eq(pct, 3.0 / 7.0, 1e-9),
            "got {pct}, expected {}",
            3.0 / 7.0
        );
    }

    #[test]
    fn levenshtein_disjoint_short_strings() {
        // "abc" → "xyz": 3 substitutions over max=3 → 1.0
        let pct = levenshtein_pct("abc", "xyz");
        assert!(approx_eq(pct, 1.0, 1e-9), "got {pct}");
    }

    #[test]
    fn detect_drift_returns_match_when_under_threshold() -> TestResult {
        let baseline = "The quick brown fox jumps over the lazy dog.";
        let current = "The quick brown fox jumps over the lazy dog.";
        let config = ResponseDriftConfig {
            max_levenshtein_pct: 0.2,
        };
        let verdict = detect_drift(baseline, current, &config);
        let DriftVerdict::Match {
            fingerprint_similarity,
            levenshtein_pct,
        } = verdict
        else {
            return Err(format!("expected Match, got {verdict:?}").into());
        };
        if !(approx_eq(fingerprint_similarity, 1.0, 1e-9) && approx_eq(levenshtein_pct, 0.0, 1e-9))
        {
            return Err(format!(
                "wrong values: fp={fingerprint_similarity}, lev={levenshtein_pct}"
            )
            .into());
        }
        Ok(())
    }

    #[test]
    fn detect_drift_returns_drift_when_above_threshold() -> TestResult {
        let baseline = "Server returned 42 messages.";
        let current = "The capital of Mars is unknowable.";
        let config = ResponseDriftConfig {
            max_levenshtein_pct: 0.2,
        };
        let verdict = detect_drift(baseline, current, &config);
        let DriftVerdict::Drift {
            reason,
            levenshtein_pct,
            ..
        } = verdict
        else {
            return Err(format!("expected Drift, got {verdict:?}").into());
        };
        if levenshtein_pct <= 0.2 {
            return Err(format!("expected lev > 0.2, got {levenshtein_pct}").into());
        }
        if !reason.contains("levenshtein") {
            return Err(format!("unexpected reason: {reason}").into());
        }
        Ok(())
    }

    #[test]
    fn detect_drift_subtle_change_under_threshold() -> TestResult {
        let baseline = "Hello world from mirroir";
        let current = "Hello world from mirroir!"; // one extra `!`
        let config = ResponseDriftConfig {
            max_levenshtein_pct: 0.1,
        };
        let verdict = detect_drift(baseline, current, &config);
        if !matches!(verdict, DriftVerdict::Match { .. }) {
            return Err(format!("expected Match, got {verdict:?}").into());
        }
        Ok(())
    }
}
