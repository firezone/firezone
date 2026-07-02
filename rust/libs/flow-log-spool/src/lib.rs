//! The on-disk flow-log spool format, shared by the writer (`tunnel`) and every
//! uploader (`flow-log-upload`, and the macOS daemon FFI).
//!
//! Keeping this tiny and dependency-light is the point: an uploader needs the spool
//! format but none of the data plane, so it depends on this crate instead of pulling
//! in all of connlib via `tunnel`.
//!
//! Each report on disk is `{ "checksum": <crc32 of the serialized payload>,
//! "payload": <Payload> }`. The CRC lets a reader reject a torn / corrupted file
//! rather than upload bad data.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::net::IpAddr;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// A flow-log payload: the network fields the data plane observes. Attribution
/// lives in the authorization's token, never in the payload. `flow_end` and the
/// counters are absent for an "open" report and present for a "completed" one.
///
/// Fields are public so the writer can build one directly; readers get one back
/// from [`deserialize`].
#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Payload {
    pub protocol: String,
    pub inner_src_ip: IpAddr,
    pub inner_src_port: u16,
    pub inner_dst_ip: IpAddr,
    pub inner_dst_port: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub domain: Option<String>,
    pub outer_src_ip: IpAddr,
    pub outer_src_port: u16,
    pub outer_dst_ip: IpAddr,
    pub outer_dst_port: u16,
    pub flow_start: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub flow_end: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_packet: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rx_packets: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tx_packets: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rx_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tx_bytes: Option<u64>,
}

/// One on-disk flow-log report: a CRC32 of the serialized `payload` and the payload
/// itself. The Bearer token lives once per authorization in the directory's `token`
/// file, not in each report.
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

/// Serializes a payload into the on-disk report form, computing the CRC32 over the
/// serialized payload so [`deserialize`] can verify it.
pub fn serialize(payload: &Payload) -> Result<Vec<u8>, serde_json::Error> {
    let body = serde_json::to_vec(payload)?;
    let entry = Entry {
        checksum: crc32fast::hash(&body),
        payload,
    };

    serde_json::to_vec(&entry)
}

/// Parses and verifies a spooled flow-log report from its file bytes, returning the
/// payload.
///
/// The error distinguishes malformed JSON (should be impossible under atomic
/// writes) from a CRC32 mismatch (environmental corruption the checksum exists to
/// catch), so the uploader can report them with different severity.
pub fn deserialize(bytes: &[u8]) -> Result<Payload, Error> {
    let stored: StoredEntry = serde_json::from_slice(bytes).map_err(Error::Malformed)?;

    // The payload serializes deterministically (fixed struct, compact), so the CRC
    // of its re-serialization matches the one written alongside it.
    let serialized = serde_json::to_vec(&stored.payload).map_err(Error::Malformed)?;
    let computed = crc32fast::hash(&serialized);

    if computed != stored.checksum {
        return Err(Error::ChecksumMismatch {
            stored: stored.checksum,
            computed,
        });
    }

    Ok(stored.payload)
}

/// Why a spooled report could not be read back.
#[derive(Debug)]
pub enum Error {
    /// The JSON structure is broken.
    Malformed(serde_json::Error),
    /// The payload does not match its stored CRC32 (a torn or corrupted file).
    ChecksumMismatch { stored: u32, computed: u32 },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Malformed(e) => write!(f, "Malformed report: {e}"),
            Error::ChecksumMismatch { stored, computed } => {
                write!(f, "Checksum mismatch: stored {stored}, computed {computed}")
            }
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Malformed(e) => Some(e),
            Error::ChecksumMismatch { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn payload() -> Payload {
        Payload {
            protocol: "tcp".to_owned(),
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
            flow_end: None,
            last_packet: None,
            rx_packets: None,
            tx_packets: None,
            rx_bytes: None,
            tx_bytes: None,
        }
    }

    #[test]
    fn round_trips_through_serialize_and_deserialize() {
        let bytes = serialize(&payload()).unwrap();

        assert_eq!(deserialize(&bytes).unwrap(), payload());
    }

    #[test]
    fn detects_checksum_mismatch() {
        let bytes = serialize(&payload()).unwrap();
        let tampered = String::from_utf8(bytes)
            .unwrap()
            .replace("\"inner_dst_port\":443", "\"inner_dst_port\":444");

        assert!(matches!(
            deserialize(tampered.as_bytes()),
            Err(Error::ChecksumMismatch { .. })
        ));
    }

    #[test]
    fn rejects_malformed_json() {
        assert!(matches!(deserialize(b"not json"), Err(Error::Malformed(_))));
    }
}
