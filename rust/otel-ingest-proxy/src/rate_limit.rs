use parking_lot::Mutex;
use std::collections::HashMap;
use std::num::NonZeroU32;
use std::time::{Duration, Instant};

/// Token buckets per key, e.g. per device.
///
/// Tracks at most `max_keys` keys. A key whose bucket has refilled completely is idle and gets
/// evicted, which is indistinguishable from keeping it. If all keys are busy, new keys are denied.
pub struct RateLimiter {
    buckets: Mutex<HashMap<String, Bucket>>,
    tokens_per_second: f64,
    burst: f64,
    max_keys: usize,
}

impl RateLimiter {
    pub fn new(per_minute: NonZeroU32, burst: NonZeroU32, max_keys: usize) -> Self {
        Self {
            buckets: Mutex::new(HashMap::new()),
            tokens_per_second: f64::from(per_minute.get()) / 60.0,
            burst: f64::from(burst.get()),
            max_keys,
        }
    }

    /// Takes a token from the bucket of `key`.
    ///
    /// # Errors
    ///
    /// Returns how long to wait until a token is available if the bucket is empty.
    pub fn check(&self, key: &str, now: Instant) -> Result<(), Duration> {
        let mut buckets = self.buckets.lock();

        if let Some(bucket) = buckets.get_mut(key) {
            return bucket.take(now, self.tokens_per_second, self.burst);
        }

        if buckets.len() >= self.max_keys {
            self.evict_idle_locked(&mut buckets, now);
        }
        if buckets.len() >= self.max_keys {
            tracing::debug!(max_keys = %self.max_keys, "Too many rate-limited keys");

            return Err(Duration::from_secs_f64(1.0 / self.tokens_per_second));
        }

        let mut bucket = Bucket {
            tokens: self.burst,
            updated_at: now,
        };
        let result = bucket.take(now, self.tokens_per_second, self.burst);
        buckets.insert(key.to_owned(), bucket);

        result
    }

    pub fn evict_idle(&self, now: Instant) {
        self.evict_idle_locked(&mut self.buckets.lock(), now);
    }

    fn evict_idle_locked(&self, buckets: &mut HashMap<String, Bucket>, now: Instant) {
        for _ in
            buckets.extract_if(|_, bucket| bucket.is_full(now, self.tokens_per_second, self.burst))
        {
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.buckets.lock().len()
    }
}

struct Bucket {
    tokens: f64,
    updated_at: Instant,
}

impl Bucket {
    fn take(&mut self, now: Instant, tokens_per_second: f64, burst: f64) -> Result<(), Duration> {
        self.tokens = self.tokens_at(now, tokens_per_second, burst);
        self.updated_at = now;

        if self.tokens < 1.0 {
            return Err(Duration::from_secs_f64(
                (1.0 - self.tokens) / tokens_per_second,
            ));
        }

        self.tokens -= 1.0;

        Ok(())
    }

    fn is_full(&self, now: Instant, tokens_per_second: f64, burst: f64) -> bool {
        self.tokens_at(now, tokens_per_second, burst) >= burst
    }

    fn tokens_at(&self, now: Instant, tokens_per_second: f64, burst: f64) -> f64 {
        let elapsed = now.saturating_duration_since(self.updated_at).as_secs_f64();

        (self.tokens + elapsed * tokens_per_second).min(burst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn denies_once_burst_is_used_up() {
        let limiter = RateLimiter::new(per_minute(60), burst(2), 10);
        let now = Instant::now();

        assert!(limiter.check("device", now).is_ok());
        assert!(limiter.check("device", now).is_ok());
        let retry_after = limiter.check("device", now).unwrap_err();

        assert_eq!(retry_after, Duration::from_secs(1));
    }

    #[test]
    fn refills_over_time() {
        let limiter = RateLimiter::new(per_minute(60), burst(1), 10);
        let now = Instant::now();
        limiter.check("device", now).unwrap();

        let result = limiter.check("device", now + Duration::from_secs(1));

        assert!(result.is_ok());
    }

    #[test]
    fn keys_have_separate_buckets() {
        let limiter = RateLimiter::new(per_minute(60), burst(1), 10);
        let now = Instant::now();
        limiter.check("account-a", now).unwrap();

        let result = limiter.check("account-b", now);

        assert!(result.is_ok());
    }

    #[test]
    fn evicts_idle_keys_to_make_room() {
        let limiter = RateLimiter::new(per_minute(60), burst(1), 1);
        let now = Instant::now();
        limiter.check("device-a", now).unwrap();

        let result = limiter.check("device-b", now + Duration::from_secs(1));

        assert!(result.is_ok());
        assert_eq!(limiter.len(), 1);
    }

    #[test]
    fn denies_new_keys_while_all_are_busy() {
        let limiter = RateLimiter::new(per_minute(60), burst(1), 1);
        let now = Instant::now();
        limiter.check("device-a", now).unwrap();

        let result = limiter.check("device-b", now + Duration::from_millis(500));

        assert!(result.is_err());
    }

    #[test]
    fn evict_idle_keeps_busy_keys() {
        let limiter = RateLimiter::new(per_minute(60), burst(2), 10);
        let now = Instant::now();
        limiter.check("idle", now).unwrap();
        limiter.check("busy", now + Duration::from_secs(1)).unwrap();

        limiter.evict_idle(now + Duration::from_millis(1500));

        assert_eq!(limiter.len(), 1);
    }

    fn per_minute(n: u32) -> NonZeroU32 {
        NonZeroU32::new(n).unwrap()
    }

    fn burst(n: u32) -> NonZeroU32 {
        NonZeroU32::new(n).unwrap()
    }
}
