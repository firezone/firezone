#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::time::{Duration, Instant};

/// A sans-IO circuit-breaker.
pub struct CircuitBreaker {
    name: String,
    state: State,
    failure_threshold: u32,
    success_threshold: u32,
    timeout: Duration,
}

/// A token for a given IO operation.
pub struct Token<'a> {
    cb: &'a mut CircuitBreaker,
}

impl<'a> Token<'a> {
    /// Consume the token and report success or failure to the circuit breaker.
    pub fn result<T, E>(self, result: Result<T, E>, now: Instant) -> Result<T, E> {
        match &result {
            Ok(_) => self.success(now),
            Err(_) => self.failure(now),
        }

        result
    }

    /// Consume the token and report success of the IO operation.
    pub fn success(self, now: Instant) {
        self.cb.handle_success(now);
    }

    /// Consume the token and report failure of the IO operation.
    pub fn failure(self, now: Instant) {
        self.cb.handle_failure(now);
    }
}

impl CircuitBreaker {
    pub fn new(
        name: impl Into<String>,
        failure_threshold: u32,
        success_threshold: u32,
        timeout: Duration,
    ) -> Self {
        Self {
            name: name.into(),
            state: State::Closed { failure_count: 0 },
            failure_threshold,
            success_threshold,
            timeout,
        }
    }

    /// Request a new token for an IO operation from the circuit breaker.
    ///
    /// If the circuit is currently open, this may get rejected.
    ///
    /// The token captures a mutable borrow from the circuit breaker and thus
    /// only one IO operation at a time is allowed.
    pub fn request_token(&mut self, now: Instant) -> Result<Token<'_>, Rejected> {
        self.update_state(now);

        match &mut self.state {
            State::Closed { .. } => Ok(Token { cb: self }),
            State::HalfOpen { attempts, .. } => {
                if *attempts < self.success_threshold {
                    *attempts += 1;
                    Ok(Token { cb: self })
                } else {
                    Err(Rejected {
                        retry_after: Duration::ZERO,
                    })
                }
            }
            State::Open { last_failure_time } => {
                let elapsed = now.duration_since(*last_failure_time);
                let retry_after = if elapsed >= self.timeout {
                    Duration::ZERO
                } else {
                    self.timeout - elapsed
                };
                Err(Rejected { retry_after })
            }
        }
    }

    fn handle_success(&mut self, now: Instant) {
        self.update_state(now);

        match &mut self.state {
            State::Closed { failure_count } => {
                *failure_count = 0;
            }
            State::HalfOpen { success_count, .. } => {
                *success_count += 1;
                if *success_count >= self.success_threshold {
                    self.transition_to_closed();
                }
            }
            State::Open { .. } => {}
        }
    }

    fn handle_failure(&mut self, now: Instant) {
        self.update_state(now);

        match &mut self.state {
            State::Closed { failure_count } => {
                *failure_count += 1;
                if *failure_count >= self.failure_threshold {
                    self.transition_to_open(now);
                }
            }
            State::HalfOpen { .. } => {
                self.transition_to_open(now);
            }
            State::Open { last_failure_time } => {
                *last_failure_time = now;
            }
        }
    }

    fn update_state(&mut self, now: Instant) {
        if let State::Open { last_failure_time } = self.state
            && now.duration_since(last_failure_time) >= self.timeout
        {
            self.transition_to_half_open();
        }
    }

    fn transition_to_closed(&mut self) {
        tracing::debug!(name = %self.name, "Transitioning to Closed");

        self.state = State::Closed { failure_count: 0 };
    }

    fn transition_to_open(&mut self, now: Instant) {
        tracing::debug!(name = %self.name, "Transitioning to Open");

        self.state = State::Open {
            last_failure_time: now,
        };
    }

    fn transition_to_half_open(&mut self) {
        tracing::debug!(name = %self.name, "Transitioning to HalfOpen");

        self.state = State::HalfOpen {
            success_count: 0,
            attempts: 0,
        };
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rejected {
    pub retry_after: Duration,
}

impl std::fmt::Display for Rejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "circuit breaker rejected request, retry after {:?}",
            self.retry_after
        )
    }
}

impl std::error::Error for Rejected {}

impl<'a> std::fmt::Debug for Token<'a> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Token").finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum State {
    Closed { failure_count: u32 },
    Open { last_failure_time: Instant },
    HalfOpen { success_count: u32, attempts: u32 },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_request_when_closed() {
        let mut cb = CircuitBreaker::new("test", 3, 2, Duration::from_secs(10));
        let now = Instant::now();

        assert!(cb.request_token(now).is_ok());
    }

    #[test]
    fn opens_after_threshold_failures() {
        let mut cb = CircuitBreaker::new("test", 3, 2, Duration::from_secs(10));
        let now = Instant::now();

        let t1 = cb.request_token(now).unwrap();
        t1.failure(now);

        let t2 = cb.request_token(now).unwrap();
        t2.failure(now);

        let t3 = cb.request_token(now).unwrap();
        t3.failure(now);

        let err = cb.request_token(now).unwrap_err();
        assert_eq!(err.retry_after, Duration::from_secs(10));
    }

    #[test]
    fn success_resets_failure_count_when_closed() {
        let mut cb = CircuitBreaker::new("test", 3, 2, Duration::from_secs(10));
        let now = Instant::now();

        let t1 = cb.request_token(now).unwrap();
        t1.failure(now);
        let t2 = cb.request_token(now).unwrap();
        t2.failure(now);

        let t3 = cb.request_token(now).unwrap();
        t3.success(now);

        let t4 = cb.request_token(now).unwrap();
        t4.failure(now);
        let t5 = cb.request_token(now).unwrap();
        t5.failure(now);

        assert!(cb.request_token(now).is_ok());
    }

    #[test]
    fn transitions_to_half_open_after_timeout() {
        let mut cb = CircuitBreaker::new("test", 3, 2, Duration::from_secs(10));
        let mut now = Instant::now();

        let t1 = cb.request_token(now).unwrap();
        t1.failure(now);
        let t2 = cb.request_token(now).unwrap();
        t2.failure(now);
        let t3 = cb.request_token(now).unwrap();
        t3.failure(now);

        now += Duration::from_secs(11);
        assert!(cb.request_token(now).is_ok());
    }

    #[test]
    fn half_open_limits_concurrent_requests() {
        let mut cb = CircuitBreaker::new("test", 3, 2, Duration::from_secs(10));
        let mut now = Instant::now();

        let t1 = cb.request_token(now).unwrap();
        t1.failure(now);
        let t2 = cb.request_token(now).unwrap();
        t2.failure(now);
        let t3 = cb.request_token(now).unwrap();
        t3.failure(now);

        now += Duration::from_secs(11);
        let _token1 = cb.request_token(now).unwrap();
        let _token2 = cb.request_token(now).unwrap();

        let err = cb.request_token(now).unwrap_err();
        assert_eq!(err.retry_after, Duration::ZERO);
    }

    #[test]
    fn half_open_closes_after_success_threshold() {
        let mut cb = CircuitBreaker::new("test", 3, 2, Duration::from_secs(10));
        let mut now = Instant::now();

        let t1 = cb.request_token(now).unwrap();
        t1.failure(now);
        let t2 = cb.request_token(now).unwrap();
        t2.failure(now);
        let t3 = cb.request_token(now).unwrap();
        t3.failure(now);

        now += Duration::from_secs(11);
        let t4 = cb.request_token(now).unwrap();
        t4.success(now);

        let t5 = cb.request_token(now).unwrap();
        t5.success(now);

        assert!(cb.request_token(now).is_ok());
    }

    #[test]
    fn half_open_reopens_on_failure() {
        let mut cb = CircuitBreaker::new("test", 3, 2, Duration::from_secs(10));
        let mut now = Instant::now();

        let t1 = cb.request_token(now).unwrap();
        t1.failure(now);
        let t2 = cb.request_token(now).unwrap();
        t2.failure(now);
        let t3 = cb.request_token(now).unwrap();
        t3.failure(now);

        now += Duration::from_secs(11);
        let t4 = cb.request_token(now).unwrap();

        t4.failure(now);
        let err = cb.request_token(now).unwrap_err();
        assert_eq!(err.retry_after, Duration::from_secs(10));
    }

    #[test]
    fn retry_after_decreases_over_time() {
        let mut cb = CircuitBreaker::new("test", 3, 2, Duration::from_secs(10));
        let mut now = Instant::now();

        let t1 = cb.request_token(now).unwrap();
        t1.failure(now);
        let t2 = cb.request_token(now).unwrap();
        t2.failure(now);
        let t3 = cb.request_token(now).unwrap();
        t3.failure(now);

        let err = cb.request_token(now).unwrap_err();
        assert_eq!(err.retry_after, Duration::from_secs(10));

        now += Duration::from_secs(3);
        let err = cb.request_token(now).unwrap_err();
        assert_eq!(err.retry_after, Duration::from_secs(7));

        now += Duration::from_secs(6);
        let err = cb.request_token(now).unwrap_err();
        assert_eq!(err.retry_after, Duration::from_secs(1));
    }
}
