//! Shared utilities for load testing modules.

use std::time::Duration;

/// Statistics for echo mode testing.
///
/// Tracks message counts and round-trip latencies for echo verification
/// in TCP and WebSocket load tests.
#[derive(Debug, Clone, Default)]
pub struct EchoStats {
    /// Number of echo payloads sent to the server.
    pub messages_sent: usize,
    /// Number of echo responses that were successfully verified.
    pub messages_verified: usize,
    /// Number of echo verification failures (timeouts, corrupted data, wrong connection ID).
    pub mismatches: usize,
    /// Round-trip latency statistics for successfully verified echo responses.
    pub latencies: StreamingStats,
}

/// Safely convert a `usize` to `u32` for use with `Duration` division.
#[inline]
pub const fn saturating_usize_to_u32(value: usize) -> u32 {
    if value > u32::MAX as usize {
        u32::MAX
    } else {
        value as u32
    }
}

/// Streaming statistics for latency/RTT tracking without storing all values.
///
/// This avoids unbounded memory growth during long-running tests by tracking
/// only the values needed for final statistics: count, sum, min, and max.
#[derive(Debug, Clone, Default)]
pub struct StreamingStats {
    count: u64,
    sum: Duration,
    min: Option<Duration>,
    max: Option<Duration>,
}

impl StreamingStats {
    /// Create a new empty statistics tracker.
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a single value.
    pub fn record(&mut self, value: Duration) {
        self.count += 1;
        self.sum += value;
        self.min = Some(self.min.map_or(value, |m| m.min(value)));
        self.max = Some(self.max.map_or(value, |m| m.max(value)));
    }

    /// Merge another set of statistics into this one.
    pub fn merge(&mut self, other: &Self) {
        if other.count == 0 {
            return;
        }
        self.count += other.count;
        self.sum += other.sum;
        self.min = match (self.min, other.min) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        };
        self.max = match (self.max, other.max) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        };
    }

    /// Number of values recorded.
    pub fn count(&self) -> u64 {
        self.count
    }

    /// Minimum value, or `None` if no values recorded.
    pub fn min(&self) -> Option<Duration> {
        self.min
    }

    /// Maximum value, or `None` if no values recorded.
    pub fn max(&self) -> Option<Duration> {
        self.max
    }

    /// Average value, or `None` if no values recorded.
    pub fn avg(&self) -> Option<Duration> {
        if self.count == 0 {
            None
        } else {
            // Use nanos to avoid u32 truncation when count exceeds u32::MAX
            let avg_nanos = self.sum.as_nanos() / u128::from(self.count);
            Some(Duration::from_nanos(avg_nanos as u64))
        }
    }
}

/// Log test completion at the appropriate level based on error state.
#[macro_export]
macro_rules! log_test_result {
    ($has_errors:expr, $($arg:tt)*) => {
        if $has_errors {
            tracing::error!($($arg)*);
        } else {
            tracing::info!($($arg)*);
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_streaming_stats_empty() {
        let stats = StreamingStats::new();
        assert_eq!(stats.count(), 0);
        assert_eq!(stats.min(), None);
        assert_eq!(stats.max(), None);
        assert_eq!(stats.avg(), None);
    }

    #[test]
    fn test_streaming_stats_single_value() {
        let mut stats = StreamingStats::new();
        stats.record(Duration::from_millis(100));
        assert_eq!(stats.count(), 1);
        assert_eq!(stats.min(), Some(Duration::from_millis(100)));
        assert_eq!(stats.max(), Some(Duration::from_millis(100)));
        assert_eq!(stats.avg(), Some(Duration::from_millis(100)));
    }

    #[test]
    fn test_streaming_stats_multiple_values() {
        let mut stats = StreamingStats::new();
        stats.record(Duration::from_millis(100));
        stats.record(Duration::from_millis(200));
        stats.record(Duration::from_millis(300));
        assert_eq!(stats.count(), 3);
        assert_eq!(stats.min(), Some(Duration::from_millis(100)));
        assert_eq!(stats.max(), Some(Duration::from_millis(300)));
        assert_eq!(stats.avg(), Some(Duration::from_millis(200)));
    }

    #[test]
    fn test_streaming_stats_merge() {
        let mut stats1 = StreamingStats::new();
        stats1.record(Duration::from_millis(100));
        stats1.record(Duration::from_millis(200));

        let mut stats2 = StreamingStats::new();
        stats2.record(Duration::from_millis(50));
        stats2.record(Duration::from_millis(300));

        stats1.merge(&stats2);
        assert_eq!(stats1.count(), 4);
        assert_eq!(stats1.min(), Some(Duration::from_millis(50)));
        assert_eq!(stats1.max(), Some(Duration::from_millis(300)));
        // (100 + 200 + 50 + 300) / 4 = 162.5ms
        assert_eq!(stats1.avg(), Some(Duration::from_micros(162_500)));
    }

    #[test]
    fn test_streaming_stats_merge_empty() {
        let mut stats1 = StreamingStats::new();
        stats1.record(Duration::from_millis(100));

        let stats2 = StreamingStats::new();
        stats1.merge(&stats2);

        assert_eq!(stats1.count(), 1);
        assert_eq!(stats1.min(), Some(Duration::from_millis(100)));
    }
}
