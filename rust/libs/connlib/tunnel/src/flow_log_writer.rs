//! Spools flow-log records to disk for later upload to the portal ingest API.
//!
//! Records are grouped by their token's flow `role` and `policy_authorization_id`
//! into a per-authorization sub-directory holding that authorization's Bearer token
//! and one file per flow report, split into an "open" and a "completed" report:
//!
//! ```text
//! <root>/<role>/<policy_authorization_id>/
//!   token                       # the Bearer JWT for this authorization
//!   <flow_identity>.start.json  # { "checksum": <crc32>, "payload": { open record } }
//!   <flow_identity>.end.json    # { "checksum": <crc32>, "payload": { completed record } }
//! ```
//!
//! The `<role>` level (`initiator` / `responder`) separates the two perspectives a
//! single device can log: a Gateway is always the responder, while a Client can be
//! the initiator of some flows and the responder of others.
//!
//! `<flow_identity>` hashes the fields that identify a flow within an authorization
//! (protocol, inner 4-tuple, flow_start), so a flow's open and completed reports
//! share a stem. The `.end` report is self-describing (it carries the full record,
//! not just the closing fields), so the uploader can send it on its own even after
//! the `.start` has already been uploaded and deleted. Writing the completed report
//! to its own file (rather than overwriting the open one) keeps both write-once, so
//! the uploader can delete one without racing a concurrent write of the other.
//!
//! Each report is written immediately as an atomic, fsync'd file, so nothing
//! already produced is lost on an unclean exit. Writing happens on a dedicated
//! thread fed by a channel so the per-file fsync never blocks the packet-processing
//! event loop. The spool holds Bearer tokens and flow payloads, so its directories
//! and files get restrictive permissions (0700 / 0600) and it lives outside the log
//! directory, so an exported log bundle never sweeps it up.

use std::{
    collections::BTreeMap,
    hash::{Hash as _, Hasher as _},
    io::Write as _,
    net::IpAddr,
    path::{Path, PathBuf},
    sync::mpsc,
    thread::JoinHandle,
};

use atomicwrites::{AtomicFile, OverwriteBehavior};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::gateway::flow_tracker::{FlowLogRecord, decode_attribution};

/// Hands each record to a writer thread that writes it immediately as its own
/// atomic, fsync'd file.
pub struct FlowLogWriter {
    tx: Option<mpsc::Sender<FlowLogRecord>>,
    handle: Option<JoinHandle<()>>,
}

impl FlowLogWriter {
    pub fn new(root: PathBuf) -> Self {
        let (tx, rx) = mpsc::channel::<FlowLogRecord>();
        let handle = std::thread::Builder::new()
            .name("flow-log-writer".to_owned())
            .spawn(move || writer_loop(&root, &rx))
            .expect("Failed to spawn flow-log writer thread");

        Self {
            tx: Some(tx),
            handle: Some(handle),
        }
    }

    /// Queues a record to be written. Cheap and non-blocking; the writer thread
    /// performs the actual fsync'd write.
    pub fn write(&self, record: FlowLogRecord) {
        if let Some(tx) = &self.tx
            && tx.send(record).is_err()
        {
            tracing::debug!("Flow-log writer thread is gone; dropping record");
        }
    }
}

impl Drop for FlowLogWriter {
    fn drop(&mut self) {
        // Close the channel so the writer thread drains its backlog and exits,
        // then wait for it so every queued record is durable before we return.
        self.tx = None;
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

fn writer_loop(root: &Path, rx: &mpsc::Receiver<FlowLogRecord>) {
    // The latest Bearer token written for each authorization, so the token file is
    // (re)written only when it first appears or rotates.
    let mut tokens = BTreeMap::<String, String>::new();

    while let Ok(record) = rx.recv() {
        if let Err(e) = write_record(root, &mut tokens, &record) {
            tracing::warn!("Failed to write flow-log report: {e:#}");
        }
    }
}

fn write_record(
    root: &Path,
    tokens: &mut BTreeMap<String, String>,
    record: &FlowLogRecord,
) -> anyhow::Result<()> {
    let Some(token) = record.ingest_token.as_deref() else {
        tracing::debug!("Dropping flow log without an ingest token");
        return Ok(());
    };
    let Some(attribution) = decode_attribution(token) else {
        tracing::debug!("Dropping flow log: token attribution could not be decoded");
        return Ok(());
    };
    let Some(authz_id) = attribution.policy_authorization_id else {
        tracing::debug!("Dropping flow log: token has no policy_authorization_id");
        return Ok(());
    };
    // The token is portal-issued but its signature is not verified here, so never
    // trust a claim as a path component without validating it first.
    if !is_valid_authz_id(&authz_id) {
        tracing::warn!(%authz_id, "Dropping flow log: invalid policy_authorization_id");
        return Ok(());
    }
    let Some(role) = attribution.role.filter(|role| is_valid_role(role)) else {
        tracing::warn!("Dropping flow log: token has a missing or invalid role");
        return Ok(());
    };

    let dir = root.join(&role).join(&authz_id);
    create_dir_secure(&dir)?;

    // (Re)write the authorization's token file only when it first appears or rotates.
    if tokens.get(&authz_id).map(String::as_str) != Some(token) {
        write_file_secure(
            &dir.join("token"),
            token.as_bytes(),
            OverwriteBehavior::AllowOverwrite,
        )?;
        tokens.insert(authz_id, token.to_owned());
    }

    let payload = Payload::from(record);
    let body = serde_json::to_vec(&payload)?;
    let entry = Entry {
        checksum: crc32fast::hash(&body),
        payload: &payload,
    };
    let contents = serde_json::to_vec(&entry)?;

    let suffix = if record.close.is_some() {
        "end"
    } else {
        "start"
    };
    let path = dir.join(format!("{}.{suffix}.json", flow_identity(record)));
    write_file_secure(&path, &contents, OverwriteBehavior::AllowOverwrite)?;

    Ok(())
}

/// A stable hash of the fields that identify a flow within an authorization, so a
/// flow's open (`.start`) and completed (`.end`) reports share a filename stem.
///
/// The same fields appear in both reports, and a re-used 4-tuple gets a fresh
/// `flow_start`, so distinct flows never collide. Only within-process determinism
/// is needed: a flow's two reports are always written by the same process (an
/// in-flight flow does not survive a restart).
fn flow_identity(record: &FlowLogRecord) -> String {
    let mut hasher = std::hash::DefaultHasher::new();
    record.protocol.as_str().hash(&mut hasher);
    record.inner_src_ip.hash(&mut hasher);
    record.inner_src_port.hash(&mut hasher);
    record.inner_dst_ip.hash(&mut hasher);
    record.inner_dst_port.hash(&mut hasher);
    record.flow_start.hash(&mut hasher);

    format!("{:016x}", hasher.finish())
}

fn write_file_secure(
    path: &Path,
    bytes: &[u8],
    overwrite: OverwriteBehavior,
) -> anyhow::Result<()> {
    // `AtomicFile` writes to a temp file, fsyncs it, then renames into place, so a
    // reader never observes a partial file and a written file is durable.
    AtomicFile::new(path, overwrite)
        .write(|f| {
            set_owner_only(f)?;
            f.write_all(bytes)
        })
        .map_err(|e| anyhow::anyhow!("atomic write of {} failed: {e}", path.display()))
}

/// A policy-authorization id must be a UUID; reject anything else so it can never
/// escape the spool root as a path component.
fn is_valid_authz_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
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

#[cfg(not(unix))]
fn create_dir_secure(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)
}

#[cfg(unix)]
fn set_owner_only(f: &std::fs::File) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;

    f.set_permissions(std::fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn set_owner_only(_f: &std::fs::File) -> std::io::Result<()> {
    Ok(())
}

/// A flow-log payload: the network fields the data plane observes. Attribution
/// lives in the authorization's token, never in the payload. `flow_end` and the
/// counters are absent for an "open" report and present for a "completed" one.
#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Payload {
    protocol: String,
    inner_src_ip: IpAddr,
    inner_src_port: u16,
    inner_dst_ip: IpAddr,
    inner_dst_port: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    domain: Option<String>,
    outer_src_ip: IpAddr,
    outer_src_port: u16,
    outer_dst_ip: IpAddr,
    outer_dst_port: u16,
    flow_start: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    flow_end: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_packet: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rx_packets: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tx_packets: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rx_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tx_bytes: Option<u64>,
}

impl From<&FlowLogRecord> for Payload {
    fn from(r: &FlowLogRecord) -> Self {
        let close = r.close.as_ref();

        Self {
            protocol: r.protocol.as_str().to_owned(),
            inner_src_ip: r.inner_src_ip,
            inner_src_port: r.inner_src_port,
            inner_dst_ip: r.inner_dst_ip,
            inner_dst_port: r.inner_dst_port,
            domain: r.domain.as_ref().map(|d| d.to_string()),
            outer_src_ip: r.outer_src_ip,
            outer_src_port: r.outer_src_port,
            outer_dst_ip: r.outer_dst_ip,
            outer_dst_port: r.outer_dst_port,
            flow_start: r.flow_start,
            flow_end: close.map(|c| c.flow_end),
            last_packet: close.map(|c| c.last_packet),
            rx_packets: close.map(|c| c.rx_packets),
            tx_packets: close.map(|c| c.tx_packets),
            rx_bytes: close.map(|c| c.rx_bytes),
            tx_bytes: close.map(|c| c.tx_bytes),
        }
    }
}

/// One on-disk flow-log report: a CRC32 of the serialized `payload` and the
/// payload itself. The Bearer token lives once per authorization in the
/// directory's `token` file, not in each report.
#[derive(Serialize)]
struct Entry<'a> {
    checksum: u32,
    payload: &'a Payload,
}

#[derive(Deserialize)]
struct StoredEntry {
    checksum: u32,
    payload: Payload,
}

/// A report that could not be parsed, or whose checksum did not match.
#[derive(Debug)]
pub struct CorruptEntry(String);

impl std::fmt::Display for CorruptEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Parses and verifies a spooled flow-log report from its file bytes, returning
/// the payload.
///
/// Returns [`CorruptEntry`] when the JSON is malformed or the CRC32 does not match
/// the payload, so the uploader can drop the file rather than send bad data.
pub fn read_spooled_entry(bytes: &[u8]) -> Result<Payload, CorruptEntry> {
    let stored: StoredEntry = serde_json::from_slice(bytes)
        .map_err(|e| CorruptEntry(format!("malformed report: {e}")))?;

    // The payload serializes deterministically (fixed struct, compact), so the CRC
    // of its re-serialization matches the one written alongside it.
    let serialized = serde_json::to_vec(&stored.payload)
        .map_err(|e| CorruptEntry(format!("could not re-serialize payload: {e}")))?;
    let computed = crc32fast::hash(&serialized);
    if computed != stored.checksum {
        return Err(CorruptEntry(format!(
            "checksum mismatch: stored {}, computed {computed}",
            stored.checksum
        )));
    }

    Ok(stored.payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::flow_tracker::{FlowClose, FlowLogRecord, FlowProtocol};
    use base64::Engine as _;
    use chrono::TimeZone as _;

    fn token_for(authz_id: &str) -> String {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!(
            r#"{{"policy_authorization_id":"{authz_id}","role":"responder"}}"#
        ));

        format!("header.{payload}.signature")
    }

    fn record(token: &str, close: Option<FlowClose>) -> FlowLogRecord {
        FlowLogRecord {
            ingest_token: Some(token.to_owned()),
            protocol: FlowProtocol::Tcp,
            inner_src_ip: "100.64.0.1".parse().unwrap(),
            inner_src_port: 1234,
            inner_dst_ip: "10.0.0.5".parse().unwrap(),
            inner_dst_port: 443,
            domain: None,
            outer_src_ip: "198.51.100.1".parse().unwrap(),
            outer_src_port: 51820,
            outer_dst_ip: "203.0.113.7".parse().unwrap(),
            outer_dst_port: 51820,
            flow_start: Utc.timestamp_opt(1_700_000_000, 0).unwrap(),
            close,
        }
    }

    fn close() -> FlowClose {
        FlowClose {
            flow_end: Utc.timestamp_opt(1_700_000_060, 0).unwrap(),
            last_packet: Utc.timestamp_opt(1_700_000_059, 0).unwrap(),
            rx_packets: 10,
            tx_packets: 12,
            rx_bytes: 1024,
            tx_bytes: 2048,
        }
    }

    fn read_payload(path: &Path) -> Payload {
        // `read_spooled_entry` verifies the CRC, so `unwrap` also asserts it.
        read_spooled_entry(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn writes_start_and_end_reports_sharing_a_stem_plus_a_token_file() {
        let dir = tempfile::tempdir().unwrap();
        let authz_id = "11111111-1111-1111-1111-111111111111";
        let token = token_for(authz_id);

        let writer = FlowLogWriter::new(dir.path().to_owned());
        writer.write(record(&token, None));
        writer.write(record(&token, Some(close())));
        drop(writer); // joins the writer thread, so everything is on disk

        let authz_dir = dir.path().join("responder").join(authz_id);
        assert_eq!(
            std::fs::read_to_string(authz_dir.join("token")).unwrap(),
            token
        );

        let stems = std::fs::read_dir(&authz_dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|name| name != "token")
            .collect::<Vec<_>>();

        // Both reports share one `<flow_identity>` stem.
        let mut prefixes = stems
            .iter()
            .map(|name| name.split('.').next().unwrap())
            .collect::<Vec<_>>();
        prefixes.dedup();
        assert_eq!(prefixes.len(), 1, "start and end share a stem: {stems:?}");

        let start = read_payload(&authz_dir.join(format!("{}.start.json", prefixes[0])));
        let end = read_payload(&authz_dir.join(format!("{}.end.json", prefixes[0])));
        assert!(start.flow_end.is_none());
        assert_eq!(end.rx_bytes, Some(1024)); // the `.end` is a self-describing record
        assert_eq!(end.inner_dst_port, 443);
    }

    #[test]
    fn drops_record_without_policy_authorization_id() {
        let dir = tempfile::tempdir().unwrap();

        let writer = FlowLogWriter::new(dir.path().to_owned());
        let payload =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(r#"{"role":"responder"}"#);
        writer.write(record(&format!("h.{payload}.s"), None));
        drop(writer);

        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }
}
