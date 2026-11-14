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
// ABOUTME: A one-shot OpenAI-compatible chat-completions stub on loopback, for judge post-hook tests.
// ABOUTME: Hands the test back the exact request body the runner sent, so the prompt can be asserted.

use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::sync::mpsc::{self, Receiver};
use std::thread;

/// A stub oracle listening on an ephemeral loopback port.
pub struct StubOracle {
    /// Port the runner should be pointed at.
    pub port: u16,
    /// Receives the full HTTP request the runner sent, once it arrives.
    pub request: Receiver<String>,
}

/// Serve exactly one chat-completions request, replying with `score` as the
/// assistant message content.
///
/// # Errors
///
/// Returns the failure text when the loopback socket can't be bound.
pub fn stub_oracle(score: &str) -> Result<StubOracle, String> {
    let listener =
        TcpListener::bind("127.0.0.1:0").map_err(|e| format!("bind stub oracle: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("read stub oracle port: {e}"))?
        .port();
    let (tx, request) = mpsc::channel();
    let body = format!("{{\"choices\":[{{\"message\":{{\"content\":\"{score}\"}}}}]}}");

    thread::spawn(move || {
        let Ok((mut stream, _)) = listener.accept() else {
            return;
        };
        let mut raw: Vec<u8> = Vec::new();
        let mut chunk = [0_u8; 4096];
        loop {
            let Ok(read) = stream.read(&mut chunk) else {
                return;
            };
            if read == 0 {
                break;
            }
            raw.extend_from_slice(&chunk[..read]);
            if request_is_complete(&raw) {
                break;
            }
        }
        let _ = tx.send(String::from_utf8_lossy(&raw).into_owned());
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes());
        let _ = stream.flush();
    });

    Ok(StubOracle { port, request })
}

/// True once `raw` holds the headers plus the whole `Content-Length` body.
fn request_is_complete(raw: &[u8]) -> bool {
    let Some(header_end) = find_header_end(raw) else {
        return false;
    };
    let headers = String::from_utf8_lossy(&raw[..header_end]);
    let declared = headers.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if name.eq_ignore_ascii_case("content-length") {
            value.trim().parse::<usize>().ok()
        } else {
            None
        }
    });
    declared.is_none_or(|len| raw.len() >= header_end + len)
}

fn find_header_end(raw: &[u8]) -> Option<usize> {
    raw.windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|start| start + 4)
}
