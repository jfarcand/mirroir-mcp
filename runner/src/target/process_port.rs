// ABOUTME: TCP port-readiness polling for the process target's `wait_port:` step.
// ABOUTME: Probes both IPv4 and IPv6 loopback so dev servers binding either family are seen.

use std::time::Duration;

use tokio::net::TcpStream;
use tokio::time::{Instant, sleep, timeout};

use crate::error::{Result, RunnerError};
use crate::parser::step::{PortState, WaitPortArgs};

/// The longest one connection attempt may take before it counts as "not
/// open". A SYN the kernel drops instead of refusing — macOS does this for a
/// socket bound but not yet listening — is otherwise retried by the kernel
/// for its full connect timeout (75 s on macOS), so one unlucky probe outlived
/// a 15 s `wait_port` budget. A fresh attempt on the next poll succeeds as
/// soon as the server listens.
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);

/// Poll interval between probes.
const POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Implements the `wait_port:` step. Polls both the IPv4 (`127.0.0.1`) and
/// IPv6 (`[::1]`) loopback addresses for `<port>` at 100ms intervals up to
/// `args.timeout_s`. Checking both matters because dev servers differ in
/// which loopback they bind — Vite, for example, binds `[::1]` only when
/// told to listen on `localhost`, so an IPv4-only probe would never see it.
/// `expect: open` passes once either address connects; `expect: closed`
/// passes once neither does. Each attempt is bounded by [`PROBE_TIMEOUT`] and
/// by the deadline, so the step never runs past its budget by more than one
/// probe.
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
        let open_now = connects(&v4, deadline).await || connects(&v6, deadline).await;
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
        sleep(POLL_INTERVAL).await;
    }
}

/// Whether a connection to `address` completes within [`PROBE_TIMEOUT`],
/// cut short at `deadline`.
async fn connects(address: &str, deadline: Instant) -> bool {
    let budget = PROBE_TIMEOUT.min(deadline.saturating_duration_since(Instant::now()));
    matches!(
        timeout(budget, TcpStream::connect(address)).await,
        Ok(Ok(_))
    )
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

    /// A SYN nobody answers — TEST-NET-1 (RFC 5737) is reserved and routed
    /// nowhere — leaves a bare connect waiting out the kernel's whole connect
    /// timeout. The probe must count it as "not open" within its own bound,
    /// which is what keeps `wait_port` inside its budget when the kernel drops
    /// a loopback SYN the same way.
    #[tokio::test]
    async fn a_probe_whose_syn_goes_unanswered_gives_up_at_its_bound() -> TestResult {
        let deadline = Instant::now() + Duration::from_secs(60);
        let started = Instant::now();
        let connected = timeout(PROBE_TIMEOUT * 4, connects("192.0.2.1:9", deadline))
            .await
            .map_err(|_| "the probe ignored its bound and hung on the unanswered SYN")?;
        assert!(!connected);
        assert!(
            started.elapsed() < PROBE_TIMEOUT * 2,
            "the probe ran {:?}",
            started.elapsed()
        );
        Ok(())
    }

    /// The bound shrinks to what is left of the deadline.
    #[tokio::test]
    async fn a_probe_never_runs_past_the_deadline() -> TestResult {
        let deadline = Instant::now() + Duration::from_millis(50);
        let started = Instant::now();
        assert!(!connects("192.0.2.1:9", deadline).await);
        assert!(
            started.elapsed() < Duration::from_millis(300),
            "the probe ran {:?}",
            started.elapsed()
        );
        Ok(())
    }
}
