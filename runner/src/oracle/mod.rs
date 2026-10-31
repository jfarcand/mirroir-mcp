// ABOUTME: Oracle module — drift detection, thresholds, baselines, LLM judge scoring, profile registry.
// ABOUTME: Owns the DRIFT verdict: every assertion green, and the semantics moved past a declared threshold.

pub mod baseline;
pub mod drift;
pub mod drift_log;
pub mod drift_session;
pub mod error;
pub mod judge;
pub mod judge_profiles;
pub mod screen_drift;
pub mod thresholds;
