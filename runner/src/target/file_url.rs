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
// ABOUTME: `file://` URLs in `http:` steps — read a local file and assert on its contents.
// ABOUTME: Filesystem assertions share the http step's `expect_body_contains` check; status and verbs other than GET do not apply.

use std::path::PathBuf;

use reqwest::Url;
use tokio::fs;
use tracing::info;

use crate::error::Result;
use crate::http_error::HttpError;
use crate::parser::step::{HttpArgs, HttpMethod};
use crate::target::http::check_body;

/// URL scheme an `http:` step reads from the local filesystem.
pub const FILE_SCHEME: &str = "file";

/// Whether `url` names a local file rather than a server.
#[must_use]
pub fn is_file_url(url: &str) -> bool {
    Url::parse(url).is_ok_and(|parsed| parsed.scheme() == FILE_SCHEME)
}

/// Read the file `args.url` names and check `expect_body_contains` against it.
///
/// # Errors
///
/// * [`HttpError::FileMethod`] when the step uses a verb other than `GET`.
/// * [`HttpError::FileStatus`] when the step declares `expect_status`, which a file has no answer for.
/// * [`HttpError::FileUrl`] when the URL does not name a local path.
/// * [`HttpError::FileRead`] when the file is missing or unreadable.
/// * [`HttpError::BodyMismatch`] when a required substring is absent.
pub async fn dispatch(args: &HttpArgs) -> Result<()> {
    if args.method != HttpMethod::Get {
        return Err(HttpError::FileMethod {
            url: args.url.clone(),
            method: args.method,
        }
        .into());
    }
    if let Some(expected) = args.expect_status {
        return Err(HttpError::FileStatus {
            url: args.url.clone(),
            expected,
        }
        .into());
    }
    let path = local_path(&args.url)?;
    let body = fs::read_to_string(&path)
        .await
        .map_err(|source| HttpError::FileRead {
            path: path.clone(),
            source,
        })?;
    check_body(&args.url, &body, &args.expect_body_contains)?;
    info!(path = %path.display(), bytes = body.len(), substrings = args.expect_body_contains.len(), "file probe ok");
    Ok(())
}

fn local_path(url: &str) -> Result<PathBuf> {
    Url::parse(url)
        .ok()
        .and_then(|parsed| parsed.to_file_path().ok())
        .ok_or_else(|| {
            HttpError::FileUrl {
                url: url.to_owned(),
            }
            .into()
        })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use tempfile::TempDir;

    use super::*;
    use crate::error::RunnerError;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn args(url: String, contains: &[&str]) -> HttpArgs {
        HttpArgs {
            method: HttpMethod::Get,
            url,
            expect_status: None,
            expect_body_contains: contains.iter().map(|s| (*s).to_owned()).collect(),
            timeout_s: None,
        }
    }

    async fn file_with(contents: &str) -> StdResult<(TempDir, String), Box<dyn StdError>> {
        let dir = TempDir::new()?;
        let path = dir.path().join("report has spaces.txt");
        fs::write(&path, contents).await?;
        let url = Url::from_file_path(&path).map_err(|()| "temp path is not absolute")?;
        Ok((dir, url.to_string()))
    }

    #[test]
    fn only_file_urls_are_file_urls() {
        assert!(is_file_url("file:///tmp/report.txt"));
        assert!(!is_file_url("http://127.0.0.1/"));
        assert!(!is_file_url("not a url"));
    }

    #[tokio::test]
    async fn a_file_with_every_substring_passes() -> TestResult {
        let (_dir, url) = file_with("exported 12 rows\nstatus: done\n").await?;
        dispatch(&args(url, &["12 rows", "status: done"])).await?;
        Ok(())
    }

    #[tokio::test]
    async fn a_missing_substring_is_a_body_mismatch() -> TestResult {
        let (_dir, url) = file_with("status: running").await?;
        let res = dispatch(&args(url, &["status: done"])).await;
        let Err(RunnerError::Http(HttpError::BodyMismatch { expected, .. })) = res else {
            return Err(format!("expected BodyMismatch, got {res:?}").into());
        };
        assert_eq!(expected, "status: done");
        Ok(())
    }

    #[tokio::test]
    async fn a_missing_file_names_its_path() -> TestResult {
        let dir = TempDir::new()?;
        let path = dir.path().join("absent.txt");
        let url = Url::from_file_path(&path).map_err(|()| "temp path is not absolute")?;
        let res = dispatch(&args(url.to_string(), &["x"])).await;
        let Err(RunnerError::Http(HttpError::FileRead { path: reported, .. })) = res else {
            return Err(format!("expected FileRead, got {res:?}").into());
        };
        assert_eq!(reported, path);
        Ok(())
    }

    #[tokio::test]
    async fn expect_status_on_a_file_is_refused() -> TestResult {
        let (_dir, url) = file_with("ok").await?;
        let res = dispatch(&HttpArgs {
            expect_status: Some(200),
            ..args(url, &[])
        })
        .await;
        assert!(
            matches!(
                res,
                Err(RunnerError::Http(HttpError::FileStatus {
                    expected: 200,
                    ..
                }))
            ),
            "{res:?}"
        );
        Ok(())
    }

    #[tokio::test]
    async fn a_verb_other_than_get_is_refused() -> TestResult {
        let (_dir, url) = file_with("ok").await?;
        let res = dispatch(&HttpArgs {
            method: HttpMethod::Post,
            ..args(url, &[])
        })
        .await;
        assert!(
            matches!(
                res,
                Err(RunnerError::Http(HttpError::FileMethod {
                    method: HttpMethod::Post,
                    ..
                }))
            ),
            "{res:?}"
        );
        Ok(())
    }

    #[tokio::test]
    async fn a_file_url_with_a_remote_host_is_refused() -> TestResult {
        let res = dispatch(&args("file://example.com/etc/hosts".to_owned(), &[])).await;
        assert!(
            matches!(res, Err(RunnerError::Http(HttpError::FileUrl { .. }))),
            "{res:?}"
        );
        Ok(())
    }
}
