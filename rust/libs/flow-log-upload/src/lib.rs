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
//! - 2xx: delete the sent files.
//! - 422: the portal already persisted the valid records and the listed ones are
//!   permanently invalid, so log the body and drop the batch.
//! - 413: split the batch and retry each half.
//! - 429: honor `Retry-After`, then retry the same batch.
//! - 408 / 5xx / transport errors: exponential backoff, then retry; defer to the
//!   next pass once the budget is spent (the files remain).
//! - Other 4xx: permanent; log the status + body and drop the batch.
//!
//! Uploads go through [`http_client::HttpClient`] over the caller's
//! [`SocketFactory`], so they bypass the tunnel exactly like connlib's own traffic.
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

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context as _, Result};
use backoff::{ExponentialBackoff, ExponentialBackoffBuilder};
use base64::Engine as _;
use bytes::Bytes;
use flow_log_spool::{Payload, deserialize};
use http::{StatusCode, header};
use http_client::HttpClient;
use serde::{Deserialize, Serialize};
use serde_with::{DurationSeconds, serde_as};
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
/// Path appended to the portal's base flow-log API URL to form the ingest endpoint.
const INGEST_PATH: &str = "/ingestion/flow_logs";
/// Name of the self-describing upload config file written into the spool root.
const CONFIG_FILE: &str = "upload.json";

/// The portal's flow-log upload config, persisted into the spool root so an uploader
/// that runs independently of the session (a background task / daemon, or the
/// service thread) can read it without a live connection to the portal.
///
/// Only written while uploads are enabled: an `interval` of `0` is never persisted
/// (see [`write_upload_config`]), so the file's presence alone means "enabled".
#[serde_as]
#[derive(Serialize, Deserialize)]
struct UploadConfig {
    /// Base URL flow logs are POSTed to.
    api_url: String,
    /// How often to upload batched flow logs.
    #[serde_as(as = "DurationSeconds<u64>")]
    interval: Duration,
    /// Maximum flows per upload request. Absent uses [`DEFAULT_BATCH_SIZE`].
    #[serde(default = "default_batch_size")]
    batch_size: usize,
}

fn default_batch_size() -> usize {
    DEFAULT_BATCH_SIZE
}

/// Persists the portal's flow-log upload config into the spool root. Called by the
/// session, which alone receives it via `init`, so a session-independent uploader
/// can read it.
///
/// An `interval_secs` of `0` means the portal disabled uploads: any persisted config
/// is removed so a running uploader stops, rather than keeping the last one.
pub fn write_upload_config(
    spool_root: &Path,
    api_url: &str,
    interval_secs: u64,
    batch_size: u64,
) -> std::io::Result<()> {
    let config_path = spool_root.join(CONFIG_FILE);

    if interval_secs == 0 {
        return match std::fs::remove_file(&config_path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        };
    }

    create_dir_secure(spool_root)?;

    let config = UploadConfig {
        api_url: api_url.to_owned(),
        interval: Duration::from_secs(interval_secs),
        batch_size: clamp_batch_size(batch_size),
    };
    let body = serde_json::to_vec(&config).map_err(std::io::Error::other)?;

    write_owner_only(&config_path, &body)?;

    Ok(())
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
/// long-running thread. The caller owns the runtime this runs on.
///
/// Returns `true` when a backlog remained (an authorization had more than one batch
/// pending), so the caller may schedule another pass sooner.
pub async fn upload_once(
    spool_root: &Path,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> bool {
    let Some(config) = read_upload_config(spool_root) else {
        return false;
    };

    scan(spool_root, &config, socket_factory).await == ScanOutcome::RescanSoon
}

/// Removes spooled authorizations whose Bearer token has expired (their flows can
/// no longer be authenticated to the ingest API) and orphaned directories that have
/// no token at all (nothing in them can ever be uploaded). Call on startup, where it
/// never races a writer, so the spool cannot grow without bound.
pub fn prune(spool_root: &Path) {
    let now = unix_now();

    let Ok(role_dirs) = std::fs::read_dir(spool_root) else {
        return;
    };

    for role_entry in role_dirs.flatten() {
        let Ok(authz_dirs) = std::fs::read_dir(role_entry.path()) else {
            continue;
        };

        for entry in authz_dirs.flatten() {
            let dir = entry.path();
            if !dir.is_dir() || !should_prune(&dir, now) {
                continue;
            }

            match std::fs::remove_dir_all(&dir) {
                Ok(()) => tracing::debug!(?dir, "Pruned stale flow-log spool directory"),
                Err(e) => tracing::info!(?dir, "Failed to prune flow-log spool dir: {e:#}"),
            }
        }
    }
}

/// Reads the persisted upload config, or `None` when none is present / valid.
fn read_upload_config(spool_root: &Path) -> Option<UploadConfig> {
    let bytes = std::fs::read(spool_root.join(CONFIG_FILE)).ok()?;

    serde_json::from_slice(&bytes).ok()
}

/// Clamps the portal-provided batch size into `[1, MAX_BATCH_SIZE]`, defaulting when
/// it is `0`.
fn clamp_batch_size(batch_size: u64) -> usize {
    match usize::try_from(batch_size).unwrap_or(MAX_BATCH_SIZE) {
        0 => DEFAULT_BATCH_SIZE,
        n => n.min(MAX_BATCH_SIZE),
    }
}

/// Whether an authorization directory should be pruned.
///
/// A directory with no `token` file can never be uploaded (the Bearer token is the
/// only credential), so it is a leftover orphan and is pruned immediately. Otherwise
/// it is pruned once its token has expired. An undecodable token is kept, so a
/// transient decode failure never deletes uploadable data.
fn should_prune(dir: &Path, now: u64) -> bool {
    let Ok(token) = std::fs::read_to_string(dir.join("token")) else {
        return true;
    };

    token_expiry(&token).is_some_and(|exp| exp <= now)
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

#[cfg(windows)]
fn create_dir_secure(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)?;
    apply_sddl(path, DIR_SDDL)
}

#[cfg(not(any(unix, windows)))]
fn create_dir_secure(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)
}

#[cfg(unix)]
fn set_owner_only(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}

#[cfg(windows)]
fn set_owner_only(path: &Path) -> std::io::Result<()> {
    apply_sddl(path, FILE_SDDL)
}

#[cfg(not(any(unix, windows)))]
fn set_owner_only(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

/// The spool holds Bearer tokens, so on Windows every spool directory and file is
/// locked down to `LocalSystem` and `BUILTIN\Administrators` (the accounts the
/// Gateway / Tunnel service runs as), the equivalent of `0700`/`0600` on Unix.
/// `OICI` on the directory ACEs makes children inherit the same access.
#[cfg(windows)]
const DIR_SDDL: &str = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
#[cfg(windows)]
const FILE_SDDL: &str = "D:P(A;;FA;;;SY)(A;;FA;;;BA)";

#[cfg(windows)]
fn apply_sddl(path: &Path, sddl: &str) -> std::io::Result<()> {
    windows_security::SecurityDescriptor::from_sddl(sddl)
        .and_then(|descriptor| descriptor.apply_to_path(path))
        .map_err(|e| std::io::Error::other(format!("{e:#}")))
}

/// Builds the full ingest endpoint from the portal's base URL, or `None` when the
/// base URL is missing / invalid.
fn ingest_endpoint(base_url: &str) -> Option<String> {
    match Url::parse(base_url).and_then(|base| base.join(INGEST_PATH)) {
        Ok(url) => Some(url.to_string()),
        Err(e) => {
            tracing::info!(%base_url, "Invalid flow-log API URL; uploads disabled: {e}");
            None
        }
    }
}

async fn run(spool_root: &Path, socket_factory: Arc<dyn SocketFactory<TcpSocket>>) {
    tracing::info!("Flow-log uploader started");

    loop {
        match read_upload_config(spool_root) {
            Some(config) => {
                let delay = match scan(spool_root, &config, socket_factory.clone()).await {
                    ScanOutcome::RescanSoon => CATCHUP_POLL,
                    ScanOutcome::Drained => config.interval,
                };
                tokio::time::sleep(delay).await;
            }
            // No config persisted yet, or uploads disabled by the portal: idle and
            // re-check the config shortly.
            None => tokio::time::sleep(DISABLED_POLL).await,
        }
    }
}

/// Opens a tunnel-bypassing HTTP client to the ingest host. Re-resolved on every
/// scan, so a roamed / changed flow-api address is picked up without a restart.
///
/// Resolution goes through [`telemetry::resolve_ingest_host`] so that, like
/// telemetry, it uses connlib's captured upstream resolvers while a session is
/// active rather than `getaddrinfo`, which would loop back through connlib's
/// hijacked system resolver.
async fn connect(
    ingest_url: &str,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<HttpClient> {
    let url = Url::parse(ingest_url).context("Invalid ingest URL")?;
    let host = url.host_str().context("Ingest URL has no host")?.to_owned();

    let addresses = telemetry::resolve_ingest_host(&host).await?;

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

/// Whether the uploader should scan again soon or wait the configured interval.
#[derive(Clone, Copy, PartialEq)]
enum ScanOutcome {
    /// More work is pending: an authorization had more than one batch, or the
    /// connection dropped mid-scan before everything was drained.
    RescanSoon,
    /// Everything pending was uploaded; wait the configured interval.
    Drained,
}

/// Processes every authorization directory once.
///
/// The spool nests authorization directories one level under a `<role>` directory
/// (`<root>/<role>/<policy_authorization_id>/`), so this walks both levels.
async fn scan(
    root: &Path,
    config: &UploadConfig,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> ScanOutcome {
    let Some(url) = ingest_endpoint(&config.api_url) else {
        return ScanOutcome::Drained;
    };

    let client = match connect(&url, socket_factory).await {
        Ok(client) => client,
        Err(e) => {
            tracing::debug!("Failed to open flow-log ingest connection: {e:#}");
            return ScanOutcome::Drained;
        }
    };

    let Ok(role_dirs) = std::fs::read_dir(root) else {
        return ScanOutcome::Drained;
    };

    let mut backlog = false;
    for role_entry in role_dirs.flatten() {
        let role_dir = role_entry.path();
        let Ok(authz_dirs) = std::fs::read_dir(&role_dir) else {
            continue;
        };

        for entry in authz_dirs.flatten() {
            let dir = entry.path();
            if !dir.is_dir() {
                continue;
            }

            // The connection died (e.g. roam) before we finished, so scan again soon
            // to drain the rest; the next scan re-resolves and reconnects.
            if client.is_closed() {
                return ScanOutcome::RescanSoon;
            }

            backlog |= process_authz_dir(&client, &dir, &url, config.batch_size).await;
        }
    }

    if backlog {
        ScanOutcome::RescanSoon
    } else {
        ScanOutcome::Drained
    }
}

/// Reads up to `batch_size` flows from one authorization's spool (oldest first),
/// joins each into a record, and uploads them. Returns whether more than one batch
/// was pending (a backlog), so the caller can rescan promptly.
async fn process_authz_dir(client: &HttpClient, dir: &Path, url: &str, batch_size: usize) -> bool {
    let token = match std::fs::read_to_string(dir.join("token")) {
        Ok(token) => token,
        // No token yet (or it was removed): nothing we can upload for this dir.
        Err(_) => return false,
    };

    let mut flows = match group_flows(dir) {
        Ok(flows) => flows,
        Err(e) => {
            tracing::info!(?dir, "Failed to list flow-log spool directory: {e:#}");
            return false;
        }
    };

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
            continue;
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
            tracing::info!(?path, "Failed to read flow-log report: {e:#}");
            return None;
        }
    };

    match deserialize(&bytes) {
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
                tracing::info!("Flow-log upload request failed: {e:#}");
                // A closed connection won't recover by retrying; defer to the next scan.
                if client.is_closed() || !sleep_backoff(&mut backoff).await {
                    return; // the files remain on disk
                }
                continue;
            }
        };

        let status = response.status();
        match classify_response(status) {
            ResponseAction::Delete => {
                delete_all(batch);
                return;
            }
            ResponseAction::Partition => {
                partition(client, url, token, batch).await;
                return;
            }
            ResponseAction::RateLimited => {
                let wait = retry_after(&response).unwrap_or(CATCHUP_POLL);
                tracing::debug!(?wait, "Flow-log upload rate-limited; waiting");
                tokio::time::sleep(wait).await;
                // Not a failure; keep retrying the same batch without spending the budget.
            }
            ResponseAction::Retry => {
                tracing::debug!(%status, "Flow-log upload transient failure; backing off");
                if !sleep_backoff(&mut backoff).await {
                    return;
                }
            }
            ResponseAction::Drop => {
                let body = body_string(&response);
                tracing::info!(%status, %body, "Flow-log upload rejected; dropping batch");
                delete_all(batch);
                return;
            }
        }
    }
}

/// What to do with a batch after a POST, decided from the response status.
#[derive(Clone, Copy, PartialEq, Debug)]
enum ResponseAction {
    /// The batch was persisted (2xx); delete the sent files.
    Delete,
    /// The batch is too large (413); split it and retry each half.
    Partition,
    /// Rate-limited (429); honour `Retry-After`, then retry the same batch.
    RateLimited,
    /// Transient failure (408 / 5xx); back off, then retry the same batch.
    Retry,
    /// Permanently rejected (422 / other 4xx); log and drop the batch. The portal
    /// upserts by flow identity, so a dropped batch is never a partial write.
    Drop,
}

fn classify_response(status: StatusCode) -> ResponseAction {
    match status {
        s if s.is_success() => ResponseAction::Delete,
        StatusCode::PAYLOAD_TOO_LARGE => ResponseAction::Partition,
        StatusCode::TOO_MANY_REQUESTS => ResponseAction::RateLimited,
        StatusCode::REQUEST_TIMEOUT => ResponseAction::Retry,
        s if s.is_server_error() => ResponseAction::Retry,
        _ => ResponseAction::Drop,
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
                tracing::info!(?path, "Failed to delete uploaded flow-log report: {e:#}");
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
        let payload =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!(r#"{{"exp":{exp}}}"#));

        format!("header.{payload}.signature")
    }

    #[test]
    fn write_then_read_config_roundtrips() {
        let root = tempfile::tempdir().unwrap();
        write_upload_config(root.path(), "https://flow-api.firezone.dev/", 90, 500).unwrap();

        let config = read_upload_config(root.path()).expect("config present");
        assert_eq!(config.api_url, "https://flow-api.firezone.dev/");
        assert_eq!(config.interval, Duration::from_secs(90));
        assert_eq!(config.batch_size, 500);
    }

    #[test]
    fn ingest_endpoint_appends_the_ingest_path() {
        assert_eq!(
            ingest_endpoint("https://flow-api.firezone.dev/").as_deref(),
            Some("https://flow-api.firezone.dev/ingestion/flow_logs")
        );
        assert_eq!(ingest_endpoint("not a url"), None);
    }

    #[test]
    fn zero_batch_size_uses_default() {
        let root = tempfile::tempdir().unwrap();
        write_upload_config(root.path(), "https://flow-api.firezone.dev/", 60, 0).unwrap();

        let config = read_upload_config(root.path()).expect("config present");
        assert_eq!(config.batch_size, DEFAULT_BATCH_SIZE);
    }

    #[test]
    fn batch_size_is_clamped_to_max() {
        assert_eq!(clamp_batch_size(1_000_000), MAX_BATCH_SIZE);
    }

    #[test]
    fn zero_interval_disables_uploads() {
        let root = tempfile::tempdir().unwrap();
        write_upload_config(root.path(), "https://flow-api.firezone.dev/", 0, 1000).unwrap();

        assert!(read_upload_config(root.path()).is_none());
    }

    #[test]
    fn disabling_removes_an_existing_config() {
        let root = tempfile::tempdir().unwrap();
        write_upload_config(root.path(), "https://flow-api.firezone.dev/", 60, 500).unwrap();
        assert!(read_upload_config(root.path()).is_some());

        write_upload_config(root.path(), "https://flow-api.firezone.dev/", 0, 500).unwrap();
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

        // No token: can never be uploaded, so pruned immediately (no grace period).
        let orphan = root.path().join("responder").join("orphan-pa");
        std::fs::create_dir_all(&orphan).unwrap();
        std::fs::write(orphan.join("a.start.json"), "{}").unwrap();

        prune(root.path());

        assert!(
            !expired.exists(),
            "expired authorization dir should be pruned"
        );
        assert!(valid.exists(), "unexpired authorization dir should be kept");
        assert!(
            !orphan.exists(),
            "token-less authorization dir should be pruned"
        );
    }

    #[test]
    fn classify_response_maps_status_to_action() {
        use ResponseAction::*;

        assert_eq!(classify_response(StatusCode::OK), Delete);
        assert_eq!(classify_response(StatusCode::ACCEPTED), Delete);
        assert_eq!(classify_response(StatusCode::NO_CONTENT), Delete);
        assert_eq!(classify_response(StatusCode::PAYLOAD_TOO_LARGE), Partition);
        assert_eq!(
            classify_response(StatusCode::TOO_MANY_REQUESTS),
            RateLimited
        );
        assert_eq!(classify_response(StatusCode::REQUEST_TIMEOUT), Retry);
        assert_eq!(classify_response(StatusCode::INTERNAL_SERVER_ERROR), Retry);
        assert_eq!(classify_response(StatusCode::SERVICE_UNAVAILABLE), Retry);
        assert_eq!(classify_response(StatusCode::UNPROCESSABLE_ENTITY), Drop);
        assert_eq!(classify_response(StatusCode::BAD_REQUEST), Drop);
        assert_eq!(classify_response(StatusCode::UNAUTHORIZED), Drop);
        assert_eq!(classify_response(StatusCode::FORBIDDEN), Drop);
    }

    #[test]
    fn retry_after_parses_the_seconds_header() {
        let with_header = http::Response::builder()
            .header(header::RETRY_AFTER, "30")
            .body(Bytes::new())
            .unwrap();
        assert_eq!(retry_after(&with_header), Some(Duration::from_secs(30)));

        let no_header = http::Response::builder().body(Bytes::new()).unwrap();
        assert_eq!(retry_after(&no_header), None);

        let non_numeric = http::Response::builder()
            .header(header::RETRY_AFTER, "soon")
            .body(Bytes::new())
            .unwrap();
        assert_eq!(retry_after(&non_numeric), None);
    }
}
