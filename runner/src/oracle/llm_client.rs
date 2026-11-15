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
// ABOUTME: One LlmClient trait for the judge, with native OpenAI chat-completions, Anthropic Messages and Ollama chat clients.
// ABOUTME: A profile's api_target picks the client; each sends the pinned system prompt and the user prompt, and returns the reply text.

use std::future::Future;

use reqwest::{Client, RequestBuilder, Response};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::Result;
use crate::oracle::error::OracleError;

/// The API version the Anthropic client sends. Sampling parameters are not
/// accepted on it, so the Anthropic request carries none.
pub const ANTHROPIC_VERSION: &str = "2026-10-21";

/// Output budget for one judge reply: a score of a few characters.
pub const JUDGE_MAX_TOKENS: u32 = 256;

/// Which wire protocol a judge profile speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ApiTarget {
    /// Chat completions (`/v1/chat/completions`), and any server that speaks it.
    #[default]
    OpenAi,
    /// Anthropic Messages (`/v1/messages`).
    Anthropic,
    /// Ollama's native chat endpoint (`/api/chat`).
    Ollama,
}

/// A chat model the judge can ask for a score.
pub trait LlmClient {
    /// Send `system` and `user` and return the model's reply text.
    ///
    /// # Errors
    ///
    /// * [`OracleError::Transport`] when the request cannot be sent or the body read.
    /// * [`OracleError::Decode`] when the provider answers with an error status,
    ///   a refusal, or a body with no reply text.
    fn complete(&self, system: &str, user: &str) -> impl Future<Output = Result<String>> + Send;
}

/// Where and how one client reaches its provider.
#[derive(Debug, Clone)]
pub struct Endpoint {
    /// The shared HTTP client, with the profile's timeout.
    pub http: Client,
    /// The full URL requests go to.
    pub url: String,
    /// The model identifier the provider expects.
    pub model: String,
    /// The API key, when the provider authenticates.
    pub api_key: Option<String>,
}

impl Endpoint {
    async fn send(&self, request: RequestBuilder) -> Result<Value> {
        let response = request
            .send()
            .await
            .map_err(|source| OracleError::Transport {
                url: self.url.clone(),
                source,
            })?;
        self.read(response).await
    }

    async fn read(&self, response: Response) -> Result<Value> {
        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|source| OracleError::Transport {
                url: self.url.clone(),
                source,
            })?;
        if !status.is_success() {
            return Err(OracleError::Decode {
                reason: format!("{} answered {status}: {body}", self.url),
            }
            .into());
        }
        serde_json::from_str(&body).map_err(|source| {
            OracleError::Decode {
                reason: format!("{} sent a body that is not JSON: {source}", self.url),
            }
            .into()
        })
    }
}

fn missing(field: &str, body: &Value) -> OracleError {
    OracleError::Decode {
        reason: format!("reply has no {field}: {body}"),
    }
}

/// The chat-completions API (`/v1/chat/completions`).
#[derive(Debug, Clone)]
pub struct OpenAiClient(pub Endpoint);

/// Anthropic Messages.
#[derive(Debug, Clone)]
pub struct AnthropicClient(pub Endpoint);

/// Ollama's native chat endpoint.
#[derive(Debug, Clone)]
pub struct OllamaClient(pub Endpoint);

#[derive(Serialize)]
struct Message<'a> {
    role: &'a str,
    content: &'a str,
}

impl LlmClient for OpenAiClient {
    async fn complete(&self, system: &str, user: &str) -> Result<String> {
        let endpoint = &self.0;
        let body = json!({
            "model": endpoint.model,
            "messages": [Message { role: "system", content: system }, Message { role: "user", content: user }],
            "temperature": 0.0,
        });
        let mut request = endpoint.http.post(&endpoint.url).json(&body);
        if let Some(key) = &endpoint.api_key {
            request = request.bearer_auth(key);
        }
        let reply = endpoint.send(request).await?;
        reply["choices"][0]["message"]["content"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| missing("choices[0].message.content", &reply).into())
    }
}

impl LlmClient for AnthropicClient {
    async fn complete(&self, system: &str, user: &str) -> Result<String> {
        let endpoint = &self.0;
        let body = json!({
            "model": endpoint.model,
            "max_tokens": JUDGE_MAX_TOKENS,
            "system": system,
            "messages": [Message { role: "user", content: user }],
        });
        let mut request = endpoint
            .http
            .post(&endpoint.url)
            .header("anthropic-version", ANTHROPIC_VERSION)
            .json(&body);
        if let Some(key) = &endpoint.api_key {
            request = request.header("x-api-key", key);
        }
        let reply = endpoint.send(request).await?;
        if reply["stop_reason"] == "refusal" {
            return Err(OracleError::Decode {
                reason: format!("the model declined to score: {}", reply["stop_details"]),
            }
            .into());
        }
        let text: String = reply["content"]
            .as_array()
            .ok_or_else(|| missing("content", &reply))?
            .iter()
            .filter(|block| block["type"] == "text")
            .filter_map(|block| block["text"].as_str())
            .collect();
        if text.is_empty() {
            return Err(missing("text block", &reply).into());
        }
        Ok(text)
    }
}

impl LlmClient for OllamaClient {
    async fn complete(&self, system: &str, user: &str) -> Result<String> {
        let endpoint = &self.0;
        let body = json!({
            "model": endpoint.model,
            "messages": [Message { role: "system", content: system }, Message { role: "user", content: user }],
            "stream": false,
            "options": { "temperature": 0.0 },
        });
        let reply = endpoint
            .send(endpoint.http.post(&endpoint.url).json(&body))
            .await?;
        reply["message"]["content"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| missing("message.content", &reply).into())
    }
}
