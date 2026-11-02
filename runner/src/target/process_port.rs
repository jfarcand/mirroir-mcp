// ABOUTME: TCP port-readiness polling for the process target's `wait_port:` step.
// ABOUTME: Probes both IPv4 and IPv6 loopback so dev servers binding either family are seen.

use std::time::Duration;

use tokio::net::TcpStream;
use tokio::select;
use tokio::task::JoinSet;
use tokio::time::{Instant, sleep, sleep_until, timeout};

use crate::error::{Result, RunnerError};
use crate::parser::step::{PortState, WaitPortArgs};

/// How often a fresh connection attempt starts while earlier ones are still
/// in flight. Attempts overlap rather than being cut short or awaited one at
/// a time: macOS silently drops a SYN sent to a socket that is bound but not
/// yet listening, so that attempt stays pending for the kernel's whole
/// connect timeout (75 s) and only a retransmit — seconds later — notices the
/// listener. Python's `http.server`, for one, binds and then resolves its own
/// name before it listens. A fresh attempt every interval sees the listener
/// as soon as it exists, and none of them outlives the deadline.
const ATTEMPT_INTERVAL: Duration = Duration::from_millis(250);

/// Poll interval for `expect: closed`.
const POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Implements the `wait_port:` step against the IPv4 (`127.0.0.1`) and IPv6
/// (`[::1]`) loopback addresses for `<port>`, up to `args.timeout_s`.
/// Checking both matters because dev servers differ in which loopback they
/// bind — Vite, for example, binds `[::1]` only when told to listen on
/// `localhost`, so an IPv4-only probe would never see it. `expect: open`
/// passes once either address connects; `expect: closed` passes once both
/// refuse. Neither outcome waits past the deadline.
///
/// # Errors
///
/// [`RunnerError::WaitPortTimeout`] when the expected state is not
/// observed before the deadline.
pub async fn wait_for_port(args: &WaitPortArgs) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(u64::from(args.timeout_s));
    let addresses = [
        format!("127.0.0.1:{}", args.port),
        format!("[::1]:{}", args.port),
    ];
    let satisfied = match args.expect {
        PortState::Open => any_connects(&addresses, deadline).await,
        PortState::Closed => all_refuse(&addresses, deadline).await,
    };
    if satisfied {
        return Ok(());
    }
    Err(RunnerError::WaitPortTimeout {
        port: args.port,
        timeout_s: args.timeout_s,
        expect: match args.expect {
            PortState::Open => "open",
            PortState::Closed => "closed",
        },
    })
}

/// Whether a connection to any of `addresses` completes before `deadline`.
///
/// A round of attempts starts every [`ATTEMPT_INTERVAL`]; each attempt runs
/// until it resolves or the deadline passes, alongside the rounds after it.
async fn any_connects(addresses: &[String], deadline: Instant) -> bool {
    let mut attempts = JoinSet::new();
    let mut next_round = Instant::now();
    loop {
        if Instant::now() >= deadline {
            return false;
        }
        if Instant::now() >= next_round {
            for address in addresses {
                let address = address.clone();
                attempts.spawn(async move { TcpStream::connect(address).await.is_ok() });
            }
            next_round += ATTEMPT_INTERVAL;
        }
        select! {
            Some(joined) = attempts.join_next() => {
                // A panicked attempt is a failed attempt; later rounds retry.
                if matches!(joined, Ok(true)) {
                    return true;
                }
            }
            () = sleep_until(next_round.min(deadline)) => {}
        }
    }
}

/// Whether every one of `addresses` refuses a connection before `deadline`.
async fn all_refuse(addresses: &[String], deadline: Instant) -> bool {
    loop {
        let mut refused = true;
        for address in addresses {
            let remaining = deadline.saturating_duration_since(Instant::now());
            // A connect that completes, or never resolves, is not a refusal.
            if !matches!(
                timeout(remaining, TcpStream::connect(address)).await,
                Ok(Err(_))
            ) {
                refused = false;
                break;
            }
        }
        if refused {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        sleep(POLL_INTERVAL).await;
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

    /// TEST-NET-1 (RFC 5737) is reserved and routed nowhere: a SYN to it is
    /// dropped, never refused, so its attempt stays pending — the shape of
    /// the loopback SYN macOS drops while a server is bound but not yet
    /// listening.
    const UNANSWERED: &str = "192.0.2.1:9";

    /// A dropped SYN must not hold the wait past its deadline (it used to
    /// ride the kernel's 75 s connect timeout).
    #[tokio::test]
    async fn an_unanswered_syn_never_outlives_the_deadline() -> TestResult {
        let started = Instant::now();
        let deadline = started + Duration::from_secs(1);
        let connected = timeout(
            Duration::from_secs(5),
            any_connects(&[UNANSWERED.to_owned()], deadline),
        )
        .await
        .map_err(|_| "the wait hung on the unanswered SYN past its deadline")?;
        assert!(!connected);
        assert!(
            started.elapsed() < Duration::from_millis(1500),
            "a 1 s wait ran {:?}",
            started.elapsed()
        );
        Ok(())
    }

    /// A pending attempt does not stop a later one from connecting.
    #[tokio::test]
    async fn a_pending_attempt_does_not_block_one_that_connects() -> TestResult {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let live = listener.local_addr()?.to_string();
        let started = Instant::now();
        let connected = any_connects(
            &[UNANSWERED.to_owned(), live],
            started + Duration::from_secs(10),
        )
        .await;
        assert!(connected);
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "took {:?}",
            started.elapsed()
        );
        Ok(())
    }

    /// A server that starts listening mid-wait is seen by a later round.
    #[tokio::test]
    async fn a_server_that_starts_late_is_seen() -> TestResult {
        let port = dark_port().await?;
        let bind = tokio::spawn(async move {
            sleep(Duration::from_millis(600)).await;
            TcpListener::bind(("127.0.0.1", port)).await
        });
        wait_for_port(&WaitPortArgs {
            port,
            timeout_s: 5,
            expect: PortState::Open,
        })
        .await?;
        drop(bind.await??);
        Ok(())
    }
}
