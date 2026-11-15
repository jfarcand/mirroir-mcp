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
// ABOUTME: Tests for the judge call: prompt template pin, score parsing, thresholds and the request it sends.
// ABOUTME: A loopback stub plays the chat-completions endpoint and hands back the request it received.

use std::error::Error as StdError;
use std::result::Result as StdResult;
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

use super::*;
use crate::error::RunnerError;
use crate::oracle::judge_profiles::SystemPrompt;
use crate::oracle::llm_client::{ANTHROPIC_VERSION, ApiTarget, JUDGE_MAX_TOKENS};

type TestResult = StdResult<(), Box<dyn StdError>>;

/// Spin a stub HTTP server that returns the canned response body for the
/// next connection. Returns `(port, JoinHandle)`.
async fn stub_server(
    canned_json: &'static str,
) -> StdResult<(u16, JoinHandle<Vec<u8>>), Box<dyn StdError>> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        canned_json.len(),
        canned_json
    );
    let response = Arc::new(Mutex::new(response));
    let handle = tokio::spawn(async move {
        let mut request = Vec::new();
        if let Ok((mut sock, _)) = listener.accept().await {
            read_request(&mut sock, &mut request).await;
            let resp = response.lock().await;
            let _ = sock.write_all(resp.as_bytes()).await;
            let _ = sock.shutdown().await;
        }
        request
    });
    Ok((port, handle))
}

/// Read one HTTP request: the headers, then as many body bytes as its
/// Content-Length names.
async fn read_request(sock: &mut TcpStream, request: &mut Vec<u8>) {
    let mut buf = [0u8; 8192];
    loop {
        let Ok(n) = sock.read(&mut buf).await else {
            return;
        };
        if n == 0 {
            return;
        }
        request.extend_from_slice(&buf[..n]);
        let text = String::from_utf8_lossy(request);
        let Some(head_end) = text.find("\r\n\r\n") else {
            continue;
        };
        let length = text[..head_end]
            .lines()
            .find_map(|line| {
                line.to_ascii_lowercase()
                    .strip_prefix("content-length:")
                    .map(|v| v.trim().to_owned())
            })
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
        if request.len() >= head_end + 4 + length {
            return;
        }
    }
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
    target_profile(name, base_url, ApiTarget::OpenAi)
}

fn target_profile(name: &str, base_url: &str, api_target: ApiTarget) -> JudgeProfile {
    JudgeProfile {
        name: name.to_owned(),
        base_url: base_url.to_owned(),
        model: "stub".to_owned(),
        api_key_env: None,
        timeout_s: 5,
        api_target,
        system_prompt: SystemPrompt::canonical(),
    }
}

/// Run one judge call against a stub speaking `api_target`, and return the
/// score and the raw request the stub received.
async fn judge_through(
    api_target: ApiTarget,
    canned: &'static str,
) -> StdResult<(f64, String), Box<dyn StdError>> {
    let (port, server) = stub_server(canned).await?;
    let base_url: &'static str =
        Box::leak(format!("http://127.0.0.1:{port}/endpoint").into_boxed_str());
    let registry = JudgeRegistry::from_profiles(vec![target_profile("stub", base_url, api_target)]);
    let outcome = run_judge(&registry, &judge_args("stub"), "Some response").await?;
    Ok((outcome.score, String::from_utf8(server.await?)?))
}

fn request_json(request: &str) -> StdResult<serde_json::Value, Box<dyn StdError>> {
    let body = request
        .split("\r\n\r\n")
        .nth(1)
        .ok_or("request has no body")?;
    Ok(serde_json::from_str(body)?)
}

#[tokio::test]
async fn the_anthropic_client_speaks_the_messages_api() -> TestResult {
    let canned = r#"{"content":[{"type":"text","text":"0.85"}],"stop_reason":"end_turn"}"#;
    let (score, request) = judge_through(ApiTarget::Anthropic, canned).await?;
    assert!((score - 0.85).abs() < 1e-9);
    let lower = request.to_ascii_lowercase();
    assert!(
        lower.contains(&format!("anthropic-version: {ANTHROPIC_VERSION}")),
        "{request}"
    );
    let json = request_json(&request)?;
    assert_eq!(json["system"], SystemPrompt::canonical().text.as_str());
    assert_eq!(json["messages"][0]["role"], "user");
    assert_eq!(json["max_tokens"], JUDGE_MAX_TOKENS);
    assert!(
        json.get("temperature").is_none(),
        "the Messages API version rejects temperature"
    );
    Ok(())
}

#[tokio::test]
async fn an_anthropic_refusal_is_a_decode_error_not_a_score() -> TestResult {
    let canned = r#"{"content":[],"stop_reason":"refusal","stop_details":{"category":"cyber"}}"#;
    match judge_through(ApiTarget::Anthropic, canned).await {
        Err(err) => {
            assert!(err.to_string().contains("declined to score"), "{err}");
            Ok(())
        }
        Ok(score) => Err(format!("a refusal must not score, got {score:?}").into()),
    }
}

#[tokio::test]
async fn the_ollama_client_speaks_native_chat_without_streaming() -> TestResult {
    let canned = r#"{"message":{"role":"assistant","content":"0.6"},"done":true}"#;
    let (score, request) = judge_through(ApiTarget::Ollama, canned).await?;
    assert!((score - 0.6).abs() < 1e-9);
    let json = request_json(&request)?;
    assert_eq!(json["stream"], false);
    assert_eq!(json["messages"][0]["role"], "system");
    assert_eq!(json["messages"][1]["role"], "user");
    Ok(())
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
async fn run_judge_sends_the_profile_system_prompt_before_the_user_prompt() -> TestResult {
    let canned = r#"{"choices":[{"message":{"content":"0.9"}}]}"#;
    let (port, server) = stub_server(canned).await?;
    let base_url: &'static str =
        Box::leak(format!("http://127.0.0.1:{port}/v1/chat/completions").into_boxed_str());
    let registry = JudgeRegistry::from_profiles(vec![stub_profile("stub", base_url)]);
    run_judge(&registry, &judge_args("stub"), "Some response").await?;
    let request = String::from_utf8(server.await?)?;
    let body = request
        .split("\r\n\r\n")
        .nth(1)
        .ok_or("request has no body")?;
    let json: serde_json::Value = serde_json::from_str(body)?;
    let messages = json["messages"].as_array().ok_or("no messages array")?;
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0]["role"], "system");
    assert_eq!(
        messages[0]["content"],
        SystemPrompt::canonical().text.as_str()
    );
    assert_eq!(messages[1]["role"], "user");
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
