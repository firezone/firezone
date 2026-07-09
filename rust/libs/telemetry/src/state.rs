use parking_lot::RwLock;

use crate::{Env, sentry};

/// A non-blocking wrapper around the process-global telemetry [`State`].
pub(crate) struct SharedState(RwLock<State>);

/// The telemetry state lock was already held, so a non-blocking access declined.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
#[error("Global telemetry state lock is contended")]
pub(crate) struct Contended;

impl SharedState {
    pub(crate) const fn new() -> Self {
        Self(RwLock::new(State::new()))
    }

    /// Reads the state without blocking, declining if the lock is held.
    pub(crate) fn try_read<R>(&self, f: impl FnOnce(&State) -> R) -> Result<R, Contended> {
        let guard = self.0.try_read().ok_or(Contended)?;
        Ok(f(&guard))
    }

    /// Mutates the state without blocking, declining if the lock is held.
    pub(crate) fn try_write<R>(&self, f: impl FnOnce(&mut State) -> R) -> Result<R, Contended> {
        let mut guard = self.0.try_write().ok_or(Contended)?;
        Ok(f(&mut guard))
    }
}

/// The process-global telemetry state.
pub(crate) struct State {
    env: Option<Env>,
    firezone_id: Option<String>,
    account_slug: Option<String>,
    sentry_guard: Option<sentry::ClientInitGuard>,
}

impl State {
    const fn new() -> Self {
        Self {
            env: None,
            firezone_id: None,
            account_slug: None,
            sentry_guard: None,
        }
    }

    pub(crate) fn env(&self) -> Option<Env> {
        self.env
    }

    pub(crate) fn firezone_id(&self) -> Option<String> {
        self.firezone_id.clone()
    }

    pub(crate) fn account_slug(&self) -> Option<String> {
        self.account_slug.clone()
    }

    /// Whether a Sentry session is currently active.
    pub(crate) fn is_active(&self) -> bool {
        self.sentry_guard.is_some()
    }

    /// The `(user, env)` identity feature flags are evaluated for.
    ///
    /// `None` unless telemetry is active and both are known.
    pub(crate) fn identity(&self) -> Option<(String, Env)> {
        self.sentry_guard.as_ref()?;

        Some((self.firezone_id.clone()?, self.env?))
    }

    pub(crate) fn set_env(&mut self, env: Option<Env>) {
        self.env = env;
    }

    pub(crate) fn set_account_slug(&mut self, slug: String) {
        self.account_slug = Some(slug);
    }

    pub(crate) fn set_firezone_id(&mut self, firezone_id: Option<String>) {
        self.firezone_id = firezone_id;
    }

    pub(crate) fn set_guard(&mut self, guard: sentry::ClientInitGuard) {
        self.sentry_guard = Some(guard);
    }

    /// Takes the current Sentry guard, leaving the session without one.
    pub(crate) fn take_guard(&mut self) -> Option<sentry::ClientInitGuard> {
        self.sentry_guard.take()
    }

    /// Clears the user identity attached to the session.
    pub(crate) fn clear_identity(&mut self) {
        self.firezone_id = None;
        self.account_slug = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accessors_decline_while_write_lock_is_held() {
        let state = SharedState::new();

        state
            .try_write(|s| s.set_env(Some(Env::Production)))
            .unwrap();

        {
            // Use private field access to grab a lock.
            let _guard = state.0.try_write().unwrap();

            assert_eq!(state.try_read(|s| s.env()), Err(Contended));
            assert_eq!(state.try_write(|s| s.set_env(None)), Err(Contended));
        }

        // Once the lock is released, the same read observes the seeded value.
        assert_eq!(state.try_read(|s| s.env()), Ok(Some(Env::Production)));
    }
}
