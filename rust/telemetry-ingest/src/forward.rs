//! Forwarding of verified reports to an Azure Monitor data collection endpoint.

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context as _, Result};
use futures::future::BoxFuture;
use serde::Deserialize;
use tokio::sync::Mutex;
use url::Url;

/// Where a verified report goes once it has been re-encoded as OTLP protobuf.
pub trait Sink: Send + Sync + 'static {
    fn forward(&self, report: Vec<u8>) -> BoxFuture<'_, Result<()>>;
}

/// The default IMDS address, link-local and reachable from every Azure VM.
const IMDS_ENDPOINT: &str = "http://169.254.169.254";
/// The Entra audience Azure Monitor ingestion accepts.
const MONITOR_RESOURCE: &str = "https://monitor.azure.com";
/// How long before a token actually expires we fetch a new one.
const TOKEN_REFRESH_MARGIN: Duration = Duration::from_secs(300);

pub struct AzureMonitor {
    client: reqwest::Client,
    endpoint: Url,
    tokens: ManagedIdentity,
}

impl AzureMonitor {
    pub fn new(client: reqwest::Client, endpoint: Url, client_id: String) -> Self {
        Self {
            tokens: ManagedIdentity::new(client.clone(), IMDS_ENDPOINT.to_owned(), client_id),
            client,
            endpoint,
        }
    }
}

impl Sink for AzureMonitor {
    fn forward(&self, report: Vec<u8>) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            let token = self.tokens.access_token().await?;

            let response = self
                .client
                .post(self.endpoint.clone())
                .bearer_auth(token)
                .header(reqwest::header::CONTENT_TYPE, "application/x-protobuf")
                .body(report)
                .send()
                .await
                .context("Failed to POST to the data collection endpoint")?;

            let status = response.status();

            anyhow::ensure!(
                status.is_success(),
                "Data collection endpoint rejected the report with {status}"
            );

            Ok(())
        })
    }
}

/// Entra access tokens for the VM's user-assigned managed identity, fetched
/// from the Azure Instance Metadata Service and cached until they near expiry.
struct ManagedIdentity {
    client: reqwest::Client,
    endpoint: String,
    client_id: String,
    cached: Mutex<Option<CachedToken>>,
}

#[derive(Clone)]
struct CachedToken {
    token: Arc<str>,
    expires_at: SystemTime,
}

impl ManagedIdentity {
    fn new(client: reqwest::Client, endpoint: String, client_id: String) -> Self {
        Self {
            client,
            endpoint,
            client_id,
            cached: Mutex::new(None),
        }
    }

    async fn access_token(&self) -> Result<Arc<str>> {
        let mut cached = self.cached.lock().await;

        if let Some(token) = cached
            .as_ref()
            .filter(|token| token.expires_at > SystemTime::now() + TOKEN_REFRESH_MARGIN)
        {
            return Ok(token.token.clone());
        }

        let fresh = self.fetch().await?;
        let token = fresh.token.clone();
        *cached = Some(fresh);

        Ok(token)
    }

    async fn fetch(&self) -> Result<CachedToken> {
        let response = self
            .client
            .get(format!("{}/metadata/identity/oauth2/token", self.endpoint))
            .header("Metadata", "true")
            .query(&[
                ("api-version", "2018-02-01"),
                ("resource", MONITOR_RESOURCE),
                ("client_id", self.client_id.as_str()),
            ])
            .send()
            .await
            .context("Failed to reach IMDS")?
            .error_for_status()
            .context("IMDS rejected the token request")?
            .json::<ImdsToken>()
            .await
            .context("Failed to parse the IMDS token response")?;

        Ok(CachedToken {
            token: Arc::from(response.access_token),
            expires_at: UNIX_EPOCH + Duration::from_secs(response.expires_on.parse()?),
        })
    }
}

#[derive(Deserialize)]
struct ImdsToken {
    access_token: String,
    expires_on: String,
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use axum::Router;
    use axum::extract::State;
    use axum::routing::get;

    use super::*;

    #[tokio::test]
    async fn caches_the_access_token_until_it_nears_expiry() {
        let fetches = Arc::new(AtomicUsize::new(0));
        let endpoint = serve_imds(fetches.clone(), 3600).await;
        let identity = ManagedIdentity::new(client(), endpoint, "client".to_owned());

        let first = identity.access_token().await.unwrap();
        let second = identity.access_token().await.unwrap();

        assert_eq!(&*first, "token-1");
        assert_eq!(first, second);
        assert_eq!(fetches.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn refetches_a_token_that_is_about_to_expire() {
        let fetches = Arc::new(AtomicUsize::new(0));
        let endpoint = serve_imds(fetches.clone(), 60).await;
        let identity = ManagedIdentity::new(client(), endpoint, "client".to_owned());

        assert_eq!(&*identity.access_token().await.unwrap(), "token-1");
        assert_eq!(&*identity.access_token().await.unwrap(), "token-2");
    }

    /// `reqwest` panics when built without a rustls provider, which `main`
    /// installs once at startup.
    fn client() -> reqwest::Client {
        static PROVIDER: std::sync::Once = std::sync::Once::new();

        PROVIDER.call_once(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
        });

        reqwest::Client::new()
    }

    async fn serve_imds(fetches: Arc<AtomicUsize>, lifetime_secs: u64) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();

        let app = Router::new()
            .route("/metadata/identity/oauth2/token", get(issue))
            .with_state((fetches, lifetime_secs));

        tokio::spawn(async move { axum::serve(listener, app).await });

        format!("http://{address}")
    }

    async fn issue(
        State((fetches, lifetime_secs)): State<(Arc<AtomicUsize>, u64)>,
    ) -> axum::Json<serde_json::Value> {
        let nth = fetches.fetch_add(1, Ordering::SeqCst) + 1;
        let expires_on = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + lifetime_secs;

        axum::Json(serde_json::json!({
            "access_token": format!("token-{nth}"),
            "expires_on": expires_on.to_string(),
        }))
    }
}
