//! Uploads spooled flow logs to the portal ingest API.
//!
//! A dedicated thread scans the spool. Each
//! `<root>/<role>/<policy_authorization_id>/` directory holds that authorization's
//! Bearer token plus per-flow reports split into `<flow_identity>.start.json` (open)
//! and `<flow_identity>.end.json` (completed) files. For each authorization the
//! thread:
//!
//! 1. reads the `token`,
//! 2. groups reports by `<flow_identity>` (up to [`MAX_BATCH`], oldest first),
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
//!   next scan once the budget is spent (the files remain).
//! - Other 4xx: permanent; log the status + body (to Sentry) and drop the batch.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    thread::JoinHandle,
    time::{Duration, SystemTime},
};

use backoff::{ExponentialBackoff, ExponentialBackoffBuilder};
use reqwest::{StatusCode, blocking::Client, header};
use serde::Serialize;
use tunnel::{Payload, read_spooled_entry};

/// Maximum flows per upload (matches the portal's per-request limit).
const MAX_BATCH: usize = 10_000;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// Base interval between scans. Kept long so flows accumulate into fuller batches,
/// trading a little latency for far fewer, larger uploads.
const SCAN_INTERVAL: Duration = Duration::from_secs(60);
/// Used instead of [`SCAN_INTERVAL`] when a scan left a backlog (an authorization
/// had more than one batch of flows pending) so we drain it without falling behind.
const CATCHUP_POLL: Duration = Duration::from_secs(1);
/// Total time spent retrying one batch on transient failures before deferring it
/// to the next scan.
const MAX_UPLOAD_RETRY: Duration = Duration::from_secs(5 * 60);

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

/// Spawns the flow-log uploader thread. The thread runs until the process exits.
pub fn spawn(spool_root: PathBuf, ingest_url: String) -> JoinHandle<()> {
    std::thread::Builder::new()
        .name("flow-log-uploader".to_owned())
        .spawn(move || run(&spool_root, &ingest_url))
        .expect("Failed to spawn flow-log uploader thread")
}

fn run(spool_root: &Path, url: &str) {
    let client = match Client::builder().timeout(REQUEST_TIMEOUT).build() {
        Ok(client) => client,
        Err(e) => {
            tracing::error!("Failed to build flow-log HTTP client; uploads disabled: {e:#}");
            return;
        }
    };

    tracing::info!(%url, "Flow-log uploader started");

    loop {
        let backlog = scan(&client, spool_root, url);
        std::thread::sleep(if backlog { CATCHUP_POLL } else { SCAN_INTERVAL });
    }
}

/// Processes every authorization directory once; returns whether any directory
/// still has a backlog (more than one batch pending) that warrants a quick rescan.
///
/// The spool nests authorization directories one level under a `<role>` directory
/// (`<root>/<role>/<policy_authorization_id>/`), so this walks both levels.
fn scan(client: &Client, root: &Path, url: &str) -> bool {
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
            if dir.is_dir() {
                backlog |= process_authz_dir(client, &dir, url);
            }
        }
    }
    backlog
}

/// Reads up to [`MAX_BATCH`] flows from one authorization's spool (oldest first),
/// joins each into a record, and uploads them. Returns whether more than one
/// batch was pending (a backlog), so the caller can rescan promptly.
fn process_authz_dir(client: &Client, dir: &Path, url: &str) -> bool {
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
    let backlog = flows.len() > MAX_BATCH;
    flows.truncate(MAX_BATCH);

    let batch = flows.into_iter().filter_map(load_flow).collect::<Vec<_>>();
    if batch.is_empty() {
        return false;
    }

    submit(client, url, &token, &batch);
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
fn submit(client: &Client, url: &str, token: &str, batch: &[Pending]) {
    if batch.is_empty() {
        return;
    }

    let payloads = batch.iter().map(|flow| &flow.payload).collect::<Vec<_>>();
    let body = match serde_json::to_vec(&Batch {
        flow_logs: &payloads,
    }) {
        Ok(body) => body,
        Err(e) => {
            tracing::error!("Failed to serialize flow-log batch: {e:#}");
            return;
        }
    };

    let mut backoff = upload_backoff();

    loop {
        let response = client
            .post(url)
            .bearer_auth(token)
            .header(header::CONTENT_TYPE, "application/json")
            .body(body.clone())
            .send();

        let response = match response {
            Ok(response) => response,
            Err(e) => {
                tracing::warn!("Flow-log upload request failed: {e:#}");
                if sleep_backoff(&mut backoff) {
                    continue;
                }
                return; // defer to the next scan; the files remain on disk
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
                let body = response.text().unwrap_or_default();
                tracing::error!(%body, "Flow-log batch had validation errors; dropping batch");
                delete_all(batch);
                return;
            }
            StatusCode::PAYLOAD_TOO_LARGE => {
                partition(client, url, token, batch);
                return;
            }
            StatusCode::TOO_MANY_REQUESTS => {
                let wait = retry_after(&response).unwrap_or(CATCHUP_POLL);
                tracing::debug!(?wait, "Flow-log upload rate-limited; waiting");
                std::thread::sleep(wait);
                // Not a failure; keep retrying the same batch without spending the budget.
            }
            StatusCode::REQUEST_TIMEOUT => {
                if !sleep_backoff(&mut backoff) {
                    return;
                }
            }
            _ if status.is_server_error() => {
                tracing::debug!(%status, "Flow-log upload server error; backing off");
                if !sleep_backoff(&mut backoff) {
                    return;
                }
            }
            _ => {
                // Other 4xx (400/401/403/...): permanent. Report and drop.
                let body = response.text().unwrap_or_default();
                tracing::error!(%status, %body, "Flow-log upload rejected; dropping batch");
                delete_all(batch);
                return;
            }
        }
    }
}

/// Splits an over-sized batch in half and submits each (req: partition-and-retry).
fn partition(client: &Client, url: &str, token: &str, batch: &[Pending]) {
    if batch.len() <= 1 {
        tracing::error!("A single flow exceeds the upload size limit; dropping");
        delete_all(batch);
        return;
    }

    let mid = batch.len() / 2;
    submit(client, url, token, &batch[..mid]);
    submit(client, url, token, &batch[mid..]);
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

fn retry_after(response: &reqwest::blocking::Response) -> Option<Duration> {
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
fn sleep_backoff(backoff: &mut ExponentialBackoff) -> bool {
    match backoff.next_backoff() {
        Some(interval) => {
            std::thread::sleep(interval);
            true
        }
        None => false,
    }
}

#[derive(Serialize)]
struct Batch<'a> {
    flow_logs: &'a [&'a Payload],
}
