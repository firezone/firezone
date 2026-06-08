use std::time::Duration;

use crate::echo_payload::HEADER_SIZE;

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

/// Bitrate suffixes (case-insensitive), ordered so longer suffixes match first.
///
/// Multipliers are decimal (SI), matching how network bitrates are conventionally quoted.
const BITRATE_SUFFIXES: &[(&str, f64)] = &[
    ("gbps", 1e9),
    ("gbit", 1e9),
    ("g", 1e9),
    ("mbps", 1e6),
    ("mbit", 1e6),
    ("m", 1e6),
    ("kbps", 1e3),
    ("kbit", 1e3),
    ("k", 1e3),
    ("bps", 1.0),
    ("bit", 1.0),
];

/// Parse a bitrate into bits per second.
///
/// Accepts values like `2mbps`, `500kbps`, `1.5gbit` or a bare bits/sec number.
pub fn parse_bitrate(s: &str) -> Result<u64, String> {
    let s = s.trim();
    let lower = s.to_ascii_lowercase();

    for &(suffix, multiplier) in BITRATE_SUFFIXES {
        let Some(num) = lower.strip_suffix(suffix) else {
            continue;
        };

        let value: f64 = num
            .trim()
            .parse()
            .map_err(|e| format!("invalid bitrate '{s}': {e}"))?;
        if !value.is_finite() || value < 0.0 {
            return Err(format!("bitrate must be a non-negative number: '{s}'"));
        }

        return Ok((value * multiplier) as u64);
    }

    // No suffix: treat as a raw bits-per-second value.
    lower.parse::<u64>().map_err(|e| {
        format!("invalid bitrate (use e.g. 2mbps, 500kbps, or a raw bits/sec value): {e}")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_bitrate_units() {
        assert_eq!(parse_bitrate("2mbps").unwrap(), 2_000_000);
        assert_eq!(parse_bitrate("500kbps").unwrap(), 500_000);
        assert_eq!(parse_bitrate("1gbit").unwrap(), 1_000_000_000);
        assert_eq!(parse_bitrate("1m").unwrap(), 1_000_000);
        assert_eq!(parse_bitrate("2.5mbps").unwrap(), 2_500_000);
    }

    #[test]
    fn parse_bitrate_bare_number_is_bits_per_second() {
        assert_eq!(parse_bitrate("1500").unwrap(), 1500);
        assert_eq!(parse_bitrate("100bps").unwrap(), 100);
    }

    #[test]
    fn parse_bitrate_is_case_insensitive() {
        assert_eq!(parse_bitrate("2MBPS").unwrap(), 2_000_000);
    }

    #[test]
    fn parse_bitrate_rejects_invalid() {
        assert!(parse_bitrate("abc").is_err());
        assert!(parse_bitrate("-5mbps").is_err());
        assert!(parse_bitrate("mbps").is_err());
    }
}
