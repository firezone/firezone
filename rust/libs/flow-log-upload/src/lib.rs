//! Uploads spooled flow logs to the portal ingest API.
//!
//! The spool, written by `tunnel::FlowLogWriter`, nests one directory per
//! authorization under a role directory:
//! `<root>/<role>/<policy_authorization_id>/`. Each holds that authorization's
//! Bearer `token` plus per-flow reports: `<flow_start>-<flow_identity>.start.json`
//! (open) and `<flow_start>-<flow_identity>.end.json` (completed), where
//! `<flow_start>` is the flow's start time as zero-padded unix seconds, so lexical
//! name order is oldest-first. Each pass uploads one batch per
//! authorization over the caller's tunnel-bypassing [`SocketFactory`] and deletes
//! what the portal stored; submits are idempotent (the portal upserts by flow
//! identity), so ambiguous failures retry the whole batch.
//!
//! [`spawn`] runs a thread that uploads on the portal's interval, for as long
//! as flows are being produced: process lifetime on the gateway and desktop
//! clients, session lifetime on mobile. [`Uploader::nudge`] skips the current
//! interval; [`Uploader::stop`] ends the thread; spawning and stopping right
//! away yields a one-shot drain.
//!
//! The async fns offload all disk IO to the blocking pool: the HTTP/2 connection
//! driver shares their runtime, so stalling it would starve the connection.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    collections::BinaryHeap,
    path::{Path, PathBuf},
    sync::{Arc, mpsc},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context as _, Result};
use backoff::{ExponentialBackoff, ExponentialBackoffBuilder};
use base64::Engine as _;
use bytes::Bytes;
use flow_log_spool::deserialize;
use http::StatusCode;
use serde::{Deserialize, Serialize};
use serde_with::{DurationSeconds, serde_as};
use socket_factory::{SocketFactory, TcpSocket};

mod ingest;

use ingest::{IngestClient, body_string, ingest_endpoint, retry_after};

/// Default flows per upload when the portal doesn't specify one.
const DEFAULT_BATCH_SIZE: usize = 1_000;
/// Hard ceiling on flows per upload (the portal's per-request limit).
const MAX_BATCH_SIZE: usize = 10_000;
/// Poll used instead of the configured interval while a backlog remains.
const CATCHUP_POLL: Duration = Duration::from_secs(1);
/// How often to re-check config while uploads are unconfigured or disabled.
const DISABLED_POLL: Duration = Duration::from_secs(30);
/// Total time spent retrying one batch on transient failures before deferring it
/// to the next pass.
const MAX_UPLOAD_RETRY: Duration = Duration::from_secs(5 * 60);
const CONFIG_FILE: &str = "upload.json";
const START_SUFFIX: &str = ".start.json";
const END_SUFFIX: &str = ".end.json";

/// The portal's upload config, persisted into the spool root so an uploader that
/// runs independently of the session can read it.
///
/// Only present while uploads are enabled (see [`configure_uploads`]).
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

/// Persists the portal's upload config into the spool root.
///
/// An `interval_secs` of `0` means uploads are disabled: any persisted config is
/// removed so a running uploader stops.
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

/// Handle to a spawned uploader thread.
///
/// Dropping it detaches the thread; it keeps running until the process exits.
#[derive(Clone)]
pub struct Uploader {
    commands: mpsc::Sender<Command>,
}

enum Command {
    /// Run an upload pass now instead of waiting out the interval.
    Upload,
    /// Exit the thread, acknowledging on `done` first.
    Shutdown { done: mpsc::Sender<()> },
}

impl Uploader {
    /// Wakes the uploader to run a pass now; returns whether the thread was
    /// alive to see it.
    pub fn nudge(&self) -> bool {
        self.commands.send(Command::Upload).is_ok()
    }

    /// Stops the thread once already-queued work (e.g. a nudge's pass) is done.
    /// With `flush`, blocks until it acknowledges or the timeout elapses.
    pub fn stop(&self, flush: Option<Duration>) -> bool {
        let (done, acked) = mpsc::channel();

        if self.commands.send(Command::Shutdown { done }).is_err() {
            return false;
        }

        let Some(timeout) = flush else {
            return false;
        };

        acked.recv_timeout(timeout).is_ok()
    }
}

/// Spawns the uploader thread with an immediate first pass queued; it prunes
/// the spool on start and re-reads the persisted config each pass.
pub fn spawn(spool_root: PathBuf, socket_factory: Arc<dyn SocketFactory<TcpSocket>>) -> Uploader {
    let (commands, inbox) = mpsc::channel();

    let uploader = Uploader { commands };
    uploader.nudge();

    std::thread::Builder::new()
        .name("flow-log-uploader".to_owned())
        .spawn({
            // The thread holds a sender too, so dropping the handle detaches
            // rather than stops it (gateway and desktop drop it right away).
            let keep_alive = uploader.clone();

            move || {
                let _keep_alive = keep_alive;

                prune(&spool_root);
                run(&spool_root, socket_factory, &inbox);
            }
        })
        .expect("Failed to spawn flow-log uploader thread");

    uploader
}

/// The uploader's event loop: sleeps until the next interval or an earlier
/// [`Command`], then acts on whichever arrived.
fn run(
    spool_root: &Path,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    commands: &mpsc::Receiver<Command>,
) {
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

    tracing::info!("Flow-log uploader started");

    let mut delay = DISABLED_POLL;

    loop {
        match commands.recv_timeout(delay) {
            Ok(Command::Upload) | Err(mpsc::RecvTimeoutError::Timeout) => {
                delay = runtime.block_on(upload_pass(spool_root, socket_factory.clone()));
            }
            Ok(Command::Shutdown { done }) => {
                let _ = done.send(());
                tracing::info!("Flow-log uploader stopped");
                return;
            }
            // Unreachable while the thread holds its own sender.
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }
    }
}

/// Runs one upload pass; returns how long to wait before the next.
async fn upload_pass(
    spool_root: &Path,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Duration {
    match load_upload_config(spool_root).await {
        Ok(Some(config)) => match upload_pending(spool_root, &config, socket_factory).await {
            Ok(true) => CATCHUP_POLL,
            Ok(false) => config.interval,
            Err(e) => {
                tracing::error!("Flow-log upload pass failed: {e:#}");
                config.interval
            }
        },
        Ok(None) => DISABLED_POLL,
        Err(e) => {
            tracing::error!("Failed to load flow-log upload config: {e:#}");
            DISABLED_POLL
        }
    }
}

/// Removes authorization directories whose token has expired or is missing, since
/// nothing in them can ever be uploaded. Runs on startup and at the top of every
/// upload pass, so the spool cannot grow without bound.
///
/// Racing the writer is benign: freshly-created directories are exempt (see
/// [`should_prune`]), a re-authorization always gets a fresh directory, and a
/// report written into a just-pruned directory fails to write and belonged to
/// an expired authorization the portal would reject anyway.
///
/// Does blocking IO: call it off any async runtime.
pub fn prune(spool_root: &Path) {
    let now = unix_now();

    let dirs = match authz_dirs(spool_root) {
        Ok(dirs) => dirs,
        Err(e) => {
            tracing::warn!("Failed to walk flow-log spool: {e:#}");
            return;
        }
    };

    for dir in dirs {
        if !should_prune(&dir, now) {
            continue;
        }

        match std::fs::remove_dir_all(&dir) {
            Ok(()) => tracing::debug!(?dir, "Pruned stale flow-log spool directory"),
            Err(e) => tracing::warn!(?dir, "Failed to prune flow-log spool dir: {e:#}"),
        }
    }
}

/// Reads the persisted upload config; `Ok(None)` when uploads are not configured.
fn read_upload_config(spool_root: &Path) -> Result<Option<UploadConfig>> {
    let bytes = match std::fs::read(spool_root.join(CONFIG_FILE)) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e).context("Failed to read upload config"),
    };

    let config = serde_json::from_slice(&bytes).context("Failed to parse upload config")?;

    Ok(Some(config))
}

/// [`read_upload_config`], off the runtime.
async fn load_upload_config(spool_root: &Path) -> Result<Option<UploadConfig>> {
    let root = spool_root.to_owned();

    blocking(move || read_upload_config(&root)).await?
}

/// Runs `f` on the blocking pool, so disk IO never stalls the runtime.
///
/// Used instead of `tokio::fs`, which dispatches per syscall: a pass makes
/// hundreds of small fs calls, so each phase does one hop as a whole.
async fn blocking<T, F>(f: F) -> Result<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .context("Blocking task failed")
}

fn clamp_batch_size(batch_size: u64) -> usize {
    match usize::try_from(batch_size).unwrap_or(MAX_BATCH_SIZE) {
        0 => DEFAULT_BATCH_SIZE,
        n => n.min(MAX_BATCH_SIZE),
    }
}

/// A missing token is pruned; an unreadable or undecodable one is kept, so a
/// transient failure never deletes uploadable data.
///
/// Reports are only spooled once their token is on disk, so a missing or
/// undecodable one is a bug. A freshly-created directory is exempt: its token
/// may not be written yet (`write_token` creates the directory first), and a
/// prune racing that write must not delete it.
fn should_prune(dir: &Path, now: u64) -> bool {
    let token = match std::fs::read_to_string(dir.join("token")) {
        Ok(token) => token,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound && is_recently_modified(dir) => {
            return false;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            tracing::error!(?dir, "Flow-log spool directory has no ingest token");
            return true;
        }
        Err(e) => {
            tracing::warn!(?dir, "Failed to read ingest token: {e:#}");
            return false;
        }
    };

    match token_expiry(&token) {
        Ok(exp) => exp <= now,
        Err(e) => {
            tracing::error!(?dir, "Failed to decode ingest token expiry: {e:#}");
            false
        }
    }
}

/// Errs on the side of "recent" (keeping the directory) when the metadata or
/// clock is unreadable.
fn is_recently_modified(dir: &Path) -> bool {
    const MIN_PRUNE_AGE: Duration = Duration::from_secs(60);

    std::fs::metadata(dir)
        .and_then(|meta| meta.modified())
        .map(|modified| match modified.elapsed() {
            Ok(age) => age < MIN_PRUNE_AGE,
            // A modification time in the future counts as recent.
            Err(_) => true,
        })
        .unwrap_or(true)
}

/// Decodes the `exp` (unix seconds) claim from an ingest token's JWT payload
/// without verifying its signature.
fn token_expiry(token: &str) -> Result<u64> {
    #[derive(Deserialize)]
    struct Claims {
        exp: u64,
    }

    let payload = token.split('.').nth(1).context("Token is not a JWT")?;
    let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .context("Failed to decode token payload")?;
    let claims = serde_json::from_slice::<Claims>(&json).context("Failed to parse token claims")?;

    Ok(claims.exp)
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Writes `bytes` to `path`, readable only by the owner (the spool holds Bearer
/// tokens).
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

/// Locks the directory down to `LocalSystem` and `BUILTIN\Administrators` (the
/// service accounts), the equivalent of `0700` on Unix; the ACEs inherit to
/// children.
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

/// One flow to upload: the record to send and the files to delete once it lands.
struct Pending {
    payload: serde_json::Value,
    files: Vec<PathBuf>,
}

/// Uploads one batch of pending flows per authorization directory.
///
/// Returns whether a backlog remains: an authorization had more than one batch
/// pending, or the connection dropped before the pass finished.
async fn upload_pending(
    root: &Path,
    config: &UploadConfig,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<bool> {
    let url = ingest_endpoint(&config.api_url)?;

    // Tokens expire mid-session on long-running gateways; sweep their
    // directories before walking the spool so they cannot accumulate
    // between restarts.
    {
        let root = root.to_owned();

        blocking(move || prune(&root)).await?;
    }

    // Routine while the device is offline or roaming; try again next pass.
    let mut client = match IngestClient::connect(url, socket_factory).await {
        Ok(client) => client,
        Err(e) => {
            tracing::info!("Failed to open flow-log ingest connection: {e:#}");
            return Ok(false);
        }
    };

    let dirs = {
        let root = root.to_owned();

        match blocking(move || authz_dirs(&root)).await? {
            Ok(dirs) => dirs,
            Err(e) => {
                tracing::warn!("Failed to walk flow-log spool: {e:#}");
                return Ok(false);
            }
        }
    };

    let mut backlog = false;

    for dir in dirs {
        // The connection died (e.g. roam); the next pass reconnects and drains the rest.
        if client.is_closed() {
            return Ok(true);
        }

        match upload_authz_batch(&mut client, &dir, config.batch_size).await {
            Ok(more) => backlog |= more,
            // One broken directory must not block the others.
            Err(e) => tracing::warn!(?dir, "Failed to upload flow-log batch: {e:#}"),
        }
    }

    Ok(backlog)
}

/// Walks the spool's `<root>/<role>/<policy_authorization_id>` layout, listing each
/// authorization directory. A missing level lists as empty (nothing spooled yet).
fn authz_dirs(root: &Path) -> Result<Vec<PathBuf>> {
    let mut dirs = Vec::new();

    for role in read_dir_or_empty(root)? {
        if !role.is_dir() {
            continue;
        }

        dirs.extend(read_dir_or_empty(&role)?.into_iter().filter(|p| p.is_dir()));
    }

    Ok(dirs)
}

fn read_dir_or_empty(dir: &Path) -> Result<Vec<PathBuf>> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e).with_context(|| format!("Failed to read {}", dir.display())),
    };

    entries
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<std::io::Result<Vec<_>>>()
        .with_context(|| format!("Failed to read {}", dir.display()))
}

/// Uploads one batch from one authorization's spool. Returns whether more than one
/// batch was pending (a backlog).
async fn upload_authz_batch(
    client: &mut IngestClient,
    dir: &Path,
    batch_size: usize,
) -> Result<bool> {
    let collected = {
        let dir = dir.to_owned();

        blocking(move || collect_batch(&dir, batch_size)).await??
    };

    let Some((token, batch, backlog)) = collected else {
        return Ok(false);
    };

    let outcome = submit(client, &token, &batch).await?;

    // Coming straight back to a batch the portal just refused would only be
    // refused again; the next pass is soon enough.
    Ok(backlog && outcome == BatchOutcome::Stored)
}

/// Reads one authorization's token and up to `batch_size` flows (oldest first), or
/// `Ok(None)` when there is nothing to upload. The `bool` reports whether more than
/// one batch was pending.
fn collect_batch(dir: &Path, batch_size: usize) -> Result<Option<(String, Vec<Pending>, bool)>> {
    let token = match std::fs::read_to_string(dir.join("token")) {
        Ok(token) => token,
        // The writer creates the token before any report, so this is a bug.
        // Nothing here can be uploaded; the next prune removes the directory.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            tracing::error!(?dir, "Flow-log spool directory has no ingest token");
            return Ok(None);
        }
        Err(e) => return Err(e).context("Failed to read ingest token"),
    };

    // A completed flow is two files, so this many always hold a full batch.
    let (files, mut backlog) =
        report_files(dir, 2 * batch_size).context("Failed to list reports")?;

    let mut batch = Vec::new();

    for path in files {
        if batch.len() == batch_size {
            backlog = true;
            break;
        }

        match load_flow(&path) {
            Ok(Some(pending)) => batch.push(pending),
            Ok(None) => {}
            // One unreadable report must not block the rest; it stays on disk
            // for the next pass.
            Err(e) => tracing::warn!(?path, "Failed to load flow-log report: {e:#}"),
        }
    }

    if batch.is_empty() {
        return Ok(None);
    }

    Ok(Some((token, batch, backlog)))
}

/// Lists a directory's oldest report files, at most `limit`, oldest first. The
/// `bool` reports whether any were left out.
///
/// Report names start with the flow's zero-padded start timestamp and `read_dir`
/// order is unspecified, so lexical name order is oldest-first. Only the oldest
/// `limit` are held while walking the directory: a spool that could not be
/// uploaded for a while holds millions of reports, and listing them all costs
/// memory proportional to the spool on every pass.
fn report_files(dir: &Path, limit: usize) -> std::io::Result<(Vec<PathBuf>, bool)> {
    let mut oldest = BinaryHeap::new();
    let mut left_out = false;

    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !name.ends_with(START_SUFFIX) && !name.ends_with(END_SUFFIX) {
            continue;
        }

        oldest.push(path);

        if oldest.len() > limit {
            oldest.pop();
            left_out = true;
        }
    }

    Ok((oldest.into_sorted_vec(), left_out))
}

/// Loads the flow reported at `path` into a [`Pending`] upload.
///
/// `Ok(None)` when there is nothing to ship: a `.start` whose `.end` is on disk
/// (the `.end` is self-describing and supersedes it, deleting both files when it
/// ships), or a corrupt report.
fn load_flow(path: &Path) -> Result<Option<Pending>> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .context("Invalid report file name")?;

    if let Some(stem) = name.strip_suffix(START_SUFFIX) {
        if path.with_file_name(format!("{stem}{END_SUFFIX}")).exists() {
            return Ok(None);
        }

        return Ok(read_report(path)?.map(|payload| Pending {
            payload,
            files: vec![path.to_owned()],
        }));
    }

    let stem = name.strip_suffix(END_SUFFIX).context("Not a report file")?;
    let start = path.with_file_name(format!("{stem}{START_SUFFIX}"));

    Ok(read_report(path)?.map(|payload| Pending {
        payload,
        files: vec![path.to_owned(), start],
    }))
}

/// Reads and verifies one report. A corrupt report yields `Ok(None)` and is
/// deleted: it can never be uploaded, and leaving it would wedge the spool.
///
/// Malformed JSON is a bug (reports are written atomically); a CRC mismatch is
/// the checksum catching environmental corruption, working as designed.
fn read_report(path: &Path) -> Result<Option<serde_json::Value>> {
    let bytes = std::fs::read(path).context("Failed to read report")?;

    match deserialize(&bytes) {
        Ok(payload) => Ok(Some(payload)),
        Err(e @ flow_log_spool::Error::Malformed(_)) => {
            tracing::error!(?path, "Corrupt flow-log report, deleting: {e}");
            let _ = std::fs::remove_file(path);
            Ok(None)
        }
        Err(e @ flow_log_spool::Error::ChecksumMismatch { .. }) => {
            tracing::warn!(?path, "Flow-log report failed its checksum, deleting: {e}");
            let _ = std::fs::remove_file(path);
            Ok(None)
        }
    }
}

/// Submits one batch with response-specific handling. Idempotent, so transient
/// failures retry the whole batch.
async fn submit(client: &mut IngestClient, token: &str, batch: &[Pending]) -> Result<BatchOutcome> {
    if batch.is_empty() {
        return Ok(BatchOutcome::Stored);
    }

    let payloads = batch.iter().map(|flow| &flow.payload).collect::<Vec<_>>();
    let body = serde_json::to_vec(&Batch {
        flow_logs: &payloads,
    })
    .context("Failed to serialize flow-log batch")?;
    let body = Bytes::from(body);

    let mut backoff = upload_backoff();

    loop {
        let response = match client.send(token, body.clone()).await {
            Ok(response) => response,
            Err(e) => {
                tracing::info!("Flow-log upload request failed: {e:#}");
                // A closed connection won't recover by retrying; defer to the next pass.
                if client.is_closed() || !sleep_backoff(&mut backoff).await {
                    return Ok(BatchOutcome::Spooled);
                }
                continue;
            }
        };

        let status = response.status();
        match classify_response(status) {
            ResponseAction::Delete => {
                tracing::debug!(flows = batch.len(), "Uploaded flow-log batch");
                delete_all(batch).await;
                return Ok(BatchOutcome::Stored);
            }
            ResponseAction::Partition => {
                return partition(client, token, batch).await;
            }
            ResponseAction::RateLimited => {
                let wait = retry_after(&response).unwrap_or(CATCHUP_POLL);
                tracing::debug!(?wait, "Flow-log upload rate-limited; waiting");
                tokio::time::sleep(wait).await;
                // Not a failure; keep retrying the same batch without spending the budget.
            }
            ResponseAction::Retry => {
                tracing::info!(%status, "Flow-log upload transient failure; backing off");
                if !sleep_backoff(&mut backoff).await {
                    return Ok(BatchOutcome::Spooled);
                }
            }
            ResponseAction::Redirect => client.follow_redirect(&response).await?,
            ResponseAction::Defer => {
                let body = body_string(&response);
                tracing::info!(%status, %body, "Flow-log upload rejected; keeping the batch");
                return Ok(BatchOutcome::Spooled);
            }
        }
    }
}

/// Where a batch ended up once [`submit`] returned.
#[derive(Clone, Copy, PartialEq, Debug)]
enum BatchOutcome {
    /// The portal stored the batch and its files are deleted.
    Stored,
    /// The batch is still spooled for a later pass to retry.
    Spooled,
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
    /// Redirected (301 / 302 / 307 / 308); reconnect if needed and replay the POST.
    Redirect,
    /// Rejected (4xx) or redirected somewhere a POST cannot follow (303); keep the
    /// batch on disk. Nothing was stored, and the reason is as likely to be a
    /// portal bug or a middlebox as a batch the portal can never accept, so a
    /// later pass tries afresh. Its token bounds the wait: [`prune`] deletes the
    /// directory once that expires.
    Defer,
}

/// Only a response the portal answered with is classified here; a 2xx is the sole
/// status that lets a batch be deleted.
fn classify_response(status: StatusCode) -> ResponseAction {
    match status {
        s if s.is_success() => ResponseAction::Delete,
        StatusCode::PAYLOAD_TOO_LARGE => ResponseAction::Partition,
        StatusCode::TOO_MANY_REQUESTS => ResponseAction::RateLimited,
        StatusCode::REQUEST_TIMEOUT => ResponseAction::Retry,
        s if s.is_server_error() => ResponseAction::Retry,
        // 303 is absent: it mandates a GET, which cannot carry the batch.
        StatusCode::MOVED_PERMANENTLY
        | StatusCode::FOUND
        | StatusCode::TEMPORARY_REDIRECT
        | StatusCode::PERMANENT_REDIRECT => ResponseAction::Redirect,
        _ => ResponseAction::Defer,
    }
}

/// Splits an over-sized batch in half and submits each.
async fn partition(
    client: &mut IngestClient,
    token: &str,
    batch: &[Pending],
) -> Result<BatchOutcome> {
    if batch.len() <= 1 {
        tracing::warn!("A single flow exceeds the upload size limit; keeping it");
        return Ok(BatchOutcome::Spooled);
    }

    let mid = batch.len() / 2;
    let first = Box::pin(submit(client, token, &batch[..mid])).await?;
    let second = Box::pin(submit(client, token, &batch[mid..])).await?;

    Ok(match (first, second) {
        (BatchOutcome::Stored, BatchOutcome::Stored) => BatchOutcome::Stored,
        _ => BatchOutcome::Spooled,
    })
}

async fn delete_all(batch: &[Pending]) {
    let files = batch
        .iter()
        .flat_map(|flow| flow.files.clone())
        .collect::<Vec<_>>();

    if let Err(e) = blocking(move || delete_files(files)).await {
        tracing::warn!("Failed to delete uploaded flow-log reports: {e:#}");
    }
}

fn delete_files(files: Vec<PathBuf>) {
    let count = files.len();

    for path in files {
        // A shipped `.end` lists its `.start` too, which may already be gone.
        if let Err(e) = std::fs::remove_file(&path)
            && e.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(?path, "Failed to delete uploaded flow-log report: {e:#}");
        }
    }

    tracing::debug!(count, "Deleted uploaded flow-log reports");
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
    flow_logs: &'a [&'a serde_json::Value],
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
        let payload = serde_json::json!({
            "protocol": "tcp",
            "inner_src_ip": "10.0.0.1",
            "inner_src_port": 1,
            "inner_dst_ip": "10.0.0.2",
            "inner_dst_port": 2,
            "flow_start": chrono::Utc::now().to_rfc3339(),
        });

        std::fs::write(path, flow_log_spool::serialize(&payload).unwrap()).unwrap();
    }

    #[test]
    fn configure_then_read_config_roundtrips() {
        let root = tempfile::tempdir().unwrap();
        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 90, 500).unwrap();

        let config = read_upload_config(root.path())
            .unwrap()
            .expect("config present");
        assert_eq!(config.api_url, "https://flow-api.firezone.dev/");
        assert_eq!(config.interval, Duration::from_secs(90));
        assert_eq!(config.batch_size, 500);
    }

    #[test]
    fn zero_batch_size_uses_default() {
        let root = tempfile::tempdir().unwrap();
        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 60, 0).unwrap();

        let config = read_upload_config(root.path())
            .unwrap()
            .expect("config present");
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

        assert!(read_upload_config(root.path()).unwrap().is_none());
    }

    #[test]
    fn disabling_removes_an_existing_config() {
        let root = tempfile::tempdir().unwrap();
        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 60, 500).unwrap();
        assert!(read_upload_config(root.path()).unwrap().is_some());

        configure_uploads(root.path(), "https://flow-api.firezone.dev/", 0, 500).unwrap();
        assert!(read_upload_config(root.path()).unwrap().is_none());
    }

    #[test]
    fn missing_config_disables_uploads() {
        let root = tempfile::tempdir().unwrap();

        assert!(read_upload_config(root.path()).unwrap().is_none());
    }

    #[test]
    fn corrupt_config_is_an_error() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join(CONFIG_FILE), "not json").unwrap();

        assert!(read_upload_config(root.path()).is_err());
    }

    #[test]
    fn token_expiry_reads_exp_claim() {
        assert_eq!(
            token_expiry(&token_expiring_at(1_700_000_000)).unwrap(),
            1_700_000_000
        );
        assert!(token_expiry("not-a-jwt").is_err());
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

        // No token and not fresh: can never be uploaded, so pruned.
        let orphan = root.path().join("responder").join("orphan-pa");
        std::fs::create_dir_all(&orphan).unwrap();
        std::fs::write(orphan.join("a.start.json"), "{}").unwrap();
        backdate(&orphan);

        // No token but freshly created: `write_token` may be about to write
        // it, so it must survive the prune.
        let fresh = root.path().join("responder").join("fresh-pa");
        std::fs::create_dir_all(&fresh).unwrap();

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
        assert!(
            fresh.exists(),
            "freshly-created token-less dir should be kept"
        );
    }

    fn backdate(dir: &Path) {
        let mtime = filetime::FileTime::from_unix_time(unix_now() as i64 - 3600, 0);

        filetime::set_file_mtime(dir, mtime).unwrap();
    }

    #[test]
    fn collect_batch_reports_backlog_beyond_batch_size() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("token"), "a-token").unwrap();
        write_report(&dir.path().join("f1.start.json"));
        write_report(&dir.path().join("f1.end.json"));
        write_report(&dir.path().join("f2.start.json"));

        let (token, batch, backlog) = collect_batch(dir.path(), 1).unwrap().expect("one batch");

        assert_eq!(token, "a-token");
        assert_eq!(batch.len(), 1);
        assert!(backlog, "second flow should count as backlog");
    }

    #[test]
    fn collect_batch_without_token_yields_nothing() {
        let dir = tempfile::tempdir().unwrap();
        write_report(&dir.path().join("f1.start.json"));

        assert!(collect_batch(dir.path(), 10).unwrap().is_none());
    }

    #[test]
    fn report_files_lists_oldest_first_and_skips_the_token() {
        let dir = tempfile::tempdir().unwrap();

        std::fs::write(dir.path().join("token"), "a-token").unwrap();
        for name in [
            "1700000030-bbb.start.json",
            "1700000010-aaa.end.json",
            "1700000020-ccc.end.json",
        ] {
            std::fs::write(dir.path().join(name), "{}").unwrap();
        }

        let (files, left_out) = report_files(dir.path(), 10).unwrap();

        assert_eq!(
            file_names(&files),
            [
                "1700000010-aaa.end.json",
                "1700000020-ccc.end.json",
                "1700000030-bbb.start.json"
            ]
        );
        assert!(!left_out);
    }

    #[test]
    fn report_files_keeps_only_the_oldest_up_to_the_limit() {
        let dir = tempfile::tempdir().unwrap();

        for name in [
            "1700000040-ddd.start.json",
            "1700000010-aaa.end.json",
            "1700000030-ccc.end.json",
            "1700000020-bbb.start.json",
        ] {
            std::fs::write(dir.path().join(name), "{}").unwrap();
        }

        let (files, left_out) = report_files(dir.path(), 2).unwrap();

        assert_eq!(
            file_names(&files),
            ["1700000010-aaa.end.json", "1700000020-bbb.start.json"]
        );
        assert!(left_out);
    }

    fn file_names(files: &[PathBuf]) -> Vec<&str> {
        files
            .iter()
            .map(|path| path.file_name().unwrap().to_str().unwrap())
            .collect()
    }

    #[test]
    fn start_with_an_end_on_disk_ships_only_the_end() {
        let dir = tempfile::tempdir().unwrap();
        let start = dir.path().join("f1.start.json");
        let end = dir.path().join("f1.end.json");
        write_report(&start);
        write_report(&end);

        assert!(load_flow(&start).unwrap().is_none());

        let pending = load_flow(&end).unwrap().expect("end should load");
        assert_eq!(pending.files, vec![end, start]);
    }

    #[test]
    fn lone_start_ships_by_itself() {
        let dir = tempfile::tempdir().unwrap();
        let start = dir.path().join("f1.start.json");
        write_report(&start);

        let pending = load_flow(&start).unwrap().expect("start should load");
        assert_eq!(pending.files, vec![start]);
    }

    #[test]
    fn corrupt_report_is_deleted_and_not_uploaded() {
        let dir = tempfile::tempdir().unwrap();
        let end = dir.path().join("f1.end.json");
        std::fs::write(&end, "not a report").unwrap();

        assert!(load_flow(&end).unwrap().is_none());
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
        assert_eq!(classify_response(StatusCode::MOVED_PERMANENTLY), Redirect);
        assert_eq!(classify_response(StatusCode::FOUND), Redirect);
        assert_eq!(classify_response(StatusCode::TEMPORARY_REDIRECT), Redirect);
        assert_eq!(classify_response(StatusCode::PERMANENT_REDIRECT), Redirect);
        assert_eq!(classify_response(StatusCode::SEE_OTHER), Defer);
        assert_eq!(classify_response(StatusCode::NOT_MODIFIED), Defer);
        assert_eq!(classify_response(StatusCode::UNPROCESSABLE_ENTITY), Defer);
        assert_eq!(classify_response(StatusCode::BAD_REQUEST), Defer);
        assert_eq!(classify_response(StatusCode::UNAUTHORIZED), Defer);
        assert_eq!(classify_response(StatusCode::FORBIDDEN), Defer);
        assert_eq!(classify_response(StatusCode::NOT_FOUND), Defer);
    }

    #[test]
    fn stop_acks_after_queued_passes_before_the_timeout() {
        let root = tempfile::tempdir().unwrap();
        let uploader = spawn(root.path().to_owned(), Arc::new(socket_factory::tcp));

        assert!(uploader.stop(Some(Duration::from_secs(10))));
    }

    #[test]
    fn stop_without_flush_returns_immediately() {
        let root = tempfile::tempdir().unwrap();
        let uploader = spawn(root.path().to_owned(), Arc::new(socket_factory::tcp));

        assert!(!uploader.stop(None));
    }

    #[test]
    fn nudge_reports_whether_the_thread_is_alive() {
        let root = tempfile::tempdir().unwrap();
        let uploader = spawn(root.path().to_owned(), Arc::new(socket_factory::tcp));

        assert!(uploader.nudge());
        assert!(uploader.stop(Some(Duration::from_secs(10))));

        // The ack precedes the thread dropping its receiver by an instant.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while uploader.nudge() {
            assert!(
                std::time::Instant::now() < deadline,
                "thread should exit after stop"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
