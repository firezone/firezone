use std::cmp::Ordering;
use std::fmt::Debug;
use std::mem;
use std::time::SystemTime;

/// A collection of events that are triggered at a specific time.
///
/// It is the caller's responsibility to keep track of actual time passing.
/// They should call [`TimeEvents::next_trigger`] to find out when to next call [`TimeEvents::pending_actions`].
#[derive(Debug)]
pub struct TimeEvents<A> {
    events: Vec<TimeEvent<A>>,
}

impl<A> TimeEvents<A>
where
    A: PartialEq,
{
    /// Add an action to be executed at the specified time.
    ///
    /// Returns the new wake deadline for convenience.
    #[must_use]
    pub fn add(&mut self, trigger: SystemTime, action: A) -> SystemTime {
        self.events.retain(|event| event.action != action);
        self.events.push(TimeEvent {
            time: trigger,
            action,
        });
        self.events.sort_unstable();

        self.next_trigger().expect("just pushed an event")
    }

    /// Remove and return all actions that are pending, given that time has advanced to `now`.
    pub fn pending_actions(&mut self, now: SystemTime) -> impl Iterator<Item = A> {
        let split_index = self
            .events
            .binary_search_by_key(&now, |event| event.time)
            .unwrap_or_else(|index| index);

        let remaining_actions = self.events.split_off(split_index);
        let events = mem::replace(&mut self.events, remaining_actions);

        tracing::trace!("Got {} pending actions", events.len());

        events.into_iter().map(|event| event.action)
    }

    /// The time at which the next action will be ready.
    pub fn next_trigger(&self) -> Option<SystemTime> {
        let first = self.events.first()?;

        Some(first.time)
    }
}

impl<A> Default for TimeEvents<A> {
    fn default() -> Self {
        Self { events: Vec::new() }
    }
}

#[derive(Debug)]
struct TimeEvent<A> {
    time: SystemTime,
    action: A,
}

impl<A> Eq for TimeEvent<A> {}

impl<A> PartialEq for TimeEvent<A> {
    fn eq(&self, other: &Self) -> bool {
        self.time == other.time
    }
}

impl<A> Ord for TimeEvent<A> {
    fn cmp(&self, other: &Self) -> Ordering {
        self.time.cmp(&other.time)
    }
}

impl<A> PartialOrd for TimeEvent<A> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(test)]
#[allow(unused_must_use)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn next_trigger_is_always_earliest_action() {
        let mut events = TimeEvents::default();
        let now = SystemTime::now();

        events.add(now + Duration::from_secs(3), "three");
        events.add(now + Duration::from_secs(1), "one");
        events.add(now + Duration::from_secs(2), "two");

        assert_eq!(events.next_trigger(), Some(now + Duration::from_secs(1)));
    }

    #[test]
    fn pending_actions_returns_actions_that_are_ready() {
        let mut events = TimeEvents::default();
        let now = SystemTime::now();

        events.add(now + Duration::from_secs(3), "three");
        events.add(now + Duration::from_secs(1), "one");
        events.add(now + Duration::from_secs(4), "two");

        assert_eq!(
            events
                .pending_actions(now + Duration::from_secs(2))
                .collect::<Vec<_>>(),
            vec!["one"]
        );
    }

    #[test]
    fn automatically_postpones_actions() {
        let mut events = TimeEvents::default();
        let now = SystemTime::now();

        events.add(now + Duration::from_secs(1), "one");
        events.add(now + Duration::from_secs(3), "one");

        assert_eq!(
            events
                .pending_actions(now + Duration::from_secs(2))
                .collect::<Vec<_>>(),
            Vec::<&'static str>::new()
        );
        assert_eq!(
            events
                .pending_actions(now + Duration::from_secs(4))
                .collect::<Vec<_>>(),
            vec!["one"]
        );
    }
}
