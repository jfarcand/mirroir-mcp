// ABOUTME: HTTP target — REST probes with status + body substring assertions.
// ABOUTME: Wraps reqwest::Client; one client per scenario run, reused across http: steps.

use std::time::Duration;

use reqwest::{Client, Method};
use tracing::{debug, info};

use crate::error::{Result, RunnerError};
use crate::parser::step::{HttpArgs, HttpMethod};
use crate::tls;

/// Default per-request timeout when `http: { timeout_s: ... }` is omitted.
const HTTP_DEFAULT_TIMEOUT_S: u32 = 30;

/// Per-scenario HTTP probe client.
///
/// Wraps a single `reqwest::Client` so steps in the same scenario share the
/// connection pool. Construct once via [`Self::new`] at scenario start.
pub struct HttpClient {
    client: Client,
}

impl HttpClient {
    /// Build a fresh client with a `mirroir-run/<version>` user agent.
    ///
    /// # Errors
    ///
    /// * [`RunnerError::TlsConfig`] if the shared rustls config cannot be built.
    /// * [`RunnerError::HttpClient`] if the underlying `reqwest` build fails —
    ///   e.g. TLS backend init refused.
    pub fn new() -> Result<Self> {
        let user_agent = format!("mirroir-run/{}", env!("CARGO_PKG_VERSION"));
        let client = tls::client_builder()?
            .user_agent(user_agent)
            .build()
            .map_err(|source| RunnerError::HttpClient { source })?;
        Ok(Self { client })
    }

    /// Implements the `http:` step.
    ///
    /// Sends the configured request, validates `expect_status` if set, and
    /// validates every substring in `expect_body_contains` (skipping the
    /// response body read entirely when the list is empty — a HEAD probe
    /// shouldn't require a body).
    ///
    /// # Errors
    ///
    /// * [`RunnerError::HttpRequest`] when `send()` fails (DNS, refused, timeout).
    /// * [`RunnerError::HttpStatusMismatch`] when `expect_status` disagrees with the response.
    /// * [`RunnerError::HttpBodyRead`] when decoding the response body fails.
    /// * [`RunnerError::HttpBodyMismatch`] when a required substring is absent.
    pub async fn dispatch(&self, args: &HttpArgs) -> Result<()> {
        let method = map_method(args.method);
        let timeout =
            Duration::from_secs(u64::from(args.timeout_s.unwrap_or(HTTP_DEFAULT_TIMEOUT_S)));
        debug!(method = %method, url = %args.url, timeout_s = ?args.timeout_s, "issuing HTTP probe");

        let response = self
            .client
            .request(method, &args.url)
            .timeout(timeout)
            .send()
            .await
            .map_err(|source| RunnerError::HttpRequest {
                url: args.url.clone(),
                source,
            })?;

        let status = response.status().as_u16();
        if let Some(expected) = args.expect_status
            && status != expected
        {
            return Err(RunnerError::HttpStatusMismatch {
                url: args.url.clone(),
                expected,
                actual: status,
            });
        }

        if args.expect_body_contains.is_empty() {
            info!(url = %args.url, status, "HTTP probe ok (status-only)");
            return Ok(());
        }

        let body = response
            .text()
            .await
            .map_err(|source| RunnerError::HttpBodyRead {
                url: args.url.clone(),
                source,
            })?;

        for substring in &args.expect_body_contains {
            if !body.contains(substring) {
                return Err(RunnerError::HttpBodyMismatch {
                    url: args.url.clone(),
                    expected: substring.clone(),
                });
            }
        }

        info!(
            url = %args.url,
            status,
            bytes = body.len(),
            substrings = args.expect_body_contains.len(),
            "HTTP probe ok"
        );
        Ok(())
    }
}

fn map_method(method: HttpMethod) -> Method {
    match method {
        HttpMethod::Get => Method::GET,
        HttpMethod::Post => Method::POST,
        HttpMethod::Put => Method::PUT,
        HttpMethod::Delete => Method::DELETE,
        HttpMethod::Head => Method::HEAD,
        HttpMethod::Patch => Method::PATCH,
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::io;
    use std::result::Result as StdResult;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::task::JoinHandle;

    use super::*;
    use crate::target::dark_port::dark_port;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    /// Spin a one-shot TCP responder that accepts the next connection, drains
    /// the request, writes `response` raw, and shuts down. Returns the bound
    /// port and the spawned task's handle.
    async fn start_test_server(
        response: &'static str,
    ) -> StdResult<(u16, JoinHandle<()>), Box<dyn StdError>> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let handle = tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let _ = sock.read(&mut buf).await;
                let _ = sock.write_all(response.as_bytes()).await;
                let _ = sock.shutdown().await;
            }
        });
        Ok((port, handle))
    }

    fn args(method: HttpMethod, url: String) -> HttpArgs {
        HttpArgs {
            method,
            url,
            expect_status: None,
            expect_body_contains: Vec::new(),
            timeout_s: None,
        }
    }

    #[tokio::test]
    async fn get_200_with_status_only_check_succeeds() -> TestResult {
        let (port, server) =
            start_test_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").await?;
        let client = HttpClient::new()?;
        client
            .dispatch(&HttpArgs {
                expect_status: Some(200),
                ..args(HttpMethod::Get, format!("http://127.0.0.1:{port}/"))
            })
            .await?;
        server.await?;
        Ok(())
    }

    #[tokio::test]
    async fn status_mismatch_returns_typed_error() -> TestResult {
        let (port, server) =
            start_test_server("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
                .await?;
        let client = HttpClient::new()?;
        let res = client
            .dispatch(&HttpArgs {
                expect_status: Some(200),
                ..args(HttpMethod::Get, format!("http://127.0.0.1:{port}/"))
            })
            .await;
        let Err(RunnerError::HttpStatusMismatch {
            actual, expected, ..
        }) = res
        else {
            return Err(format!("expected HttpStatusMismatch, got {res:?}").into());
        };
        if actual != 503 || expected != 200 {
            return Err(format!("wrong codes: actual={actual} expected={expected}").into());
        }
        server.await?;
        Ok(())
    }

    #[tokio::test]
    async fn body_contains_substrings_succeeds() -> TestResult {
        let body = "{\"transports\":[\"webtransport\",\"websocket\"]}";
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let leaked: &'static str = Box::leak(response.into_boxed_str());
        let (port, server) = start_test_server(leaked).await?;
        let client = HttpClient::new()?;
        client
            .dispatch(&HttpArgs {
                expect_status: Some(200),
                expect_body_contains: vec!["webtransport".to_owned(), "websocket".to_owned()],
                ..args(HttpMethod::Get, format!("http://127.0.0.1:{port}/"))
            })
            .await?;
        server.await?;
        Ok(())
    }

    #[tokio::test]
    async fn missing_substring_returns_body_mismatch() -> TestResult {
        let (port, server) =
            start_test_server("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello").await?;
        let client = HttpClient::new()?;
        let res = client
            .dispatch(&HttpArgs {
                expect_body_contains: vec!["goodbye".to_owned()],
                ..args(HttpMethod::Get, format!("http://127.0.0.1:{port}/"))
            })
            .await;
        let Err(RunnerError::HttpBodyMismatch { expected, .. }) = res else {
            return Err(format!("expected HttpBodyMismatch, got {res:?}").into());
        };
        if expected != "goodbye" {
            return Err(format!("wrong substring `{expected}`").into());
        }
        server.await?;
        Ok(())
    }

    #[tokio::test]
    async fn unreachable_host_returns_http_request_error() -> TestResult {
        let client = HttpClient::new()?;
        // The OS picks this port and it is released before the request, so
        // reqwest gets connection refused. A fixed port would instead assert
        // against whatever that machine happens to have bound there.
        let port = dark_port().await?;
        let res = client
            .dispatch(&args(HttpMethod::Get, format!("http://127.0.0.1:{port}/")))
            .await;
        if !matches!(res, Err(RunnerError::HttpRequest { .. })) {
            return Err(format!("expected HttpRequest error, got {res:?}").into());
        }
        Ok(())
    }

    #[tokio::test]
    async fn method_routing_covers_patch() -> TestResult {
        // Capture the request line via a server that records what it received.
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let handle: JoinHandle<StdResult<Vec<u8>, io::Error>> = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await?;
            let mut buf = vec![0u8; 4096];
            let n = sock.read(&mut buf).await?;
            buf.truncate(n);
            sock.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                .await?;
            sock.shutdown().await?;
            Ok(buf)
        });
        let client = HttpClient::new()?;
        client
            .dispatch(&HttpArgs {
                expect_status: Some(200),
                ..args(HttpMethod::Patch, format!("http://127.0.0.1:{port}/"))
            })
            .await?;
        let captured = handle.await??;
        let request = String::from_utf8_lossy(&captured);
        if !request.starts_with("PATCH ") {
            return Err(format!("expected PATCH request line, got `{request:.40}`").into());
        }
        Ok(())
    }
}
