use std::sync::LazyLock;

use anyhow::{Context as _, Result};
use bytes::Bytes;
use http::{Method, Request, Response, header};
use serde::Serialize;

use crate::{Env, ingest};

pub(crate) const API_KEY_PROD: &str = "phc_uXXl56plyvIBHj81WwXBLtdPElIRbm7keRTdUCmk8ll";
pub(crate) const API_KEY_STAGING: &str = "phc_tHOVtq183RpfKmzadJb4bxNpLM5jzeeb1Gu8YSH3nsK";
pub(crate) const API_KEY_ON_PREM: &str = "phc_4R9Ii6q4SEofVkH7LvajwuJ3nsGFhCj0ZlfysS2FNc";

const INGEST_HOST: &str = "posthog.firezone.dev";

static CLIENT: LazyLock<ingest::Client> = LazyLock::new(|| ingest::Client::new(INGEST_HOST));

pub(crate) fn api_key_for_env(env: Env) -> Option<&'static str> {
    match env {
        Env::Production => Some(API_KEY_PROD),
        Env::Staging => Some(API_KEY_STAGING),
        Env::OnPrem => Some(API_KEY_ON_PREM),
        Env::Entrypoint | Env::DockerCompose | Env::Localhost => None,
    }
}

/// Drops the current connection so the next request reconnects.
pub(crate) fn reset_client() {
    CLIENT.reset();
}

/// Sends a JSON `POST` to `path` on the PostHog ingest host and returns the response.
pub(crate) async fn post_json<B>(path: &str, body: &B) -> Result<Response<Bytes>>
where
    B: Serialize,
{
    let request = Request::builder()
        .method(Method::POST)
        .uri(format!("https://{INGEST_HOST}{path}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Bytes::from(
            serde_json::to_vec(body).context("Failed to serialize request body")?,
        ))
        .context("Failed to build HTTP request")?;

    CLIENT.send_request(request).await
}
