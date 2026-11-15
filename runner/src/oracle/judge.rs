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
// ABOUTME: LLM judge oracle — scores response text against expectation using a profile registry.
// ABOUTME: The profile's api_target picks the LlmClient: OpenAI chat completions, Anthropic Messages or Ollama chat.

use std::env;
use std::time::Duration;

use sha2::{Digest, Sha256};
use tracing::{debug, info};

use crate::error::Result;
use crate::oracle::error::OracleError;
use crate::oracle::llm_client::{
    AnthropicClient, ApiTarget, Endpoint, LlmClient, OllamaClient, OpenAiClient,
};
use crate::parser::step::JudgeArgs;
use crate::tls;

// The profile registry lives in its own module; re-export so existing callers
// keep using `crate::oracle::judge::{JudgeProfile, JudgeRegistry}`.
pub use crate::oracle::judge_profiles::{JudgeProfile, JudgeRegistry};

/// Outcome of a single judge invocation.
#[derive(Debug, Clone, PartialEq)]
pub struct JudgeOutcome {
    /// Score in `[0, 1]` extracted from the model's reply.
    pub score: f64,
    /// Raw text of the model's reply (for diagnostics).
    pub raw: String,
}

/// Score `response` against the scenario's `judge:` args using the named
/// profile. Returns `Ok(JudgeOutcome)` on transport+decode success; the
/// caller is responsible for thresholding via [`enforce_threshold`].
///
/// # Errors
///
/// * [`OracleError::UnknownProfile`] when `args.profile` isn't registered.
/// * [`OracleError::MissingApiKey`] when the profile needs an env key.
/// * [`crate::http_error::HttpError::Tls`] when the shared rustls config cannot be built.
/// * [`OracleError::Transport`] on HTTP transport failure.
/// * [`OracleError::Decode`] when the model's reply can't be parsed as a score.
pub async fn run_judge(
    registry: &JudgeRegistry,
    args: &JudgeArgs,
    response: &str,
) -> Result<JudgeOutcome> {
    verify_template_hash(&args.user_prompt_template_hash)?;
    let profile = registry.resolve(&args.profile)?;
    let api_key = api_key_for(profile)?;
    let prompt = build_prompt(args, response);
    info!(
        profile = %profile.name,
        model = %profile.model,
        url = %profile.base_url,
        response_len = response.len(),
        "running judge"
    );

    let http = tls::client_builder()?
        .timeout(Duration::from_secs(u64::from(profile.timeout_s)))
        .user_agent(format!("mirroir-run/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|source| OracleError::Transport {
            url: profile.base_url.clone(),
            source,
        })?;
    let endpoint = Endpoint {
        http,
        url: profile.base_url.clone(),
        model: profile.model.clone(),
        api_key,
    };
    let system = profile.system_prompt.text.as_str();
    let raw = match profile.api_target {
        ApiTarget::OpenAi => OpenAiClient(endpoint).complete(system, &prompt).await?,
        ApiTarget::Anthropic => AnthropicClient(endpoint).complete(system, &prompt).await?,
        ApiTarget::Ollama => OllamaClient(endpoint).complete(system, &prompt).await?,
    };
    let score = parse_score(&raw)?;
    debug!(score, raw = %raw, "judge returned");
    Ok(JudgeOutcome { score, raw })
}

/// Apply `pass_threshold` + optional tolerance to a [`JudgeOutcome`].
///
/// # Errors
///
/// [`OracleError::BelowThreshold`] when `score < threshold - tolerance`.
pub fn enforce_threshold(
    profile_name: &str,
    args: &JudgeArgs,
    outcome: &JudgeOutcome,
) -> Result<()> {
    let tolerance = args.pass_threshold_tolerance.unwrap_or(0.0);
    let effective = args.pass_threshold - tolerance;
    if outcome.score < effective {
        return Err(OracleError::BelowThreshold {
            profile: profile_name.to_owned(),
            score: outcome.score,
            threshold: effective,
        }
        .into());
    }
    Ok(())
}

fn api_key_for(profile: &JudgeProfile) -> Result<Option<String>> {
    let Some(env_name) = profile.api_key_env.as_deref() else {
        return Ok(None);
    };
    match env::var(env_name) {
        Ok(value) if !value.is_empty() => Ok(Some(value)),
        _ => Err(OracleError::MissingApiKey {
            profile: profile.name.clone(),
            env_var: env_name.to_owned(),
        }
        .into()),
    }
}

/// Canonical user-prompt template the judge sends to the model. `{expected}`
/// and `{response}` are substituted at run time. Scenarios pin
/// [`user_prompt_template_hash`] over this literal so that changing the oracle
/// wording invalidates scenarios calibrated against the old prompt — the
/// reproducibility guarantee `judge.user_prompt_template_hash` promises.
const USER_PROMPT_TEMPLATE: &str = "You are a deterministic test oracle. Given an AI agent's response, score how well it \
matches the expected outcome. Return ONLY a single decimal number between 0.0 (total \
failure) and 1.0 (perfect match), with at most three decimal places. Do not include any \
other text, justification, or punctuation.\n\n\
Expected outcome: __EXPECTED__\n\n\
Agent response:\n```\n__RESPONSE__\n```\n\n\
Score:";

/// SHA-256 of [`USER_PROMPT_TEMPLATE`], formatted `sha256:<hex>`. A scenario's
/// `judge.user_prompt_template_hash` must equal this value.
#[must_use]
pub fn user_prompt_template_hash() -> String {
    let digest = Sha256::digest(USER_PROMPT_TEMPLATE.as_bytes());
    format!("sha256:{}", hex::encode(digest))
}

/// Verify the scenario's pinned template hash matches the current template.
///
/// # Errors
///
/// [`OracleError::TemplateMismatch`] when the declared hash differs from
/// the hash of [`USER_PROMPT_TEMPLATE`] — the oracle prompt changed and the
/// scenario must be re-pinned to keep its score calibration meaningful.
fn verify_template_hash(declared: &str) -> Result<()> {
    let expected = user_prompt_template_hash();
    if declared == expected {
        Ok(())
    } else {
        Err(OracleError::TemplateMismatch {
            expected,
            declared: declared.to_owned(),
        }
        .into())
    }
}

fn build_prompt(args: &JudgeArgs, response: &str) -> String {
    let expected = args
        .expected_signal
        .as_deref()
        .unwrap_or("the response satisfies the scenario's success criteria with high fidelity");
    USER_PROMPT_TEMPLATE
        .replace("__EXPECTED__", expected)
        .replace("__RESPONSE__", response)
}

/// Extract a score from the model's textual reply.
///
/// Tolerates surrounding whitespace, a trailing period, or a leading
/// "Score:" prefix. Anything that doesn't parse as a finite `[0,1]` float
/// returns [`OracleError::Decode`].
fn parse_score(raw: &str) -> Result<f64> {
    let cleaned = raw
        .trim()
        .trim_start_matches("Score:")
        .trim_start_matches("score:")
        .trim()
        .trim_end_matches('.')
        .trim();
    let value: f64 = cleaned.parse().map_err(|_| OracleError::Decode {
        reason: format!("could not parse `{cleaned}` as f64"),
    })?;
    if !value.is_finite() || !(0.0..=1.0).contains(&value) {
        return Err(OracleError::Decode {
            reason: format!("score {value} out of [0,1] range"),
        }
        .into());
    }
    Ok(value)
}

#[cfg(test)]
#[path = "judge_tests.rs"]
mod tests;
