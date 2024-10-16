use std::time::Instant;

/// Computes an instance of [`smoltcp::time::Instant`] based on a given starting point and the current time.
pub fn smol_now(boot: Instant, now: Instant) -> smoltcp::time::Instant {
    let millis_since_startup = now.duration_since(boot).as_millis();

    smoltcp::time::Instant::from_millis(millis_since_startup as i64)
}
