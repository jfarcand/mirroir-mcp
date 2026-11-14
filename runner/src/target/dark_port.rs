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
// ABOUTME: Test support — hands out a loopback TCP port the OS confirmed nothing is listening on.
// ABOUTME: Lets the port tests assert against a port proven dark rather than one assumed free.

use std::result::Result as StdResult;

use tokio::net::{TcpListener, TcpStream};

/// How many ports to try before giving up.
///
/// An attempt is spent only when another process claims the released port in
/// the window between the release and the probe, so needing more than one or
/// two means the machine is churning through its ephemeral range.
const ATTEMPTS: usize = 16;

/// Yield a loopback TCP port nothing is listening on.
///
/// The OS picks it: binding `127.0.0.1:0` reserves a port, reading the local
/// address back names it, and dropping the listener releases it. A test must
/// never assume some fixed number is free — a machine is free to run a service
/// on any port, low ones included, and a test that assumes otherwise fails on
/// the machine that does.
///
/// Releasing the port opens a window in which another process could claim it,
/// so both loopback families are probed before the port is handed out and the
/// search restarts if either answered. The caller gets a port that refused a
/// connection a moment ago, which is the strongest guarantee available without
/// holding the port open — and holding it open is precisely what the caller
/// needs it not to be.
///
/// # Errors
///
/// A message naming the failure when a port cannot be reserved, when its
/// address cannot be read back, or when [`ATTEMPTS`] ports were each claimed
/// between release and probe.
pub async fn dark_port() -> StdResult<u16, String> {
    for _ in 0..ATTEMPTS {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|source| format!("reserve a loopback port: {source}"))?;
        let port = listener
            .local_addr()
            .map_err(|source| format!("read back the reserved port: {source}"))?
            .port();
        drop(listener);
        if TcpStream::connect(("127.0.0.1", port)).await.is_err()
            && TcpStream::connect(("::1", port)).await.is_err()
        {
            return Ok(port);
        }
    }
    Err(format!(
        "no dark loopback port after {ATTEMPTS} attempts: every released port was claimed before it could be probed"
    ))
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use tokio::net::TcpStream;

    use super::dark_port;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    /// The contract the three port tests lean on: what comes back refuses a
    /// connection. A helper that handed out a live port would turn those tests
    /// green for the wrong reason.
    #[tokio::test]
    async fn the_port_handed_out_refuses_a_connection() -> TestResult {
        let port = dark_port().await?;
        if TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            return Err(format!("something is listening on the handed-out port {port}").into());
        }
        Ok(())
    }
}
