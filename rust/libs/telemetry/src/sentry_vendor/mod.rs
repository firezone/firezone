//! Copied from https://github.com/getsentry/sentry-rust/blob/master/sentry/src/transports
//!
//! See https://github.com/getsentry/sentry-rust/issues/941 for discussion on how to properly reuse this.

mod sentry_rate_limiter;
mod tokio_thread;

pub use sentry_rate_limiter::{RateLimiter, RateLimitingCategory};
pub use tokio_thread::TransportThread;
