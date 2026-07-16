//! The on-disk flow-log spool format, shared by the writer (`tunnel`) and every
//! uploader (`flow-log-upload`, and the macOS daemon FFI).
//!
//! Keeping this tiny and dependency-light is the point: an uploader needs the spool
//! format but none of the data plane, so it depends on this crate instead of pulling
//! in all of connlib via `tunnel`.
//!
//! Each report on disk is `{ "checksum": <crc32 of the serialized payload>,
//! "payload": <payload> }`. The payload is an opaque JSON object: the writer spools
//! the flow-log event's fields as emitted and the portal validates them on ingest,
//! so this crate imposes no schema. The CRC lets a reader reject a torn / corrupted
//! file rather than upload bad data.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use serde::{Deserialize, Serialize};

/// One on-disk flow-log report: a CRC32 of the serialized `payload` and the payload
/// itself. The Bearer token lives once per authorization in the directory's `token`
/// file, not in each report.
#[derive(Serialize)]
struct Entry<'a> {
    checksum: u32,
    payload: &'a serde_json::Value,
}

#[derive(Deserialize)]
struct StoredEntry {
    checksum: u32,
    payload: serde_json::Value,
}

/// Serializes a payload into the on-disk report form, computing the CRC32 over the
/// serialized payload so [`deserialize`] can verify it.
pub fn serialize(payload: &serde_json::Value) -> Result<Vec<u8>, serde_json::Error> {
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
pub fn deserialize(bytes: &[u8]) -> Result<serde_json::Value, Error> {
    let stored: StoredEntry = serde_json::from_slice(bytes).map_err(Error::Malformed)?;

    // `serde_json::Value` objects sort their keys, so re-serialization is
    // deterministic and the CRC matches the one written alongside the payload.
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

    fn payload() -> serde_json::Value {
        serde_json::json!({
            "protocol": "tcp",
            "inner_src_ip": "100.64.0.1",
            "inner_src_port": 1234,
            "inner_dst_ip": "10.0.0.5",
            "inner_dst_port": 443,
            "flow_start": "2023-11-14T22:13:20Z",
        })
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
