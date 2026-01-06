use std::time::Duration;

use crate::{echo_payload::HEADER_SIZE, ping};

/// Duration suffixes: (suffix, seconds_multiplier, unit_name).
const DURATION_SUFFIXES: &[(&str, u64, &str)] = &[
    // "ms" must come before "m" to match correctly.
    ("ms", 0, "milliseconds"), // Special case: 0 means use millis
    ("s", 1, "seconds"),
    ("m", 60, "minutes"),
    ("h", 3600, "hours"),
];

pub fn parse_duration(s: &str) -> Result<Duration, String> {
    let s = s.trim();

    for &(suffix, multiplier, unit) in DURATION_SUFFIXES {
        if let Some(num_str) = s.strip_suffix(suffix) {
            let num: u64 = num_str
                .parse()
                .map_err(|e| format!("invalid {unit}: {e}"))?;
            return Ok(if multiplier == 0 {
                Duration::from_millis(num)
            } else {
                Duration::from_secs(num * multiplier)
            });
        }
    }

    // Default: treat as seconds
    s.parse::<u64>()
        .map(Duration::from_secs)
        .map_err(|e| format!("invalid duration (use 500ms, 30s, 5m, 1h): {e}"))
}

pub fn parse_echo_payload_size(s: &str) -> Result<usize, String> {
    let size: usize = s
        .parse()
        .map_err(|e| format!("invalid payload size: {e}"))?;
    if size < HEADER_SIZE {
        return Err(format!(
            "payload size must be at least {HEADER_SIZE} bytes (header size)"
        ));
    }
    Ok(size)
}

pub fn parse_ping_payload_size(s: &str) -> Result<usize, String> {
    let size: usize = s
        .parse()
        .map_err(|e| format!("invalid payload size: {e}"))?;
    if size > ping::MAX_ICMP_PAYLOAD_SIZE {
        return Err(format!(
            "payload size exceeds maximum ICMP payload of {} bytes",
            ping::MAX_ICMP_PAYLOAD_SIZE
        ));
    }
    Ok(size)
}
