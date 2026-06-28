//! Uploads spooled flow logs to the portal ingest API.
//!
//! The spool, written by `tunnel::FlowLogWriter`, nests one directory per
//! authorization under a role directory:
//! `<root>/<role>/<policy_authorization_id>/`. Each holds that authorization's
//! Bearer `token` plus per-flow reports split into `<flow_identity>.start.json`
//! (open) and `<flow_identity>.end.json` (completed) files. For each authorization
//! an upload pass:
//!
//! 1. reads the `token`,
//! 2. groups reports by `<flow_identity>` (up to the configured batch size, oldest
//!    first),
//! 3. joins each flow into a single record — the `.end` if present (it is
//!    self-describing), otherwise the `.start`,
//! 4. POSTs the batch and, on success, deletes the files it sent (both halves of a
//!    joined flow, or the lone `.start`). If a flow's `.end` arrives after its
//!    `.start` was already sent and deleted, it ships as its own record next pass.
//!
//! The submit is idempotent (the portal upserts by flow identity), so any
//! ambiguous failure retries the whole batch. Response handling:
//! - 202: delete the sent files.
//! - 422: the portal already persisted the valid records and the listed ones are
//!   permanently invalid, so log the body (to Sentry) and drop the batch.
//! - 413: split the batch and retry each half.
//! - 429: honor `Retry-After`, then retry the same batch.
//! - 408 / 5xx / transport errors: exponential backoff, then retry; defer to the
//!   next pass once the budget is spent (the files remain).
//! - Other 4xx: permanent; log the status + body (to Sentry) and drop the batch.
//!
//! Uploads go through [`http_client::HttpClient`] over the caller's
//! [`SocketFactory`], so they bypass the tunnel exactly like connlib's own traffic
//! (Apple NE process exclusion, Android `protect()`, Linux/Windows routing). The
//! client negotiates HTTP/2 and falls back to HTTP/1.1.
//!
//! Two drivers share this logic so parsing / CRC / request handling is not
//! duplicated across platforms:
//! - [`spawn`] runs a long-lived thread (gateway and desktop clients, whose tunnel
//!   service is always running).
//! - [`upload_once`] runs a single pass for platforms that drive uploads from a
//!   provider-process / OS background task via FFI.
//!
//! [`prune`] removes expired / orphaned spool directories on startup so the spool
//! cannot grow without bound.

use std::{
    collections::BTreeMap,
    net::IpAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context as _, Result};
use backoff::{ExponentialBackoff, ExponentialBackoffBuilder};
use base64::Engine as _;
use bytes::Bytes;
use flow_log_spool::{Payload, read_spooled_entry};
use http::{StatusCode, header};
use http_client::HttpClient;
use serde::{Deserialize, Serialize};
use socket_factory::{SocketFactory, TcpSocket};
use url::Url;

/// Default flows per upload when the portal doesn't specify one.
const DEFAULT_BATCH_SIZE: usize = 1_000;
/// Hard ceiling on flows per upload (matches the portal's per-request limit), so a
/// misconfigured batch size can never produce a request the portal rejects.
const MAX_BATCH_SIZE: usize = 10_000;
/// Used instead of the portal's scan interval when a scan left a backlog (an
/// authorization had more than one batch pending) so we drain it without falling
/// behind.
const CATCHUP_POLL: Duration = Duration::from_secs(1);
/// How long to wait before re-checking config while uploads are unconfigured or
/// disabled by the portal.
const DISABLED_POLL: Duration = Duration::from_secs(30);
/// Total time spent retrying one batch on transient failures before deferring it
/// to the next scan.
const MAX_UPLOAD_RETRY: Duration = Duration::from_secs(5 * 60);
/// How long a spool directory with no decodable token may linger before [`prune`]
/// removes it as an orphan.
const ORPHAN_GRACE: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// Path appended to the portal's base flow-log API URL to form the ingest endpoint.
const INGEST_PATH: &str = "/ingestion/flow_logs";
/// Name of the self-describing upload config file written into the spool root.
const CONFIG_FILE: &str = "upload.json";

/// The portal's flow-log upload config, persisted into the spool root so an uploader
/// that runs independently of the session (a background task / daemon, or the
/// service thread) can read it without a live connection to the portal.
#[derive(Serialize, Deserialize)]
struct UploadConfig {
    /// Base URL flow logs are POSTed to.
    api_url: String,
    /// How often, in seconds, to upload batched flow logs. `0` disables uploads.
    interval_secs: u64,
    /// Maximum flows per upload request. `0` / absent uses [`DEFAULT_BATCH_SIZE`].
    #[serde(default)]
    batch_size: u64,
}

/// The resolved upload config: ingest endpoint, scan interval, and batch size.
struct ResolvedConfig {
    url: String,
    interval: Duration,
    batch_size: usize,
}

/// Persists the portal's flow-log upload config into the spool root. Called by the
/// session, which alone receives it via `init`, so a session-independent uploader
/// can read it. An `interval_secs` of `0` disables uploads; a `batch_size` of `0`
/// falls back to [`DEFAULT_BATCH_SIZE`].
pub fn write_upload_config(
    spool_root: &Path,
    api_url: &str,
    interval_secs: u64,
    batch_size: u64,
) -> std::io::Result<()> {
    create_dir_secure(spool_root)?;

    let config = UploadConfig {
        api_url: api_url.to_owned(),
        interval_secs,
        batch_size,
    };
    let body = serde_json::to_vec(&config).map_err(std::io::Error::other)?;

    write_owner_only(&spool_root.join(CONFIG_FILE), &body)
}

/// Reads the persisted upload config. `None` when no (valid) config is present or
/// uploads are disabled (interval `0`).
fn read_upload_config(spool_root: &Path) -> Option<ResolvedConfig> {
    let bytes = std::fs::read(spool_root.join(CONFIG_FILE)).ok()?;
    let config: UploadConfig = serde_json::from_slice(&bytes).ok()?;

    let url = ingest_endpoint(&config.api_url)?;
    let interval = (config.interval_secs > 0).then(|| Duration::from_secs(config.interval_secs))?;
    let batch_size = batch_size_or_default(config.batch_size);

    Some(ResolvedConfig {
        url,
        interval,
        batch_size,
    })
}

/// Clamps the portal-provided batch size into `[1, MAX_BATCH_SIZE]`, defaulting when
/// it is `0` / absent.
fn batch_size_or_default(batch_size: u64) -> usize {
    let batch_size = usize::try_from(batch_size).unwrap_or(MAX_BATCH_SIZE);

    match batch_size {
        0 => DEFAULT_BATCH_SIZE,
        n => n.min(MAX_BATCH_SIZE),
    }
}

/// Spawns the flow-log uploader thread for an always-running process (the gateway,
/// the desktop tunnel service) or a provider process. The thread reads the spool's
/// config file each pass, so it picks up whatever the session persisted via
/// [`write_upload_config`], and uploads over `socket_factory` so it bypasses the
/// tunnel. It runs until the process exits.
pub fn spawn(
    spool_root: PathBuf,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> std::thread::JoinHandle<()> {
    std::thread::Builder::new()
        .name("flow-log-uploader".to_owned())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(e) => {
                    tracing::error!("Failed to build flow-log uploader runtime: {e:#}");
                    return;
                }
            };

            runtime.block_on(run(&spool_root, socket_factory));
        })
        .expect("Failed to spawn flow-log uploader thread")
}

/// Runs a single upload pass: scans the spool once and uploads any pending flows,
/// using the config persisted in the spool, over `socket_factory`. Intended for
/// platforms that drive uploads from a short-lived OS background task / the
/// provider process via FFI, so they can flush the spool independently of a
/// long-running thread.
///
/// Returns `true` when a backlog remained (an authorization had more than one batch
/// pending), so the caller may schedule another pass sooner.
pub fn upload_once(spool_root: &Path, socket_factory: Arc<dyn SocketFactory<TcpSocket>>) -> bool {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(e) => {
            tracing::error!("Failed to build flow-log uploader runtime; skipping upload: {e:#}");
            return false;
        }
    };

    let Some(config) = read_upload_config(spool_root) else {
        return false;
    };

    runtime.block_on(scan(spool_root, &config, socket_factory))
}

/// Removes spooled authorizations whose Bearer token has expired (their flows can
/// no longer be authenticated to the ingest API) and orphaned directories with no
/// decodable token older than [`ORPHAN_GRACE`]. Call on startup so the spool cannot
/// grow without bound.
pub fn prune(spool_root: &Path) {
    let now = unix_now();

    let Ok(role_dirs) = std::fs::read_dir(spool_root) else {
        return;
    };

    for role_entry in role_dirs.flatten() {
        let Ok(authz_dirs) = std::fs::read_dir(role_entry.path()) else {
            continue; // not a directory, or unreadable
        };

        for entry in authz_dirs.flatten() {
            let dir = entry.path();
            if dir.is_dir() && should_prune(&dir, now) {
                match std::fs::remove_dir_all(&dir) {
                    Ok(()) => tracing::debug!(?dir, "Pruned stale flow-log spool directory"),
                    Err(e) => tracing::warn!(?dir, "Failed to prune flow-log spool dir: {e:#}"),
                }
            }
        }
    }
}

/// Whether an authorization directory should be pruned: its token is expired, or it
/// has no decodable token and has lingered past [`ORPHAN_GRACE`].
fn should_prune(dir: &Path, now: u64) -> bool {
    match std::fs::read_to_string(dir.join("token"))
        .ok()
        .and_then(|token| token_expiry(&token))
    {
        Some(exp) => exp <= now,
        None => dir_age(dir) > ORPHAN_GRACE,
    }
}

/// Decodes the `exp` (unix seconds) claim from an ingest token's JWT payload
/// without verifying its signature.
fn token_expiry(token: &str) -> Option<u64> {
    #[derive(Deserialize)]
    struct Claims {
        exp: u64,
    }

    let payload = token.split('.').nth(1)?;
    let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .ok()?;

    serde_json::from_slice::<Claims>(&json).ok().map(|c| c.exp)
}

fn dir_age(dir: &Path) -> Duration {
    dir.metadata()
        .and_then(|m| m.modified())
        .ok()
        .and_then(|modified| SystemTime::now().duration_since(modified).ok())
        .unwrap_or_default()
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Writes `bytes` to `path`, restricting it to the owner (the spool holds Bearer
/// tokens and the API URL).
fn write_owner_only(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, bytes)?;
    set_owner_only(path)
}

#[cfg(unix)]
fn create_dir_secure(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt as _;

    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
}

#[cfg(not(unix))]
fn create_dir_secure(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)
}

#[cfg(unix)]
fn set_owner_only(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn set_owner_only(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

/// Builds the full ingest endpoint from the portal's base URL, or `None` when the
/// base URL is missing / invalid.
fn ingest_endpoint(base_url: &str) -> Option<String> {
    match Url::parse(base_url).and_then(|base| base.join(INGEST_PATH)) {
        Ok(url) => Some(url.to_string()),
        Err(e) => {
            tracing::warn!(%base_url, "Invalid flow-log API URL; uploads disabled: {e}");
            None
        }
    }
}

async fn run(spool_root: &Path, socket_factory: Arc<dyn SocketFactory<TcpSocket>>) {
    tracing::info!("Flow-log uploader thread started");

    loop {
        match read_upload_config(spool_root) {
            Some(config) => {
                let backlog = scan(spool_root, &config, socket_factory.clone()).await;
                tokio::time::sleep(if backlog { CATCHUP_POLL } else { config.interval }).await;
            }
            // No config persisted yet, or uploads disabled by the portal: idle and
            // re-check the config shortly.
            None => tokio::time::sleep(DISABLED_POLL).await,
        }
    }
}

/// Opens a tunnel-bypassing HTTP client to the ingest host. Re-resolved on every
/// scan, so a roamed / changed flow-api address is picked up without a restart.
async fn connect(
    ingest_url: &str,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<HttpClient> {
    let url = Url::parse(ingest_url).context("Invalid ingest URL")?;
    let host = url.host_str().context("Ingest URL has no host")?.to_owned();

    let addresses = tokio::net::lookup_host((host.as_str(), 443))
        .await
        .with_context(|| format!("Failed to resolve ingest host {host}"))?
        .map(|addr| addr.ip())
        .collect::<Vec<IpAddr>>();

    anyhow::ensure!(!addresses.is_empty(), "No addresses for ingest host {host}");

    HttpClient::new(host, addresses, socket_factory)
        .await
        .context("Failed to connect to ingest host")
}

/// One flow to upload: the record to send and the files to delete once it lands.
struct Pending {
    payload: Payload,
    files: Vec<PathBuf>,
}

/// The on-disk `.start`/`.end` files discovered for one flow identity.
#[derive(Default)]
struct FlowFiles {
    start: Option<PathBuf>,
    end: Option<PathBuf>,
    mtime: Option<SystemTime>,
}

/// Processes every authorization directory once; returns whether any directory
/// still has a backlog (more than one batch pending) that warrants a quick rescan.
///
/// The spool nests authorization directories one level under a `<role>` directory
/// (`<root>/<role>/<policy_authorization_id>/`), so this walks both levels.
async fn scan(
    root: &Path,
    config: &ResolvedConfig,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> bool {
    let client = match connect(&config.url, socket_factory).await {
        Ok(client) => client,
        Err(e) => {
            tracing::debug!("Failed to open flow-log ingest connection: {e:#}");
            return false;
        }
    };

    let Ok(role_dirs) = std::fs::read_dir(root) else {
        return false;
    };

    let mut backlog = false;
    for role_entry in role_dirs.flatten() {
        let role_dir = role_entry.path();
        let Ok(authz_dirs) = std::fs::read_dir(&role_dir) else {
            continue; // not a directory, or unreadable
        };

        for entry in authz_dirs.flatten() {
            let dir = entry.path();
            if !dir.is_dir() {
                continue;
            }

            // The connection died (e.g. roam); the next scan re-resolves and reconnects.
            if client.is_closed() {
                return backlog;
            }

            backlog |= process_authz_dir(&client, &dir, &config.url, config.batch_size).await;
        }
    }
    backlog
}

/// Reads up to `batch_size` flows from one authorization's spool (oldest first),
/// joins each into a record, and uploads them. Returns whether more than one batch
/// was pending (a backlog), so the caller can rescan promptly.
async fn process_authz_dir(
    client: &HttpClient,
    dir: &Path,
    url: &str,
    batch_size: usize,
) -> bool {
    let token = match std::fs::read_to_string(dir.join("token")) {
        Ok(token) => token,
        // No token yet (or it was removed): nothing we can upload for this dir.
        Err(_) => return false,
    };

    let mut flows = match group_flows(dir) {
        Ok(flows) => flows,
        Err(e) => {
            tracing::warn!(?dir, "Failed to list flow-log spool directory: {e:#}");
            return false;
        }
    };

    // Oldest flows first, bounded to one request's worth.
    flows.sort_by_key(|files| files.mtime.unwrap_or(SystemTime::UNIX_EPOCH));
    let backlog = flows.len() > batch_size;
    flows.truncate(batch_size);

    let batch = flows.into_iter().filter_map(load_flow).collect::<Vec<_>>();
    if batch.is_empty() {
        return false;
    }

    submit(client, url, &token, &batch).await;
    backlog
}

/// Groups a directory's `.start`/`.end` report files by their flow-identity stem.
fn group_flows(dir: &Path) -> std::io::Result<Vec<FlowFiles>> {
    let mut flows = BTreeMap::<String, FlowFiles>::new();

    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };

        let (stem, is_end) = if let Some(stem) = name.strip_suffix(".end.json") {
            (stem, true)
        } else if let Some(stem) = name.strip_suffix(".start.json") {
            (stem, false)
        } else {
            continue; // the `token` file or anything unexpected
        };

        let mtime = entry.metadata()?.modified().ok();
        let flow = flows.entry(stem.to_owned()).or_default();
        if is_end {
            flow.end = Some(path);
        } else {
            flow.start = Some(path);
        }
        flow.mtime = [flow.mtime, mtime].into_iter().flatten().min();
    }

    Ok(flows.into_values().collect())
}

/// Loads one flow into a [`Pending`], preferring the self-describing `.end`.
/// Corrupt files are reported and deleted; a flow with no readable report yields
/// `None`.
fn load_flow(files: FlowFiles) -> Option<Pending> {
    // Prefer the self-describing `.end`; if it is missing or corrupt (and thus
    // deleted by `read_report`), fall back to the `.start`.
    if let Some(end) = &files.end
        && let Some(payload) = read_report(end)
    {
        let mut to_delete = vec![end.clone()];
        to_delete.extend(files.start);
        return Some(Pending {
            payload,
            files: to_delete,
        });
    }

    let start = files.start?;
    let payload = read_report(&start)?;
    Some(Pending {
        payload,
        files: vec![start],
    })
}

/// Reads and verifies one report. A corrupt report is reported and deleted (it can
/// never be uploaded); a transient read error is left for the next scan.
fn read_report(path: &Path) -> Option<Payload> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) => {
            tracing::warn!(?path, "Failed to read flow-log report: {e:#}");
            return None;
        }
    };

    match read_spooled_entry(&bytes) {
        Ok(payload) => Some(payload),
        Err(e) => {
            tracing::error!(?path, "Corrupt flow-log report, deleting: {e}");
            let _ = std::fs::remove_file(path);
            None
        }
    }
}

/// Submits one batch with response-specific handling. Idempotent, so transient
/// failures retry the whole batch.
async fn submit(client: &HttpClient, url: &str, token: &str, batch: &[Pending]) {
    if batch.is_empty() {
        return;
    }

    let payloads = batch.iter().map(|flow| &flow.payload).collect::<Vec<_>>();
    let body = match serde_json::to_vec(&Batch {
        flow_logs: &payloads,
    }) {
        Ok(body) => Bytes::from(body),
        Err(e) => {
            tracing::error!("Failed to serialize flow-log batch: {e:#}");
            return;
        }
    };

    let mut backoff = upload_backoff();

    loop {
        let response = match send(client, url, token, body.clone()).await {
            Ok(response) => response,
            Err(e) => {
                tracing::warn!("Flow-log upload request failed: {e:#}");
                // A closed connection won't recover by retrying; defer to the next scan.
                if client.is_closed() || !sleep_backoff(&mut backoff).await {
                    return; // the files remain on disk
                }
                continue;
            }
        };

        let status = response.status();
        match status {
            StatusCode::ACCEPTED => {
                delete_all(batch);
                return;
            }
            StatusCode::UNPROCESSABLE_ENTITY => {
                // The portal persisted the valid records and the listed ones are
                // permanently invalid, so log and drop the whole batch.
                let body = body_string(&response);
                tracing::error!(%body, "Flow-log batch had validation errors; dropping batch");
                delete_all(batch);
                return;
            }
            StatusCode::PAYLOAD_TOO_LARGE => {
                partition(client, url, token, batch).await;
                return;
            }
            StatusCode::TOO_MANY_REQUESTS => {
                let wait = retry_after(&response).unwrap_or(CATCHUP_POLL);
                tracing::debug!(?wait, "Flow-log upload rate-limited; waiting");
                tokio::time::sleep(wait).await;
                // Not a failure; keep retrying the same batch without spending the budget.
            }
            StatusCode::REQUEST_TIMEOUT => {
                if !sleep_backoff(&mut backoff).await {
                    return;
                }
            }
            _ if status.is_server_error() => {
                tracing::debug!(%status, "Flow-log upload server error; backing off");
                if !sleep_backoff(&mut backoff).await {
                    return;
                }
            }
            _ => {
                // Other 4xx (400/401/403/...): permanent. Report and drop.
                let body = body_string(&response);
                tracing::error!(%status, %body, "Flow-log upload rejected; dropping batch");
                delete_all(batch);
                return;
            }
        }
    }
}

/// Sends one batch and reads the full response.
async fn send(
    client: &HttpClient,
    url: &str,
    token: &str,
    body: Bytes,
) -> Result<http::Response<Bytes>> {
    let request = http::Request::builder()
        .method(http::Method::POST)
        .uri(url)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(body)
        .context("Failed to build flow-log request")?;

    client.send_request(request)?.await
}

fn body_string(response: &http::Response<Bytes>) -> String {
    String::from_utf8_lossy(response.body()).into_owned()
}

/// Splits an over-sized batch in half and submits each (req: partition-and-retry).
async fn partition(client: &HttpClient, url: &str, token: &str, batch: &[Pending]) {
    if batch.len() <= 1 {
        tracing::error!("A single flow exceeds the upload size limit; dropping");
        delete_all(batch);
        return;
    }

    let mid = batch.len() / 2;
    Box::pin(submit(client, url, token, &batch[..mid])).await;
    Box::pin(submit(client, url, token, &batch[mid..])).await;
}

fn delete_all(batch: &[Pending]) {
    for flow in batch {
        for path in &flow.files {
            if let Err(e) = std::fs::remove_file(path) {
                tracing::warn!(?path, "Failed to delete uploaded flow-log report: {e:#}");
            }
        }
    }
}

fn retry_after(response: &http::Response<Bytes>) -> Option<Duration> {
    let seconds = response
        .headers()
        .get(header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .parse::<u64>()
        .ok()?;

    Some(Duration::from_secs(seconds))
}

fn upload_backoff() -> ExponentialBackoff {
    ExponentialBackoffBuilder::default()
        .with_max_interval(Duration::from_secs(60))
        .with_max_elapsed_time(Some(MAX_UPLOAD_RETRY))
        .build()
}

/// Sleeps for the next backoff interval; returns `false` once the budget is spent.
async fn sleep_backoff(backoff: &mut ExponentialBackoff) -> bool {
    match backoff.next_backoff() {
        Some(interval) => {
            tokio::time::sleep(interval).await;
            true
        }
        None => false,
    }
}

#[derive(Serialize)]
struct Batch<'a> {
    flow_logs: &'a [&'a Payload],
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token_expiring_at(exp: u64) -> String {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(format!(r#"{{"exp":{exp}}}"#));

        format!("header.{payload}.signature")
    }

    #[test]
    fn write_then_read_config_builds_ingest_endpoint_interval_and_batch_size() {
        let root = tempfile::tempdir().unwrap();
        write_upload_config(root.path(), "https://flow-api.firezone.dev/", 90, 500).unwrap();

        let config = read_upload_config(root.path()).expect("config present");
        assert_eq!(config.url, "https://flow-api.firezone.dev/ingestion/flow_logs");
        assert_eq!(config.interval, Duration::from_secs(90));
        assert_eq!(config.batch_size, 500);
    }

    #[test]
    fn zero_or_missing_batch_size_uses_default() {
        let root = tempfile::tempdir().unwrap();
        write_upload_config(root.path(), "https://flow-api.firezone.dev/", 60, 0).unwrap();

        let config = read_upload_config(root.path()).expect("config present");
        assert_eq!(config.batch_size, DEFAULT_BATCH_SIZE);
    }

    #[test]
    fn batch_size_is_clamped_to_max() {
        assert_eq!(batch_size_or_default(1_000_000), MAX_BATCH_SIZE);
    }

    #[test]
    fn zero_interval_disables_uploads() {
        let root = tempfile::tempdir().unwrap();
        write_upload_config(root.path(), "https://flow-api.firezone.dev/", 0, 1000).unwrap();

        assert!(read_upload_config(root.path()).is_none());
    }

    #[test]
    fn invalid_url_disables_uploads() {
        let root = tempfile::tempdir().unwrap();
        write_upload_config(root.path(), "not a url", 60, 1000).unwrap();

        assert!(read_upload_config(root.path()).is_none());
    }

    #[test]
    fn missing_config_disables_uploads() {
        let root = tempfile::tempdir().unwrap();

        assert!(read_upload_config(root.path()).is_none());
    }

    #[test]
    fn token_expiry_reads_exp_claim() {
        assert_eq!(
            token_expiry(&token_expiring_at(1_700_000_000)),
            Some(1_700_000_000)
        );
        assert_eq!(token_expiry("not-a-jwt"), None);
    }

    #[test]
    fn prune_removes_expired_authz_dirs_and_keeps_valid() {
        let root = tempfile::tempdir().unwrap();
        let now = unix_now();

        let expired = root.path().join("responder").join("expired-pa");
        std::fs::create_dir_all(&expired).unwrap();
        std::fs::write(expired.join("token"), token_expiring_at(now - 60)).unwrap();
        std::fs::write(expired.join("a.start.json"), "{}").unwrap();

        let valid = root.path().join("responder").join("valid-pa");
        std::fs::create_dir_all(&valid).unwrap();
        std::fs::write(valid.join("token"), token_expiring_at(now + 3600)).unwrap();

        prune(root.path());

        assert!(!expired.exists(), "expired authorization dir should be pruned");
        assert!(valid.exists(), "unexpired authorization dir should be kept");
    }
}
