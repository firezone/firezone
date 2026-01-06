//! Timestamped echo payload for load testing.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Minimum payload size (connection_id + timestamp).
pub const HEADER_SIZE: usize = 16;

/// Echo payload format:
/// - 8 bytes: connection_id (u64, big-endian)
/// - 8 bytes: timestamp_nanos (u64, big-endian, nanoseconds since UNIX epoch)
/// - N bytes: padding (filled with connection_id byte pattern for verification)
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EchoPayload {
    /// Unique identifier for the connection that sent this payload.
    pub connection_id: u64,
    /// Timestamp when the payload was created (nanoseconds since UNIX epoch).
    pub timestamp_nanos: u64,
    /// Padding bytes for reaching desired payload size.
    pub padding: Vec<u8>,
}

impl EchoPayload {
    /// Create a new echo payload with the current timestamp.
    pub fn new(connection_id: u64, payload_size: usize) -> Self {
        let timestamp_nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time before UNIX epoch")
            .as_nanos() as u64;

        let padding_size = payload_size.saturating_sub(HEADER_SIZE);
        let padding = Self::generate_padding(connection_id, padding_size);

        Self {
            connection_id,
            timestamp_nanos,
            padding,
        }
    }

    /// Generate padding bytes using connection_id as a pattern.
    ///
    /// This makes padding verification possible - corrupted padding indicates
    /// data corruption during echo.
    fn generate_padding(connection_id: u64, size: usize) -> Vec<u8> {
        let pattern = connection_id.to_be_bytes();
        let mut padding = Vec::with_capacity(size);

        for i in 0..size {
            padding.push(pattern[i % 8]);
        }

        padding
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(HEADER_SIZE + self.padding.len());
        bytes.extend_from_slice(&self.connection_id.to_be_bytes());
        bytes.extend_from_slice(&self.timestamp_nanos.to_be_bytes());
        bytes.extend_from_slice(&self.padding);
        bytes
    }

    /// Deserialize a payload from bytes.
    ///
    /// Returns `None` if the bytes are too short or the padding doesn't match
    /// the expected pattern.
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < HEADER_SIZE {
            return None;
        }

        let connection_id = u64::from_be_bytes(bytes[0..8].try_into().ok()?);
        let timestamp_nanos = u64::from_be_bytes(bytes[8..16].try_into().ok()?);
        let padding = bytes[16..].to_vec();

        // Verify padding matches expected pattern
        let expected_padding = Self::generate_padding(connection_id, padding.len());
        if padding != expected_padding {
            return None;
        }

        Some(Self {
            connection_id,
            timestamp_nanos,
            padding,
        })
    }

    /// Calculate the round-trip latency from when this payload was created.
    ///
    /// Returns `None` if the current time is before the payload timestamp
    /// (clock skew or corruption).
    pub fn round_trip_latency(&self) -> Option<Duration> {
        let now_nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time before UNIX epoch")
            .as_nanos() as u64;

        now_nanos
            .checked_sub(self.timestamp_nanos)
            .map(Duration::from_nanos)
    }

    /// Total size of the serialized payload in bytes.
    pub fn size(&self) -> usize {
        HEADER_SIZE + self.padding.len()
    }
}

/// Error type for echo payload operations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EchoError {
    /// Received data is too short to contain a valid payload.
    TooShort { expected: usize, actual: usize },
    /// Padding verification failed - data corruption detected.
    PaddingMismatch,
    /// Connection ID in response doesn't match the sent payload.
    ConnectionIdMismatch { expected: u64, actual: u64 },
}

impl std::fmt::Display for EchoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TooShort { expected, actual } => {
                write!(
                    f,
                    "payload too short: expected {expected} bytes, got {actual}"
                )
            }
            Self::PaddingMismatch => write!(f, "padding verification failed"),
            Self::ConnectionIdMismatch { expected, actual } => {
                write!(
                    f,
                    "connection ID mismatch: expected {expected}, got {actual}"
                )
            }
        }
    }
}

impl std::error::Error for EchoError {}

/// Verify that received bytes match the sent payload.
pub fn verify_echo(sent: &EchoPayload, received: &[u8]) -> Result<EchoPayload, EchoError> {
    let expected_size = sent.size();
    if received.len() < expected_size {
        return Err(EchoError::TooShort {
            expected: expected_size,
            actual: received.len(),
        });
    }

    let parsed = EchoPayload::from_bytes(received).ok_or(EchoError::PaddingMismatch)?;

    if parsed.connection_id != sent.connection_id {
        return Err(EchoError::ConnectionIdMismatch {
            expected: sent.connection_id,
            actual: parsed.connection_id,
        });
    }

    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_payload_round_trip() {
        let payload = EchoPayload::new(42, 100);
        let bytes = payload.to_bytes();
        let parsed = EchoPayload::from_bytes(&bytes).expect("should parse");

        assert_eq!(parsed.connection_id, 42);
        assert_eq!(parsed.timestamp_nanos, payload.timestamp_nanos);
        assert_eq!(parsed.padding.len(), 100 - HEADER_SIZE);
    }

    #[test]
    fn test_payload_minimum_size() {
        let payload = EchoPayload::new(1, 0);
        assert_eq!(payload.size(), HEADER_SIZE);
        assert!(payload.padding.is_empty());
    }

    #[test]
    fn test_verify_echo_success() {
        let sent = EchoPayload::new(123, 64);
        let received = sent.to_bytes();
        let result = verify_echo(&sent, &received);
        assert!(result.is_ok());
    }

    #[test]
    fn test_verify_echo_too_short() {
        let sent = EchoPayload::new(123, 64);
        let received = vec![0u8; 10];
        let result = verify_echo(&sent, &received);
        assert!(matches!(result, Err(EchoError::TooShort { .. })));
    }

    #[test]
    fn test_verify_echo_corrupted_padding() {
        let sent = EchoPayload::new(123, 64);
        let mut received = sent.to_bytes();
        received[20] ^= 0xFF; // Corrupt a padding byte
        let result = verify_echo(&sent, &received);
        assert!(matches!(result, Err(EchoError::PaddingMismatch)));
    }

    #[test]
    fn test_verify_echo_wrong_connection_id() {
        let sent = EchoPayload::new(123, 64);
        let wrong = EchoPayload::new(456, 64);
        let received = wrong.to_bytes();
        let result = verify_echo(&sent, &received);
        assert!(matches!(
            result,
            Err(EchoError::ConnectionIdMismatch { .. })
        ));
    }

    #[test]
    fn test_round_trip_latency_clock_skew() {
        let mut payload = EchoPayload::new(1, 16);
        // Set timestamp far in the future to simulate clock skew
        payload.timestamp_nanos = u64::MAX;
        assert!(payload.round_trip_latency().is_none());
    }
}
