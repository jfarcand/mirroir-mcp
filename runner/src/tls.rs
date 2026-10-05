// ABOUTME: The one place a reqwest client is started — every HTTP client the runner builds begins here.
// ABOUTME: Pins TLS to the ring provider and the bundled Mozilla roots, so a static binary needs no system CA store.

use std::sync::Arc;

use reqwest::{Client, ClientBuilder};
use rustls::crypto::ring;
use rustls::{ClientConfig, RootCertStore};

use crate::error::{Result, RunnerError};

/// Start a `reqwest` client builder whose TLS is already configured.
///
/// The rustls config is built here and handed to reqwest pre-built, so reqwest
/// never looks for a process-default crypto provider — with the
/// `rustls-no-provider` feature it panics when none is installed. Trust comes
/// from `webpki-roots`, compiled into the binary, so certificate verification
/// behaves the same on a static-musl Linux build as on a desktop.
///
/// # Errors
///
/// [`RunnerError::TlsConfig`] if the ring provider rejects rustls's default
/// protocol versions.
pub fn client_builder() -> Result<ClientBuilder> {
    let roots = RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let config = ClientConfig::builder_with_provider(Arc::new(ring::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(|source| RunnerError::TlsConfig { source })?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Client::builder().tls_backend_preconfigured(config))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_preconfigured_rustls_backend_builds_a_client() -> Result<()> {
        // reqwest accepts a pre-built config only when it is the same rustls
        // version reqwest links; any other type is an "unknown" backend and
        // `build()` fails. Building here proves the two stay in step.
        client_builder()?
            .build()
            .map_err(|source| RunnerError::HttpClient { source })?;
        Ok(())
    }
}
