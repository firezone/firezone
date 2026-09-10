//! Spools flow-log records to disk for later upload to the portal ingest API.
//!
//! Flow logs travel from the data plane to this writer as structured `tracing`
//! events (target `flow_logs`): [`layer`] returns a subscriber layer that each
//! entrypoint installs as part of its tracing configuration, so the tunnel itself
//! needs no knowledge of where (or whether) flow logs are persisted.
//!
//! Reports are grouped by the flow's `role` and `policy_authorization_id` into a
//! per-authorization sub-directory holding that authorization's Bearer token and
//! one file per flow report, split into an "open" and a "completed" report:
//!
//! ```text
//! <root>/<role>/<policy_authorization_id>/
//!   token                                    # the Bearer JWT for this authorization
//!   <flow_start>-<flow_identity>.start.json  # { "checksum": <crc32>, "payload": { open report } }
//!   <flow_start>-<flow_identity>.end.json    # { "checksum": <crc32>, "payload": { completed report } }
//! ```
//!
//! The `<role>` level (`initiator` / `responder`) separates the two perspectives a
//! single device can log: a Gateway is always the responder, while a Client can be
//! the initiator of some flows and the responder of others.
//!
//! The Bearer token deliberately does NOT ride the tracing events (a broad `trace`
//! directive would copy it into log files); the eventloops receive it in the
//! portal's authorization messages and persist it via [`write_token`] instead.
//! A report's payload is the event's record fields as emitted (see
//! [`RECORD_FIELDS`]), with the JSON-encoded `outers` field decoded into its
//! array; attribution deliberately rides only the token, and the portal
//! validates the payload on ingest, so beyond that the writer only interprets
//! what routing and naming need.
//!
//! `<flow_start>` is the flow's start time as zero-padded unix seconds, so a
//! lexical sort of the report names is oldest-first and the uploader needs no
//! per-file metadata. `<flow_identity>` hashes the fields that identify a flow
//! within an authorization (protocol, inner 4-tuple, flow_start), so a flow's open
//! and completed reports share a stem. The `.end` report is self-describing (it
//! carries the full report, not just the closing fields), so the uploader can send
//! it on its own even after the `.start` has already been uploaded and deleted.
//! Writing the completed report to its own file (rather than overwriting the open
//! one) keeps both write-once, so the uploader can delete one without racing a
//! concurrent write of the other.
//!
//! Two things bound what the spool costs a device. It occupies at most
//! [`SPOOL_BUDGET_BYTES`], charged in the volume's own allocation units, so a
//! stretch the uploader cannot drain (an offline client, uploads disabled)
//! settles at a fixed amount of disk instead of growing until the disk is full.
//! And a write that runs out of disk parks the writes after it for
//! [`DISK_FULL_COOLDOWN`], so a disk filled by anything else costs one failed
//! write per cooldown rather than one per flow.
//!
//! Each report is written immediately as an atomic, fsync'd file, so nothing
//! already produced is lost on an unclean exit. Writing happens on a dedicated
//! thread fed by a channel so the per-file fsync never blocks the packet-processing
//! event loop; hold the returned [`Guard`] until process exit so the thread's
//! backlog is drained before shutdown. The spool holds Bearer tokens and flow
//! payloads, so its directories and files get restrictive permissions (0700 /
//! 0600) and it lives outside the log directory, so an exported log bundle never
//! sweeps it up.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    hash::{Hash as _, Hasher as _},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

use anyhow::{Context as _, ErrorExt as _};
use base64::Engine as _;
use chrono::DateTime;
use flow_log_spool::serialize;
use tracing::field::{Field, Visit};
use tracing_subscriber::registry::LookupSpan;

/// How many reports may queue for the writer thread before new ones are dropped.
///
/// Reports are a few hundred bytes each, so this bounds worst-case memory while
/// absorbing flow-churn bursts (e.g. a port scan opening many flows at once)
/// faster than the per-report fsync can drain them. Mobile gets a smaller buffer;
/// it has less memory headroom and the OS may kill the tunnel process under
/// memory pressure.
const CHANNEL_CAPACITY: usize = if cfg!(any(target_os = "ios", target_os = "android")) {
    1_000
} else {
    10_000
};

/// How much disk the spool may occupy. Mobile gets less, for the same reasons as
/// [`CHANNEL_CAPACITY`].
const SPOOL_BUDGET_BYTES: u64 = if cfg!(any(target_os = "ios", target_os = "android")) {
    32 * 1024 * 1024
} else {
    256 * 1024 * 1024
};

/// Charged per report when the volume does not report its allocation unit. The
/// common default across NTFS, ext4 and APFS.
const DEFAULT_CLUSTER_BYTES: u64 = 4096;

/// How long a write that ran out of disk parks the ones after it.
const DISK_FULL_COOLDOWN: Duration = Duration::from_secs(60);

/// How often a full spool is re-counted to pick up the uploader's deletions.
const RECOUNT_INTERVAL: Duration = Duration::from_secs(10);

/// Creates the flow-log spooling layer plus the [`Guard`] keeping it durable.
///
/// Keep the guard alive until process exit; dropping it drains and joins the
/// writer thread.
pub fn layer<S>(spool_root: PathBuf) -> (impl tracing_subscriber::Layer<S>, Guard)
where
    S: tracing::Subscriber + for<'a> LookupSpan<'a>,
{
    use tracing_subscriber::Layer as _;

    let (tx, rx) = mpsc::sync_channel::<Command>(CHANNEL_CAPACITY);
    let handle = std::thread::Builder::new()
        .name("flow-log-writer".to_owned())
        .spawn({
            let spool_root = spool_root.clone();

            move || writer_loop(&spool_root, &rx)
        })
        .expect("Failed to spawn flow-log writer thread");

    let layer = FlowLogLayer {
        tx: tx.clone(),
        dropped: AtomicU64::new(0),
    }
    .with_filter(
        tracing_subscriber::filter::Targets::new().with_target("flow_logs", tracing::Level::TRACE),
    );

    (
        layer,
        Guard {
            tx,
            spool_root,
            handle: Some(handle),
        },
    )
}

/// Persists an authorization's ingest token where the uploader expects it.
///
/// The spool path derives from the token's (unverified) `role` and
/// `policy_authorization_id` claims, which are validated first.
pub fn write_token(spool_root: &Path, token: &str) -> anyhow::Result<()> {
    #[derive(serde::Deserialize)]
    struct Claims {
        role: Option<String>,
        policy_authorization_id: Option<String>,
    }

    let payload = token
        .split('.')
        .nth(1)
        .context("Token is not a JWT (no payload segment)")?;
    let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .context("Token payload is not base64url")?;
    let claims =
        serde_json::from_slice::<Claims>(&json).context("Token payload is not valid JSON")?;

    // The token is portal-issued but its signature is not verified here, so never
    // trust a claim as a path component without validating it first.
    let role = claims
        .role
        .filter(|role| is_valid_role(role))
        .context("Token has a missing or invalid role")?;
    let authz_id = claims
        .policy_authorization_id
        .filter(|id| is_valid_authz_id(id))
        .context("Token has a missing or invalid policy_authorization_id")?;

    let dir = spool_root.join(&role).join(&authz_id);
    create_dir_secure(&dir).context("Failed to create authorization directory")?;
    atomicfs::write(dir.join("token"), token).context("Failed to write token file")?;

    Ok(())
}

/// Keeps the writer thread alive.
///
/// Dropping it drains the backlog and joins the thread, making every
/// already-emitted report durable. The wait is bounded so a stalled disk
/// cannot hang process exit.
pub struct Guard {
    tx: mpsc::SyncSender<Command>,
    spool_root: PathBuf,
    handle: Option<JoinHandle<()>>,
}

impl Guard {
    /// Where this writer spools its reports, so an uploader can be pointed at
    /// the same place rather than told separately.
    pub fn spool_root(&self) -> &Path {
        &self.spool_root
    }
}

impl Drop for Guard {
    fn drop(&mut self) {
        const DRAIN_TIMEOUT: Duration = Duration::from_secs(5);

        let _ = self.tx.send(Command::Shutdown);

        let Some(handle) = self.handle.take() else {
            return;
        };

        let deadline = Instant::now() + DRAIN_TIMEOUT;
        while !handle.is_finished() {
            if Instant::now() > deadline {
                tracing::warn!(
                    "Flow-log writer did not drain within {DRAIN_TIMEOUT:?}; abandoning it"
                );

                return;
            }

            std::thread::sleep(Duration::from_millis(10));
        }

        let _ = handle.join();
    }
}

impl Guard {
    /// Drains the backlog and joins the writer thread, with no time bound.
    ///
    /// Production exits through [`Drop`], whose wait is bounded so a stalled
    /// disk cannot hang the process. A test that reads the spool right after
    /// emitting needs every report on disk instead, and a hung writer there
    /// should hang the test into its own timeout, which names the culprit.
    pub fn join(mut self) {
        let _ = self.tx.send(Command::Shutdown);

        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

enum Command {
    Write(Report),
    /// Explicit shutdown signal; the layer's sender clone lives in the global
    /// subscriber for the rest of the process, so the channel never closes.
    Shutdown,
}

/// One flow report reconstructed from a `flow_logs` tracing event.
///
/// The payload is the event's fields as emitted (minus `role` /
/// `policy_authorization_id`, which become the spool path, and the human
/// `message`); the portal validates it on ingest, so nothing is re-parsed here
/// beyond what the file name needs.
struct Report {
    role: String,
    authz_id: String,
    /// `flow_start` as unix seconds, for the lexically-sortable file name.
    flow_start: i64,
    /// Stable stem shared by a flow's open and completed reports.
    identity: String,
    completed: bool,
    payload: serde_json::Map<String, serde_json::Value>,
}

struct FlowLogLayer {
    tx: mpsc::SyncSender<Command>,
    /// How many reports were dropped because the writer thread's queue was full.
    dropped: AtomicU64,
}

impl<S> tracing_subscriber::Layer<S> for FlowLogLayer
where
    S: tracing::Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &tracing::Event<'_>, _: tracing_subscriber::layer::Context<'_, S>) {
        let mut visitor = FieldVisitor::default();
        event.record(&mut visitor);

        let Some(report) = visitor.into_report() else {
            // Flows without a portal-minted token (and thus no routing claims)
            // are emitted for observability but not spooled.
            tracing::debug!("Dropping flow-log event with missing or invalid fields");

            return;
        };

        // Never block the packet-processing path on disk IO: when the writer
        // thread cannot keep up, drop the report instead.
        match self.tx.try_send(Command::Write(report)) {
            Ok(()) => {}
            Err(mpsc::TrySendError::Full(_)) => {
                let dropped = self.dropped.fetch_add(1, Ordering::Relaxed) + 1;

                if dropped == 1 || dropped.is_multiple_of(1_000) {
                    tracing::warn!(dropped, "Flow-log writer cannot keep up; dropping reports");
                }
            }
            Err(mpsc::TrySendError::Disconnected(_)) => {
                tracing::debug!("Flow-log writer thread is gone; dropping report");
            }
        }
    }
}

/// The ingest API's record fields: the payload spooled for upload. Kept in sync
/// with the portal's ingest schema, which any new record field must be
/// coordinated with anyway.
const RECORD_FIELDS: &[&str] = &[
    "protocol",
    "inner_src_ip",
    "inner_src_port",
    "inner_dst_ip",
    "inner_dst_port",
    "domain",
    "outers",
    "flow_start",
    "flow_end",
    "last_packet",
    "rx_packets",
    "tx_packets",
    "rx_bytes",
    "tx_bytes",
];

/// Collects an event's fields as emitted.
///
/// Strings arrive through `record_str`, `Display` / `Debug` values through
/// `record_debug` (as their rendered form), counters as numbers.
#[derive(Default)]
struct FieldVisitor {
    fields: serde_json::Map<String, serde_json::Value>,
}

impl Visit for FieldVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.fields
            .insert(field.name().to_owned(), format!("{value:?}").into());
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        self.fields.insert(field.name().to_owned(), value.into());
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.fields.insert(field.name().to_owned(), value.into());
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.fields.insert(field.name().to_owned(), value.into());
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.fields.insert(field.name().to_owned(), value.into());
    }
}

impl FieldVisitor {
    /// Builds the [`Report`] from the recorded fields, or `None` if the routing /
    /// naming fields are missing or fail validation.
    fn into_report(mut self) -> Option<Report> {
        self.fields.remove("message");

        let serde_json::Value::String(role) = self.fields.remove("role")? else {
            return None;
        };
        let serde_json::Value::String(authz_id) = self.fields.remove("policy_authorization_id")?
        else {
            return None;
        };

        if !is_valid_role(&role) || !is_valid_authz_id(&authz_id) {
            return None;
        }

        // Everything else on the event (attribution claims, the human message)
        // is display-only or already carried by the token.
        self.fields
            .retain(|name, _| RECORD_FIELDS.contains(&name.as_str()));

        // The record's outer tuples ride the event as one JSON-encoded field (a
        // tracing field holds a single scalar); decode it so the report payload
        // carries the array itself.
        if let Some(outers) = self.fields.get_mut("outers") {
            let decoded = outers
                .as_str()
                .and_then(|json| serde_json::from_str::<serde_json::Value>(json).ok())?;

            *outers = decoded;
        }

        // The only other field the writer interprets: the file name needs it so
        // a lexical sort of the reports is oldest-first.
        let flow_start = DateTime::parse_from_rfc3339(self.fields.get("flow_start")?.as_str()?)
            .ok()?
            .timestamp();

        let identity = flow_identity(&self.fields);
        let completed = self.fields.contains_key("flow_end");

        Some(Report {
            role,
            authz_id,
            flow_start,
            identity,
            completed,
            payload: self.fields,
        })
    }
}

fn writer_loop(root: &Path, rx: &mpsc::Receiver<Command>) {
    let mut spool = Spool::new(root);

    while let Ok(command) = rx.recv() {
        let report = match command {
            Command::Write(report) => report,
            Command::Shutdown => break,
        };

        spool.write(&report);
    }
}

/// How much of its disk budget the spool has used, and whether the disk has room
/// at all.
///
/// Lives on the writer thread, the spool's only producer, so back-pressure
/// applies before a report is written rather than after the disk is already full.
struct Spool {
    root: PathBuf,
    /// The volume's allocation unit, so a report is charged what it takes from
    /// the disk rather than its serialized length.
    cluster: u64,
    /// Clusters the spool may occupy.
    capacity: u64,
    /// Clusters in use as of `counted_at`, plus every write since. Only the
    /// uploader deletes, so this can drift upwards but never down: reaching
    /// `capacity` early is corrected by a re-count, and the spool stays within
    /// its budget in between.
    spooled: u64,
    counted_at: Instant,
    /// When the disk-full circuit breaker re-arms, if it is tripped.
    disk_full_until: Option<Instant>,
    dropped: u64,
}

impl Spool {
    fn new(root: &Path) -> Self {
        // The volume can only be queried through a path that exists, and the
        // spool root is the writer's to create either way.
        if let Err(e) = create_dir_secure(root) {
            tracing::warn!(root = %root.display(), "Failed to create flow-log spool root: {e}");
        }

        let cluster = cluster_bytes(root).unwrap_or(DEFAULT_CLUSTER_BYTES).max(1);

        Self {
            root: root.to_owned(),
            cluster,
            capacity: SPOOL_BUDGET_BYTES / cluster,
            // The spool carries over whatever the last run could not upload.
            spooled: count_clusters(root, cluster),
            counted_at: Instant::now(),
            disk_full_until: None,
            dropped: 0,
        }
    }

    fn write(&mut self, report: &Report) {
        let now = Instant::now();

        if self.disk_full_until.is_some_and(|until| now < until) {
            self.drop_report("disk full");

            return;
        }

        if self.spooled >= self.capacity && !self.recount(now) {
            self.drop_report("spool full");

            return;
        }

        match write_report(&self.root, report) {
            Outcome::Written { bytes } => self.spooled += clusters_for(bytes, self.cluster),
            Outcome::DiskFull => self.disk_full_until = Some(now + DISK_FULL_COOLDOWN),
            Outcome::Skipped => {}
        }
    }

    /// Re-counts the spool, at most once per [`RECOUNT_INTERVAL`], and reports
    /// whether that left room for another report.
    fn recount(&mut self, now: Instant) -> bool {
        if now.duration_since(self.counted_at) < RECOUNT_INTERVAL {
            return false;
        }

        self.spooled = count_clusters(&self.root, self.cluster);
        self.counted_at = now;

        self.spooled < self.capacity
    }

    fn drop_report(&mut self, reason: &'static str) {
        self.dropped += 1;

        if self.dropped == 1 || self.dropped.is_multiple_of(1_000) {
            tracing::debug!(
                dropped = self.dropped,
                reason,
                "Not spooling flow-log report"
            );
        }
    }
}

/// What became of one report handed to [`write_report`].
enum Outcome {
    Written {
        bytes: u64,
    },
    /// The disk is full, so every write after this one fails the same way until
    /// something frees space.
    DiskFull,
    /// Nothing was written, for a reason particular to this report.
    Skipped,
}

fn write_report(root: &Path, report: &Report) -> Outcome {
    let dir = root.join(&report.role).join(&report.authz_id);

    if !dir.join("token").exists() {
        tracing::debug!(authz_id = %report.authz_id, "No ingest token on disk for authorization; not spooling report");

        return Outcome::Skipped;
    }

    let contents = match serialize(&serde_json::Value::Object(report.payload.clone())) {
        Ok(contents) => contents,
        Err(e) => {
            tracing::warn!("Failed to serialize flow-log report: {e:#}");

            return Outcome::Skipped;
        }
    };

    let suffix = if report.completed { "end" } else { "start" };
    let path = dir.join(format!(
        "{:010}-{}.{suffix}.json",
        report.flow_start, report.identity
    ));
    match atomicfs::write(&path, &contents).context("Failed to write flow-log report") {
        Ok(()) => Outcome::Written {
            bytes: contents.len() as u64,
        },
        Err(e)
            if e.any_downcast_ref::<std::io::Error>()
                .is_some_and(|io| io.kind() == std::io::ErrorKind::StorageFull) =>
        {
            tracing::debug!(path = %path.display(), "{e:#}");

            Outcome::DiskFull
        }
        Err(e) => {
            tracing::warn!(path = %path.display(), "{e:#}");

            Outcome::Skipped
        }
    }
}

/// What a report of `bytes` costs the spool.
///
/// File systems hand out whole clusters, so a 500-byte report still takes one,
/// and an empty file is not free either.
fn clusters_for(bytes: u64, cluster: u64) -> u64 {
    bytes.div_ceil(cluster).max(1)
}

/// Sums what the reports spooled under `root` cost, walking its
/// `<role>/<policy_authorization_id>` layout.
///
/// Reports are the only `.json` files in an authorization directory: the token
/// has no extension and `atomicfs` names its in-flight temporaries without one.
/// A report whose size cannot be read is charged one cluster, the least it can
/// cost.
fn count_clusters(root: &Path, cluster: u64) -> u64 {
    let mut clusters = 0;

    for role in entries(root) {
        for authz in entries(&role.path()) {
            for report in entries(&authz.path()) {
                if report.path().extension().is_none_or(|ext| ext != "json") {
                    continue;
                }

                let bytes = report.metadata().map(|meta| meta.len()).unwrap_or(0);

                clusters += clusters_for(bytes, cluster);
            }
        }
    }

    clusters
}

/// The allocation unit of the file system holding `path`, or `None` if the
/// volume cannot be queried.
///
/// Chosen per volume when it is formatted rather than fixed by the platform
/// (NTFS defaults to 4 KiB but scales with volume size, ReFS uses 4 KiB or
/// 64 KiB), so it is read from the volume rather than assumed.
#[cfg(unix)]
fn cluster_bytes(path: &Path) -> Option<u64> {
    let stats = nix::sys::statvfs::statvfs(path)
        .inspect_err(|e| tracing::debug!(path = %path.display(), "Failed to stat volume: {e}"))
        .ok()?;

    Some(stats.fragment_size())
}

#[cfg(windows)]
fn cluster_bytes(path: &Path) -> Option<u64> {
    use std::os::windows::ffi::OsStrExt as _;
    use windows::{
        Win32::Storage::FileSystem::{GetDiskFreeSpaceW, GetVolumePathNameW},
        core::PCWSTR,
    };

    let wide = path
        .as_os_str()
        .encode_wide()
        .chain([0])
        .collect::<Vec<_>>();
    // `GetDiskFreeSpaceW` takes the volume's root, not an arbitrary directory.
    let mut root = [0u16; 261]; // `MAX_PATH` plus the terminator.

    unsafe { GetVolumePathNameW(PCWSTR(wide.as_ptr()), &mut root) }
        .inspect_err(|e| tracing::debug!(path = %path.display(), "Failed to find volume: {e}"))
        .ok()?;

    let mut sectors_per_cluster = 0u32;
    let mut bytes_per_sector = 0u32;

    unsafe {
        GetDiskFreeSpaceW(
            PCWSTR(root.as_ptr()),
            Some(&mut sectors_per_cluster),
            Some(&mut bytes_per_sector),
            None,
            None,
        )
    }
    .inspect_err(|e| tracing::debug!(path = %path.display(), "Failed to query volume: {e}"))
    .ok()?;

    Some(u64::from(sectors_per_cluster) * u64::from(bytes_per_sector))
}

#[cfg(not(any(unix, windows)))]
fn cluster_bytes(_: &Path) -> Option<u64> {
    None
}

/// Lists a directory, yielding nothing if it cannot be read.
fn entries(dir: &Path) -> impl Iterator<Item = std::fs::DirEntry> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
}

/// A stable hash of the fields identifying a flow within an authorization.
///
/// A flow's open and completed reports share this stem; a reused 4-tuple gets a
/// fresh `flow_start`, so distinct flows never collide. Only within-process
/// determinism is needed.
fn flow_identity(fields: &serde_json::Map<String, serde_json::Value>) -> String {
    let mut hasher = std::hash::DefaultHasher::new();

    for name in [
        "protocol",
        "inner_src_ip",
        "inner_src_port",
        "inner_dst_ip",
        "inner_dst_port",
        "flow_start",
    ] {
        fields.get(name).map(|v| v.to_string()).hash(&mut hasher);
    }

    format!("{:016x}", hasher.finish())
}

/// A policy-authorization id must be a hyphenated UUID; reject anything else so it
/// can never escape the spool root as a path component.
fn is_valid_authz_id(id: &str) -> bool {
    // `Uuid` also parses the braced / urn / simple forms; 36 bytes pins it to
    // the hyphenated one.
    id.len() == 36 && uuid::Uuid::try_parse(id).is_ok()
}

/// Only the portal's two flow roles are valid as a path component, so an unverified
/// token can never inject an arbitrary directory name.
fn is_valid_role(role: &str) -> bool {
    matches!(role, "initiator" | "responder")
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

    // The spool holds Bearer tokens, so lock each authorization directory down to
    // `LocalSystem` and `BUILTIN\Administrators` (the accounts the Gateway / Tunnel
    // service runs as), the equivalent of `0700` on Unix. `OICI` makes the token and
    // report files inside inherit the same access.
    windows_security::SecurityDescriptor::from_sddl("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
        .and_then(|descriptor| descriptor.apply_to_path(path))
        .map_err(|e| std::io::Error::other(format!("{e:#}")))
}

#[cfg(not(any(unix, windows)))]
fn create_dir_secure(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone as _, Utc};
    use flow_log_spool::deserialize;
    use tracing_subscriber::layer::SubscriberExt as _;

    const AUTHZ_ID: &str = "11111111-1111-1111-1111-111111111111";
    /// Pinned so the tests do not depend on the volume they run on.
    const CLUSTER: u64 = 4096;

    #[test]
    fn spools_start_and_end_reports_sharing_a_stem() {
        let dir = tempfile::tempdir().unwrap();
        write_token(dir.path(), &token_for(AUTHZ_ID)).unwrap();

        let (layer, guard) = layer(dir.path().to_owned());
        let subscriber = tracing_subscriber::registry().with(layer);
        tracing::subscriber::with_default(subscriber, || {
            emit_event(false);
            emit_event(true);
        });
        guard.join(); // every emitted report is on disk once this returns

        let authz_dir = dir.path().join("responder").join(AUTHZ_ID);
        let stems = std::fs::read_dir(&authz_dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|name| name != "token")
            .collect::<Vec<_>>();

        // Both reports share one `<flow_start>-<flow_identity>` stem.
        let mut prefixes = stems
            .iter()
            .map(|name| name.split('.').next().unwrap())
            .collect::<Vec<_>>();
        prefixes.dedup();
        assert_eq!(prefixes.len(), 1, "start and end share a stem: {stems:?}");

        let start = read_payload(&authz_dir.join(format!("{}.start.json", prefixes[0])));
        let end = read_payload(&authz_dir.join(format!("{}.end.json", prefixes[0])));
        assert!(start.get("flow_end").is_none());
        // Fields are spooled as emitted; routing fields and the message are not.
        assert_eq!(start["flow_start"], "2023-11-14T22:13:20.000000500Z");
        assert!(start.get("role").is_none());
        assert!(start.get("message").is_none());
        assert!(start.get("actor_id").is_none()); // attribution rides the token only
        assert_eq!(end["rx_bytes"], 1024); // the `.end` is a self-describing report
        assert_eq!(end["inner_dst_port"], "443");
    }

    #[test]
    fn spools_nothing_without_ingest_token() {
        let dir = tempfile::tempdir().unwrap();

        let (layer, guard) = layer(dir.path().to_owned());
        let subscriber = tracing_subscriber::registry().with(layer);
        tracing::subscriber::with_default(subscriber, || {
            emit_event(true);
        });
        guard.join();

        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn drops_event_without_policy_authorization_id() {
        let dir = tempfile::tempdir().unwrap();

        let (layer, guard) = layer(dir.path().to_owned());
        let subscriber = tracing_subscriber::registry().with(layer);
        tracing::subscriber::with_default(subscriber, || {
            tracing::trace!(
                target: "flow_logs",
                protocol = "tcp",
                role = "responder",
                "TCP flow started"
            );
        });
        guard.join();

        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn writes_token_file_from_claims() {
        let dir = tempfile::tempdir().unwrap();
        let token = token_for(AUTHZ_ID);

        write_token(dir.path(), &token).unwrap();

        let path = dir.path().join("responder").join(AUTHZ_ID).join("token");
        assert_eq!(std::fs::read_to_string(path).unwrap(), token);
    }

    #[test]
    fn rejects_token_with_invalid_claims() {
        let dir = tempfile::tempdir().unwrap();
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(r#"{"policy_authorization_id":"../../evil","role":"responder"}"#);

        assert!(write_token(dir.path(), &format!("h.{payload}.s")).is_err());
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn authz_id_must_be_a_hyphenated_uuid() {
        assert!(is_valid_authz_id("11111111-1111-1111-1111-111111111111"));
        assert!(is_valid_authz_id("d31580cd-9c75-4eb1-93b0-1f43a68d5192"));

        assert!(!is_valid_authz_id(""));
        assert!(!is_valid_authz_id("11111111111111111111111111111111"));
        assert!(!is_valid_authz_id("../../../../../../../etc/passwd"));
        assert!(!is_valid_authz_id("11111111-1111-1111-1111-11111111111g"));
        assert!(!is_valid_authz_id("11111111-1111-1111-1111-1111111111111"));
    }

    #[test]
    fn stops_spooling_at_capacity() {
        let dir = tempfile::tempdir().unwrap();
        write_token(dir.path(), &token_for(AUTHZ_ID)).unwrap();

        let mut spool = Spool {
            cluster: CLUSTER,
            capacity: 2,
            ..Spool::new(dir.path())
        };
        for identity in ["a", "b", "c"] {
            spool.write(&report(identity, false));
        }

        assert_eq!(count_clusters(dir.path(), CLUSTER), 2);
    }

    #[test]
    fn resumes_spooling_once_a_recount_finds_room() {
        let dir = tempfile::tempdir().unwrap();
        write_token(dir.path(), &token_for(AUTHZ_ID)).unwrap();

        let mut spool = Spool {
            cluster: CLUSTER,
            capacity: 2,
            ..Spool::new(dir.path())
        };
        spool.write(&report("a", false));
        spool.write(&report("b", false));

        // The uploader ships one report and deletes it.
        std::fs::remove_file(report_path(dir.path(), "a")).unwrap();
        spool.counted_at = Instant::now() - RECOUNT_INTERVAL;

        spool.write(&report("c", false));

        assert!(report_path(dir.path(), "c").exists());
    }

    #[test]
    fn a_full_disk_parks_writes_until_the_cooldown_passes() {
        let dir = tempfile::tempdir().unwrap();
        write_token(dir.path(), &token_for(AUTHZ_ID)).unwrap();

        let mut spool = Spool {
            cluster: CLUSTER,
            disk_full_until: Some(Instant::now() + DISK_FULL_COOLDOWN),
            ..Spool::new(dir.path())
        };
        spool.write(&report("a", false));

        assert_eq!(count_clusters(dir.path(), CLUSTER), 0);

        spool.disk_full_until = Some(Instant::now());
        spool.write(&report("a", false));

        assert_eq!(count_clusters(dir.path(), CLUSTER), 1);
    }

    #[test]
    fn counts_reports_across_roles_but_not_tokens_or_config() {
        let dir = tempfile::tempdir().unwrap();
        write_token(dir.path(), &token_for(AUTHZ_ID)).unwrap();

        let mut spool = Spool {
            cluster: CLUSTER,
            ..Spool::new(dir.path())
        };
        spool.write(&report("a", false));
        spool.write(&report("a", true));

        let initiator = dir.path().join("initiator").join(AUTHZ_ID);
        std::fs::create_dir_all(&initiator).unwrap();
        std::fs::write(initiator.join("token"), "token").unwrap();
        std::fs::write(initiator.join("1700000000-b.start.json"), "{}").unwrap();

        // The uploader's config sits in the root, next to the role directories.
        std::fs::write(dir.path().join("upload.json"), "{}").unwrap();

        assert_eq!(count_clusters(dir.path(), CLUSTER), 3);
    }

    #[test]
    fn a_report_is_charged_whole_clusters() {
        assert_eq!(clusters_for(0, CLUSTER), 1);
        assert_eq!(clusters_for(489, CLUSTER), 1);
        assert_eq!(clusters_for(CLUSTER, CLUSTER), 1);
        assert_eq!(clusters_for(CLUSTER + 1, CLUSTER), 2);
    }

    /// Charging a report a whole cluster assumes it never spans more than one.
    /// NTFS also stores small files inside the MFT, which costs no cluster at
    /// all, so this reports what a report-sized file really takes (CI runs
    /// tests with `--nocapture`).
    #[cfg(windows)]
    #[test]
    #[allow(clippy::print_stdout)] // Reporting the measurement is the point.
    fn a_report_sized_file_costs_at_most_one_cluster() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("report.json");
        std::fs::write(&path, vec![b'x'; 489]).unwrap();

        let cluster = cluster_bytes(dir.path()).expect("volume reports its allocation unit");
        let allocated = allocated_bytes(&path);

        println!("cluster={cluster} logical=489 allocated={allocated}");

        assert!(
            allocated <= cluster,
            "a 489-byte report allocated {allocated} on a {cluster}-byte cluster"
        );
    }

    /// What the file system actually reserved for `path`, which is zero for a
    /// file NTFS keeps resident in the MFT.
    #[cfg(windows)]
    fn allocated_bytes(path: &Path) -> u64 {
        use std::os::windows::io::AsRawHandle as _;
        use windows::Win32::{
            Foundation::HANDLE,
            Storage::FileSystem::{
                FILE_STANDARD_INFO, FileStandardInfo, GetFileInformationByHandleEx,
            },
        };

        let file = std::fs::File::open(path).unwrap();
        let mut info = FILE_STANDARD_INFO::default();

        unsafe {
            GetFileInformationByHandleEx(
                HANDLE(file.as_raw_handle()),
                FileStandardInfo,
                std::ptr::from_mut(&mut info).cast(),
                size_of::<FILE_STANDARD_INFO>() as u32,
            )
        }
        .unwrap();

        info.AllocationSize as u64
    }

    fn report(identity: &str, completed: bool) -> Report {
        Report {
            role: "responder".to_owned(),
            authz_id: AUTHZ_ID.to_owned(),
            flow_start: 1_700_000_000,
            identity: identity.to_owned(),
            completed,
            payload: serde_json::Map::new(),
        }
    }

    fn report_path(root: &Path, identity: &str) -> PathBuf {
        root.join("responder")
            .join(AUTHZ_ID)
            .join(format!("1700000000-{identity}.start.json"))
    }

    fn token_for(authz_id: &str) -> String {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!(
            r#"{{"policy_authorization_id":"{authz_id}","role":"responder"}}"#
        ));

        format!("header.{payload}.signature")
    }

    /// Emits a `flow_logs` event shaped like `tunnel`'s emission.
    fn emit_event(completed: bool) {
        let flow_start = Utc.timestamp_opt(1_700_000_000, 500).unwrap();
        let flow_end = completed.then(|| Utc.timestamp_opt(1_700_000_060, 0).unwrap());

        tracing::trace!(
            target: "flow_logs",
            protocol = "tcp",
            role = "responder",
            policy_authorization_id = AUTHZ_ID,
            inner_src_ip = %"100.64.0.1",
            inner_src_port = %1234,
            inner_dst_ip = %"10.0.0.5",
            inner_dst_port = %443,
            outers = %r#"[{"src_ip":"198.51.100.1","src_port":51820,"dst_ip":"203.0.113.7","dst_port":51820}]"#,
            actor_id = "a-1",
            flow_start = ?flow_start,
            flow_end = flow_end.map(tracing::field::debug),
            last_packet = flow_end.map(tracing::field::debug),
            rx_packets = completed.then_some(10_u64),
            tx_packets = completed.then_some(12_u64),
            rx_bytes = completed.then_some(1024_u64),
            tx_bytes = completed.then_some(2048_u64),
            "TCP flow"
        );
    }

    fn read_payload(path: &Path) -> serde_json::Value {
        // `deserialize` verifies the CRC, so `unwrap` also asserts it.
        deserialize(&std::fs::read(path).unwrap()).unwrap()
    }
}
