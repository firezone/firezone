use anyhow::{Context as _, Result};
use axum::Router;
use bin_shared::signals::Terminate;
use futures::future::{self, Either};
use hyper_util::rt::{TokioIo, TokioTimer};
use hyper_util::server::graceful::{GracefulShutdown, Watcher};
use hyper_util::service::TowerToHyperService;
use parking_lot::RwLock;
use rustls::ServerConfig;
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;
use rustls_pki_types::pem::PemObject as _;
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use std::fmt;
use std::path::{Path, PathBuf};
use std::pin::pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsAcceptor;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);

/// Serves the certificate and key at the given paths, picking up changes on [`CertResolver::reload`].
pub struct CertResolver {
    cert_path: PathBuf,
    key_path: PathBuf,
    current: RwLock<Arc<CertifiedKey>>,
}

impl CertResolver {
    pub fn load(cert_path: PathBuf, key_path: PathBuf) -> Result<Self> {
        let current = load_certified_key(&cert_path, &key_path)?;

        Ok(Self {
            cert_path,
            key_path,
            current: RwLock::new(Arc::new(current)),
        })
    }

    /// Loads the certificate and key again.
    ///
    /// # Errors
    ///
    /// Keeps serving the previous certificate if the files cannot be loaded or do not match,
    /// e.g. because only one of them has been rewritten yet.
    pub fn reload(&self) -> Result<()> {
        let new = load_certified_key(&self.cert_path, &self.key_path)?;

        let mut current = self.current.write();
        if current.cert != new.cert {
            tracing::info!("Loaded new TLS certificate");
        }
        *current = Arc::new(new);

        Ok(())
    }

    pub fn server_config(self: Arc<Self>) -> ServerConfig {
        let mut config = ServerConfig::builder()
            .with_no_client_auth()
            .with_cert_resolver(self);
        config.alpn_protocols = vec![b"http/1.1".to_vec()];

        config
    }
}

impl ResolvesServerCert for CertResolver {
    fn resolve(&self, _: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        Some(self.current.read().clone())
    }
}

impl fmt::Debug for CertResolver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CertResolver")
            .field("cert_path", &self.cert_path)
            .field("key_path", &self.key_path)
            .finish_non_exhaustive()
    }
}

fn load_certified_key(cert_path: &Path, key_path: &Path) -> Result<CertifiedKey> {
    let certs = CertificateDer::pem_file_iter(cert_path)
        .with_context(|| format!("Failed to read certificate from {}", cert_path.display()))?
        .collect::<Result<Vec<_>, _>>()
        .with_context(|| format!("Invalid certificate in {}", cert_path.display()))?;
    let key = PrivateKeyDer::from_pem_file(key_path)
        .with_context(|| format!("Failed to read private key from {}", key_path.display()))?;
    let key = rustls::crypto::ring::sign::any_supported_type(&key)
        .context("Unsupported private key type")?;

    let certified_key = CertifiedKey::new(certs, key);
    certified_key
        .keys_match()
        .context("Certificate does not match private key")?;

    Ok(certified_key)
}

/// Serves `router` over HTTPS until SIGINT or SIGTERM, then waits for open connections to finish.
pub async fn serve(listener: TcpListener, tls: TlsAcceptor, router: Router) -> Result<()> {
    let mut terminate = Terminate::new().context("Failed to listen for signals")?;
    let graceful = GracefulShutdown::new();

    loop {
        let accept = pin!(listener.accept());
        let terminated = pin!(terminate.recv());

        let stream = match future::select(accept, terminated).await {
            Either::Left((Ok((stream, _)), _)) => stream,
            Either::Left((Err(e), _)) => {
                tracing::warn!("Failed to accept connection: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;

                continue;
            }
            Either::Right(((), _)) => break,
        };

        tokio::spawn(serve_connection(
            stream,
            tls.clone(),
            router.clone(),
            graceful.watcher(),
        ));
    }

    tracing::info!("Shutting down");

    let shutdown = pin!(graceful.shutdown());
    let timeout = pin!(tokio::time::sleep(SHUTDOWN_TIMEOUT));
    if let Either::Right(_) = future::select(shutdown, timeout).await {
        tracing::warn!("Timed out waiting for connections to close");
    }

    Ok(())
}

async fn serve_connection(stream: TcpStream, tls: TlsAcceptor, router: Router, watcher: Watcher) {
    let stream = match tokio::time::timeout(HANDSHAKE_TIMEOUT, tls.accept(stream)).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(e)) => {
            tracing::debug!("TLS handshake failed: {e}");

            return;
        }
        Err(_) => {
            tracing::debug!("TLS handshake timed out");

            return;
        }
    };

    let connection = hyper::server::conn::http1::Builder::new()
        .timer(TokioTimer::new())
        .serve_connection(TokioIo::new(stream), TowerToHyperService::new(router));

    if let Err(e) = watcher.watch(connection).await {
        tracing::debug!("Failed to serve connection: {e}");
    }
}
