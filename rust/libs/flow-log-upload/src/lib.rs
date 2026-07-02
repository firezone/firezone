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
//! 2. lists its report files oldest-first (up to the configured batch size),
//!    skipping a `.start` whose `.end` is already on disk: the `.end` is
//!    self-describing and supersedes it,
//! 3. POSTs the batch and, on success, deletes the files it sent (a shipped `.end`
//!    deletes its `.start` too). If a flow's `.end` arrives after its `.start` was
//!    already sent and deleted, it ships as its own record next pass.
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
//! The async fns offload all disk IO to the blocking pool: the HTTP/2 connection
//! driver shares their runtime, so stalling it would starve the connection.
//!
//! [`prune`] removes expired / orphaned spool directories on startup so the spool
//! cannot grow without bound.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
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
/// Suffix of an "open" flow report (see `tunnel::FlowLogWriter`).
const START_SUFFIX: &str = ".start.json";
/// Suffix of a "completed" flow report.
const END_SUFFIX: &str = ".end.json";

/// The portal's flow-log upload config, persisted into the spool root so an uploader
/// that runs independently of the session (a background task / daemon, or the
/// service thread) can read it without a live connection to the portal.
///
/// Only written while uploads are enabled: an `interval` of `0` is never persisted
/// (see [`configure_uploads`]), so the file's presence alone means "enabled".
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

/// Sets the upload config persisted in the spool root. Called by the session, which
/// alone receives it via `init`, so a session-independent uploader can read it.
///
/// An `interval_secs` of `0` means the portal disabled uploads: the persisted config
/// is removed so a running uploader stops, rather than keeping the last one.
pub fn configure_uploads(
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
/// [`configure_uploads`], and uploads over `socket_factory` so it bypasses the
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
    let Some(config) = load_upload_config(spool_root).await else {
        return false;
    };

    upload_pending(spool_root, &config, socket_factory).await
}

/// Removes spooled authorizations whose Bearer token has expired (their flows can
/// no longer be authenticated to the ingest API) and orphaned directories that have
/// no token at all (nothing in them can ever be uploaded). Call on startup, where it
/// never races a writer, so the spool cannot grow without bound.
///
/// Does blocking IO: call it off any async runtime, or wrap it in
/// [`tokio::task::spawn_blocking`].
pub fn prune(spool_root: &Path) {
    let now = unix_now();

    for dir in authz_dirs(spool_root) {
        if !should_prune(&dir, now) {
            continue;
        }

        match std::fs::remove_dir_all(&dir) {
            Ok(()) => tracing::debug!(?dir, "Pruned stale flow-log spool directory"),
            Err(e) => tracing::info!(?dir, "Failed to prune flow-log spool dir: {e:#}"),
        }
    }
}

/// Reads the persisted upload config, or `None` when none is present / valid.
fn read_upload_config(spool_root: &Path) -> Option<UploadConfig> {
    let bytes = std::fs::read(spool_root.join(CONFIG_FILE)).ok()?;

    serde_json::from_slice(&bytes).ok()
}

/// [`read_upload_config`], off the runtime.
async fn load_upload_config(spool_root: &Path) -> Option<UploadConfig> {
    let root = spool_root.to_owned();

    blocking(move || read_upload_config(&root)).await.flatten()
}

/// Runs `f` on the blocking pool, so disk IO never stalls the runtime.
async fn blocking<T, F>(f: F) -> Option<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    match tokio::task::spawn_blocking(f).await {
        Ok(value) => Some(value),
        Err(e) => {
            tracing::error!("Flow-log blocking task failed: {e}");
            None
        }
    }
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

/// The spool holds Bearer tokens, so on Windows every spool directory is locked
/// down to `LocalSystem` and `BUILTIN\Administrators` (the accounts the Gateway /
/// Tunnel service runs as), the equivalent of `0700` on Unix. The directory ACEs
/// inherit, so children get the same access.
#[cfg(windows)]
fn create_dir_secure(path: &Path) -> std::io::Result<()> {
    use windows_security::pipe_dacl::{FileRights, PipeDacl, Trustee};

    std::fs::create_dir_all(path)?;

    let dacl = PipeDacl::new()
        .allow_inheriting(FileRights::FullAccess, Trustee::local_system())
        .allow_inheriting(FileRights::FullAccess, Trustee::builtin_administrators());

    apply_dacl(path, &dacl)
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

/// The equivalent of `0600` on Unix (see [`create_dir_secure`]).
#[cfg(windows)]
fn set_owner_only(path: &Path) -> std::io::Result<()> {
    use windows_security::pipe_dacl::{FileRights, PipeDacl, Trustee};

    let dacl = PipeDacl::new()
        .allow(FileRights::FullAccess, Trustee::local_system())
        .allow(FileRights::FullAccess, Trustee::builtin_administrators());

    apply_dacl(path, &dacl)
}

#[cfg(not(any(unix, windows)))]
fn set_owner_only(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(windows)]
fn apply_dacl(path: &Path, dacl: &windows_security::pipe_dacl::PipeDacl) -> std::io::Result<()> {
    dacl.build()
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
        let delay = match load_upload_config(spool_root).await {
            Some(config) => {
                if upload_pending(spool_root, &config, socket_factory.clone()).await {
                    CATCHUP_POLL
                } else {
                    config.interval
                }
            }
            // No config persisted yet, or uploads disabled by the portal: idle and
            // re-check the config shortly.
            None => DISABLED_POLL,
        };

        tokio::time::sleep(delay).await;
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

/// Uploads one batch of pending flows per authorization directory.
///
/// Returns whether a backlog remains: an authorization had more than one batch
/// pending, or the connection dropped before the pass finished. The caller can then
/// schedule the next pass promptly instead of waiting the configured interval.
async fn upload_pending(
    root: &Path,
    config: &UploadConfig,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> bool {
    let Some(url) = ingest_endpoint(&config.api_url) else {
        return false;
    };

    let client = match connect(&url, socket_factory).await {
        Ok(client) => client,
        Err(e) => {
            tracing::debug!("Failed to open flow-log ingest connection: {e:#}");
            return false;
        }
    };

    let dirs = {
        let root = root.to_owned();

        blocking(move || authz_dirs(&root).collect::<Vec<_>>()).await
    };

    let mut backlog = false;

    for dir in dirs.unwrap_or_default() {
        // The connection died (e.g. roam) before we finished; the next pass
        // re-resolves, reconnects, and drains the rest.
        if client.is_closed() {
            return true;
        }

        backlog |= upload_authz_batch(&client, dir, &url, config.batch_size).await;
    }

    backlog
}

/// Walks the spool's `<root>/<role>/<policy_authorization_id>` layout, yielding each
/// authorization directory. An unreadable level yields nothing.
fn authz_dirs(root: &Path) -> impl Iterator<Item = PathBuf> {
    dir_entries(root)
        .flat_map(|role| dir_entries(&role.path()))
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
}

fn dir_entries(dir: &Path) -> impl Iterator<Item = std::fs::DirEntry> + use<> {
    std::fs::read_dir(dir).into_iter().flatten().flatten()
}

/// Uploads one batch from one authorization's spool. Returns whether more than one
/// batch was pending (a backlog).
async fn upload_authz_batch(
    client: &HttpClient,
    dir: PathBuf,
    url: &str,
    batch_size: usize,
) -> bool {
    let collected = blocking(move || collect_batch(&dir, batch_size))
        .await
        .flatten();

    let Some((token, batch, backlog)) = collected else {
        return false;
    };

    submit(client, url, &token, &batch).await;

    backlog
}

/// Reads one authorization's token and up to `batch_size` flows (oldest first), or
/// `None` when there is nothing to upload. The `bool` reports whether more than one
/// batch was pending.
fn collect_batch(dir: &Path, batch_size: usize) -> Option<(String, Vec<Pending>, bool)> {
    // No token yet (or it was removed): nothing we can upload for this dir.
    let token = std::fs::read_to_string(dir.join("token")).ok()?;

    let files = match report_files(dir) {
        Ok(files) => files,
        Err(e) => {
            tracing::info!(?dir, "Failed to list flow-log spool directory: {e:#}");
            return None;
        }
    };

    let mut batch = Vec::new();
    let mut backlog = false;

    for path in files {
        if batch.len() == batch_size {
            backlog = true;
            break;
        }

        batch.extend(load_flow(&path));
    }

    if batch.is_empty() {
        return None;
    }

    Some((token, batch, backlog))
}

/// Lists a directory's report files, oldest first.
///
/// Directory iteration order is unspecified and report names are flow-identity
/// hashes, so the ordering has to come from mtimes.
fn report_files(dir: &Path) -> std::io::Result<Vec<PathBuf>> {
    let mut files = Vec::new();

    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !name.ends_with(START_SUFFIX) && !name.ends_with(END_SUFFIX) {
            continue;
        }

        let mtime = entry
            .metadata()?
            .modified()
            .unwrap_or(SystemTime::UNIX_EPOCH);
        files.push((mtime, path));
    }

    files.sort();

    Ok(files.into_iter().map(|(_, path)| path).collect())
}

/// Loads the flow reported at `path` into a [`Pending`] upload.
///
/// A `.start` whose `.end` is already on disk yields `None`: the `.end` is
/// self-describing and supersedes it, so only the `.end` ships (deleting both files
/// once it lands). A corrupt report is deleted by [`read_report`] and yields `None`;
/// a superseded `.start` then ships on a later pass.
fn load_flow(path: &Path) -> Option<Pending> {
    let name = path.file_name()?.to_str()?;

    if let Some(stem) = name.strip_suffix(START_SUFFIX) {
        if path.with_file_name(format!("{stem}{END_SUFFIX}")).exists() {
            return None;
        }

        let payload = read_report(path)?;

        return Some(Pending {
            payload,
            files: vec![path.to_owned()],
        });
    }

    let stem = name.strip_suffix(END_SUFFIX)?;
    let payload = read_report(path)?;
    let start = path.with_file_name(format!("{stem}{START_SUFFIX}"));

    Some(Pending {
        payload,
        files: vec![path.to_owned(), start],
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
                delete_all(batch).await;
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
                delete_all(batch).await;
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
        delete_all(batch).await;
        return;
    }

    let mid = batch.len() / 2;
    Box::pin(submit(client, url, token, &batch[..mid])).await;
    Box::pin(submit(client, url, token, &batch[mid..])).await;
}

async fn delete_all(batch: &[Pending]) {
    let files = batch
        .iter()
        .flat_map(|flow| flow.files.clone())
        .collect::<Vec<_>>();

    let _ = blocking(move || delete_files(files)).await;
}

fn delete_files(files: Vec<PathBuf>) {
    for path in files {
        // A shipped `.end` lists its `.start` too, which may already be gone.
        if let Err(e) = std::fs::remove_file(&path)
            && e.kind() != std::io::ErrorKind::NotFound
        {
            tracing::info!(?path, "Failed to delete uploaded flow-log report: {e:#}");
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

    fn write_report(path: &Path) {
        let payload = Payload {
            protocol: "tcp".to_owned(),
            inner_src_ip: "10.0.0.1".parse().unwrap(),
            inner_src_port: 1,
            inner_dst_ip: "10.0.0.2".parse().unwrap(),
            inner_dst_port: 2,
            domain: None,
            outer_src_ip: "192.0.2.1".parse().unwrap(),
            outer_src_port: 3,
            outer_dst_ip: "192.0.2.2".parse().unwrap(),
            outer_dst_port: 4,
            flow_start: chrono::Utc::now(),
            flow_end: None,
            last_packet: None,
            rx_packets: None,
            tx_packets: None,
            rx_bytes: None,
            tx_bytes: None,
        };

        std::fs::write(path, flow_log_spool::serialize(&payload).unwrap()).unwrap();
    }

    fn set_mtime(path: &Path, mtime: SystemTime) {
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(mtime)
            .unwrap();
    }

    #[test]
    fn configure_then_read_config_roundtrips() {
        let root = tempfile::tempdir().unwrap();
        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 90, 500).unwrap();

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
        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 60, 0).unwrap();

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
        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 0, 1000).unwrap();

        assert!(read_upload_config(root.path()).is_none());
    }

    #[test]
    fn disabling_removes_an_existing_config() {
        let root = tempfile::tempdir().unwrap();
        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 60, 500).unwrap();
        assert!(read_upload_config(root.path()).is_some());

        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 0, 500).unwrap();
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
    fn collect_batch_reports_backlog_beyond_batch_size() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("token"), "a-token").unwrap();
        write_report(&dir.path().join("f1.start.json"));
        write_report(&dir.path().join("f1.end.json"));
        write_report(&dir.path().join("f2.start.json"));

        let (token, batch, backlog) = collect_batch(dir.path(), 1).expect("one batch");

        assert_eq!(token, "a-token");
        assert_eq!(batch.len(), 1);
        assert!(backlog, "second flow should count as backlog");
    }

    #[test]
    fn collect_batch_without_token_yields_nothing() {
        let dir = tempfile::tempdir().unwrap();
        write_report(&dir.path().join("f1.start.json"));

        assert!(collect_batch(dir.path(), 10).is_none());
    }

    #[test]
    fn report_files_lists_oldest_first_and_skips_the_token() {
        let dir = tempfile::tempdir().unwrap();
        let now = SystemTime::now();

        std::fs::write(dir.path().join("token"), "a-token").unwrap();
        for (name, age_secs) in [("b.start.json", 10), ("a.end.json", 30), ("c.end.json", 20)] {
            let path = dir.path().join(name);
            std::fs::write(&path, "{}").unwrap();
            set_mtime(&path, now - Duration::from_secs(age_secs));
        }

        let files = report_files(dir.path()).unwrap();
        let names = files
            .iter()
            .map(|path| path.file_name().unwrap().to_str().unwrap())
            .collect::<Vec<_>>();

        assert_eq!(names, ["a.end.json", "c.end.json", "b.start.json"]);
    }

    #[test]
    fn start_with_an_end_on_disk_ships_only_the_end() {
        let dir = tempfile::tempdir().unwrap();
        let start = dir.path().join("f1.start.json");
        let end = dir.path().join("f1.end.json");
        write_report(&start);
        write_report(&end);

        assert!(load_flow(&start).is_none());

        let pending = load_flow(&end).expect("end should load");
        assert_eq!(pending.files, vec![end, start]);
    }

    #[test]
    fn lone_start_ships_by_itself() {
        let dir = tempfile::tempdir().unwrap();
        let start = dir.path().join("f1.start.json");
        write_report(&start);

        let pending = load_flow(&start).expect("start should load");
        assert_eq!(pending.files, vec![start]);
    }

    #[test]
    fn corrupt_report_is_deleted_and_not_uploaded() {
        let dir = tempfile::tempdir().unwrap();
        let end = dir.path().join("f1.end.json");
        std::fs::write(&end, "not a report").unwrap();

        assert!(load_flow(&end).is_none());
        assert!(!end.exists(), "corrupt report should be deleted");
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
