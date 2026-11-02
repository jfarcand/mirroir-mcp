// ABOUTME: TCP port-readiness polling for the process target's `wait_port:` step.
// ABOUTME: Probes both IPv4 and IPv6 loopback so dev servers binding either family are seen.

use std::time::Duration;

use tokio::net::TcpStream;
use tokio::time::{Instant, sleep};

use crate::error::{Result, RunnerError};
use crate::parser::step::{PortState, WaitPortArgs};

/// Implements the `wait_port:` step. Polls both the IPv4 (`127.0.0.1`) and
/// IPv6 (`[::1]`) loopback addresses for `<port>` at 100ms intervals up to
/// `args.timeout_s`. Checking both matters because dev servers differ in
/// which loopback they bind — Vite, for example, binds `[::1]` only when
/// told to listen on `localhost`, so an IPv4-only probe would never see it.
/// `expect: open` passes once either address connects; `expect: closed`
/// passes once both refuse.
///
/// # Errors
///
/// [`RunnerError::WaitPortTimeout`] when the expected state is not
/// observed before the deadline.
pub async fn wait_for_port(args: &WaitPortArgs) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(u64::from(args.timeout_s));
    let v4 = format!("127.0.0.1:{}", args.port);
    let v6 = format!("[::1]:{}", args.port);
    loop {
        let open_now =
            TcpStream::connect(&v4).await.is_ok() || TcpStream::connect(&v6).await.is_ok();
        let satisfied = match args.expect {
            PortState::Open => open_now,
            PortState::Closed => !open_now,
        };
        if satisfied {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(RunnerError::WaitPortTimeout {
                port: args.port,
                timeout_s: args.timeout_s,
                expect: match args.expect {
                    PortState::Open => "open",
                    PortState::Closed => "closed",
                },
            });
        }
        sleep(Duration::from_millis(100)).await;
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::net::SocketAddr;
    use std::result::Result as StdResult;

    use tokio::net::TcpListener;

    use super::*;
    use crate::target::dark_port::dark_port;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    #[tokio::test]
    async fn wait_port_open_resolves_for_live_listener() -> TestResult {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let SocketAddr::V4(addr) = listener.local_addr()? else {
            return Err("expected IPv4 listener".into());
        };
        wait_for_port(&WaitPortArgs {
            port: addr.port(),
            timeout_s: 2,
            expect: PortState::Open,
        })
        .await?;
        Ok(())
    }

    #[tokio::test]
    async fn wait_port_open_resolves_for_ipv6_only_listener() -> TestResult {
        // Vite binds [::1] (IPv6 loopback) when listening on "localhost"; an
        // IPv4-only probe would miss it. wait_port must see the IPv6 listener.
        // Some sandboxes (default Docker networks) have no IPv6 loopback, so the
        // listener bind itself fails — skip there rather than report a false
        // failure; environments with IPv6 (CI runners, macOS) exercise it fully.
        let Ok(listener) = TcpListener::bind("[::1]:0").await else {
            eprintln!("skipping: no IPv6 loopback available in this environment");
            return Ok(());
        };
        let SocketAddr::V6(addr) = listener.local_addr()? else {
            return Err("expected IPv6 listener".into());
        };
        wait_for_port(&WaitPortArgs {
            port: addr.port(),
            timeout_s: 2,
            expect: PortState::Open,
        })
        .await?;
        Ok(())
    }

    #[tokio::test]
    async fn wait_port_open_times_out_when_port_dark() -> TestResult {
        // A port the OS reserved and released: nothing is listening on it, so
        // the poll never sees `open` and runs out its budget.
        let port = dark_port().await?;
        let res = wait_for_port(&WaitPortArgs {
            port,
            timeout_s: 1,
            expect: PortState::Open,
        })
        .await;
        if !matches!(res, Err(RunnerError::WaitPortTimeout { .. })) {
            return Err(format!("expected WaitPortTimeout, got {res:?}").into());
        }
        Ok(())
    }

    #[tokio::test]
    async fn wait_port_closed_resolves_when_nothing_listens() -> TestResult {
        // Both loopback families refuse this port, which is exactly what
        // `expect: closed` waits for.
        let port = dark_port().await?;
        wait_for_port(&WaitPortArgs {
            port,
            timeout_s: 2,
            expect: PortState::Closed,
        })
        .await?;
        Ok(())
    }
}
