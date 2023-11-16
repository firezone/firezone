use std::sync::Arc;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use tokio::time::Interval;

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

/// As per recommendation on [`boringtun::noise::rate_limiter::RateLimiter::reset_count`].
const RESET_PERIOD: Duration = Duration::from_secs(1);

pub struct RateLimiter {
    inner: Arc<boringtun::noise::rate_limiter::RateLimiter>,
    reset_interval: Interval,
}

impl RateLimiter {
    pub fn new(public_key: boringtun::x25519::PublicKey) -> Self {
        Self {
            inner: Arc::new(boringtun::noise::rate_limiter::RateLimiter::new(
                &public_key,
                HANDSHAKE_RATE_LIMIT,
            )),
            reset_interval: tokio::time::interval(RESET_PERIOD),
        }
    }

    pub fn clone_to(&self) -> Arc<boringtun::noise::rate_limiter::RateLimiter> {
        self.inner.clone()
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        loop {
            ready!(self.reset_interval.poll_tick(cx));
            self.inner.reset_count();
            continue;
        }
    }
}
