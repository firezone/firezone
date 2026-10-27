use std::{ops::ControlFlow, time::Instant};

#[derive(Debug, Default)]
pub struct TimeoutCache {
    inner: Option<Instant>,
}

impl TimeoutCache {
    pub fn update(&mut self, value: impl Into<Option<Instant>>) -> Option<Instant> {
        self.inner = value.into();

        self.inner
    }

    pub fn check(&mut self, now: Instant) -> ControlFlow<()> {
        let Some(timeout) = self.inner else {
            return ControlFlow::Break(());
        };

        if timeout > now {
            return ControlFlow::Break(());
        }

        self.inner = None;

        ControlFlow::Continue(())
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn check_returns_break_if_deadline_not_reached() {
        let mut cache = TimeoutCache::default();
        let now = Instant::now();

        cache.update(now + Duration::from_secs(1));

        assert_eq!(cache.check(now), ControlFlow::Break(()));
    }

    #[test]
    fn check_returns_continue_if_deadline_reached() {
        let mut cache = TimeoutCache::default();
        let now = Instant::now();

        cache.update(now + Duration::from_secs(1));

        assert_eq!(
            cache.check(now + Duration::from_secs(1)),
            ControlFlow::Continue(())
        );
        assert_eq!(
            cache.check(now + Duration::from_secs(1)),
            ControlFlow::Break(()),
            "subsequent check should return `Break`"
        );
    }

    #[test]
    fn empty_cache_returns_break() {
        let mut cache = TimeoutCache::default();
        let now = Instant::now();

        assert_eq!(cache.check(now), ControlFlow::Break(()));
    }
}
