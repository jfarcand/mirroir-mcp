// ABOUTME: LLM judge oracle — scores response text against expectation using a profile registry.
// ABOUTME: OpenAI-compatible chat completions API; works with OpenAI, Anthropic-compatible, vLLM, Ollama.

use std::env;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tracing::{debug, info};

use crate::error::Result;
use crate::oracle::error::OracleError;
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
/// * [`crate::error::RunnerError::TlsConfig`] when the shared rustls config cannot be built.
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

    let client = tls::client_builder()?
        .timeout(Duration::from_secs(u64::from(profile.timeout_s)))
        .user_agent(format!("mirroir-run/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|source| OracleError::Transport {
            url: profile.base_url.clone(),
            source,
        })?;
    let req = ChatRequest {
        model: profile.model.as_str(),
        messages: vec![ChatMessage {
            role: "user",
            content: prompt,
        }],
        temperature: 0.0,
    };
    let mut request = client.post(profile.base_url.as_str()).json(&req);
    if let Some(key) = api_key {
        request = request.bearer_auth(key);
    }
    let response = request
        .send()
        .await
        .map_err(|source| OracleError::Transport {
            url: profile.base_url.clone(),
            source,
        })?;
    let body: ChatResponse = response
        .json()
        .await
        .map_err(|source| OracleError::Transport {
            url: profile.base_url.clone(),
            source,
        })?;
    let Some(choice) = body.choices.into_iter().next() else {
        return Err(OracleError::Decode {
            reason: "no choices in response".to_owned(),
        }
        .into());
    };
    let raw = choice.message.content;
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

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    temperature: f64,
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'a str,
    content: String,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatChoiceMessage,
}

#[derive(Deserialize)]
struct ChatChoiceMessage {
    content: String,
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;
    use std::sync::Arc;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::sync::Mutex;
    use tokio::task::JoinHandle;

    use super::*;
    use crate::error::RunnerError;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    /// Spin a stub HTTP server that returns the canned response body for the
    /// next connection. Returns `(port, JoinHandle)`.
    async fn stub_server(
        canned_json: &'static str,
    ) -> StdResult<(u16, JoinHandle<()>), Box<dyn StdError>> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            canned_json.len(),
            canned_json
        );
        let response = Arc::new(Mutex::new(response));
        let handle = tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = [0u8; 8192];
                let _ = sock.read(&mut buf).await;
                let resp = response.lock().await;
                let _ = sock.write_all(resp.as_bytes()).await;
                let _ = sock.shutdown().await;
            }
        });
        Ok((port, handle))
    }

    fn judge_args(profile: &str) -> JudgeArgs {
        JudgeArgs {
            profile: profile.to_owned(),
            user_prompt_template_hash: user_prompt_template_hash(),
            response_selector: "[data-test=reply]".to_owned(),
            pass_threshold: 0.8,
            pass_threshold_tolerance: Some(0.05),
            expected_signal: Some("response correctly summarises the topic".to_owned()),
            response_drift: None,
            response_text: None,
            response_file: None,
            drift_baseline_file: None,
        }
    }

    fn stub_profile(name: &str, base_url: &str) -> JudgeProfile {
        JudgeProfile {
            name: name.to_owned(),
            base_url: base_url.to_owned(),
            model: "stub".to_owned(),
            api_key_env: None,
            timeout_s: 5,
        }
    }

    #[tokio::test]
    async fn run_judge_extracts_score_from_response() -> TestResult {
        let canned = r#"{"choices":[{"message":{"content":"0.95"}}]}"#;
        let (port, server) = stub_server(canned).await?;
        let base_url: &'static str =
            Box::leak(format!("http://127.0.0.1:{port}/v1/chat/completions").into_boxed_str());
        let registry = JudgeRegistry::from_profiles(vec![stub_profile("stub", base_url)]);
        let outcome = run_judge(&registry, &judge_args("stub"), "Some response").await?;
        if (outcome.score - 0.95).abs() > 1e-9 {
            return Err(format!("wrong score: {}", outcome.score).into());
        }
        server.await?;
        Ok(())
    }

    #[tokio::test]
    async fn run_judge_tolerates_surrounding_whitespace_and_period() -> TestResult {
        let canned = r#"{"choices":[{"message":{"content":"  0.7.  "}}]}"#;
        let (port, server) = stub_server(canned).await?;
        let base_url: &'static str =
            Box::leak(format!("http://127.0.0.1:{port}/v1/chat/completions").into_boxed_str());
        let registry = JudgeRegistry::from_profiles(vec![stub_profile("stub", base_url)]);
        let outcome = run_judge(&registry, &judge_args("stub"), "x").await?;
        if (outcome.score - 0.7).abs() > 1e-9 {
            return Err(format!("wrong score: {}", outcome.score).into());
        }
        server.await?;
        Ok(())
    }

    #[tokio::test]
    async fn run_judge_returns_decode_error_for_bad_score() -> TestResult {
        let canned = r#"{"choices":[{"message":{"content":"definitely not a number"}}]}"#;
        let (port, server) = stub_server(canned).await?;
        let base_url: &'static str =
            Box::leak(format!("http://127.0.0.1:{port}/v1/chat/completions").into_boxed_str());
        let registry = JudgeRegistry::from_profiles(vec![stub_profile("stub", base_url)]);
        let res = run_judge(&registry, &judge_args("stub"), "x").await;
        if !matches!(res, Err(RunnerError::Oracle(OracleError::Decode { .. }))) {
            return Err(format!("expected a decode error, got {res:?}").into());
        }
        server.await?;
        Ok(())
    }

    #[tokio::test]
    async fn run_judge_unknown_profile() -> TestResult {
        let registry = JudgeRegistry::default();
        let res = run_judge(&registry, &judge_args("does-not-exist"), "x").await;
        if !matches!(
            res,
            Err(RunnerError::Oracle(OracleError::UnknownProfile { .. }))
        ) {
            return Err(format!("expected an unknown-profile error, got {res:?}").into());
        }
        Ok(())
    }

    #[test]
    fn enforce_threshold_passes_within_tolerance() -> TestResult {
        let args = JudgeArgs {
            pass_threshold: 0.9,
            pass_threshold_tolerance: Some(0.05),
            ..judge_args("stub")
        };
        let outcome = JudgeOutcome {
            score: 0.86,
            raw: "0.86".to_owned(),
        };
        enforce_threshold("stub", &args, &outcome)?;
        Ok(())
    }

    #[test]
    fn enforce_threshold_fails_below_tolerance() -> TestResult {
        let args = JudgeArgs {
            pass_threshold: 0.9,
            pass_threshold_tolerance: Some(0.05),
            ..judge_args("stub")
        };
        let outcome = JudgeOutcome {
            score: 0.5,
            raw: "0.5".to_owned(),
        };
        let res = enforce_threshold("stub", &args, &outcome);
        let Err(RunnerError::Oracle(OracleError::BelowThreshold {
            score, threshold, ..
        })) = res
        else {
            return Err(format!("expected a below-threshold error, got {res:?}").into());
        };
        if (score - 0.5).abs() > 1e-9 || (threshold - 0.85).abs() > 1e-9 {
            return Err(format!("wrong values: score={score} threshold={threshold}").into());
        }
        Ok(())
    }

    #[test]
    fn parse_score_rejects_out_of_range() -> TestResult {
        let res = parse_score("1.5");
        if !matches!(res, Err(RunnerError::Oracle(OracleError::Decode { .. }))) {
            return Err(format!("expected a decode error, got {res:?}").into());
        }
        Ok(())
    }

    #[tokio::test]
    async fn run_judge_rejects_template_hash_mismatch() -> TestResult {
        let registry = JudgeRegistry::default();
        let mut args = judge_args("fast-ci");
        args.user_prompt_template_hash = "sha256:stale-pinned-value".to_owned();
        let res = run_judge(&registry, &args, "x").await;
        if !matches!(
            res,
            Err(RunnerError::Oracle(OracleError::TemplateMismatch { .. }))
        ) {
            return Err(format!("expected a template-mismatch error, got {res:?}").into());
        }
        Ok(())
    }

    #[test]
    fn template_hash_is_stable() {
        // Guards the pinned hash baked into shipped sample scenarios. If the
        // oracle prompt changes, update this constant AND every scenario's
        // judge.user_prompt_template_hash in lockstep.
        assert_eq!(
            user_prompt_template_hash(),
            "sha256:2fd94adeba57835b2267269c672245aeb82c450908f866bd4c887da010602834",
            "template hash drifted — re-pin sample scenarios"
        );
    }
}
