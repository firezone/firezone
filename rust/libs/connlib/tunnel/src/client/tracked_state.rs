/// Manages a state `T` and tracks updates to it.
pub struct TrackedState<T> {
    current: Option<T>,
    pending_update: Option<PendingUpdate<T>>,
}

impl<T> Default for TrackedState<T> {
    fn default() -> Self {
        Self {
            current: Default::default(),
            pending_update: Default::default(),
        }
    }
}

impl<T> TrackedState<T>
where
    T: Clone + PartialEq,
{
    pub fn current(&self) -> Option<&T> {
        self.current.as_ref()
    }

    pub fn update(&mut self, new: T) {
        match self.pending_update.as_mut() {
            Some(pending) => pending.update_want(new.clone()),
            None => {
                self.pending_update = Some(PendingUpdate::new(self.current.clone(), new.clone()))
            }
        };
        self.current = Some(new);
    }

    pub fn take_pending_update(&mut self) -> Option<T> {
        self.pending_update.take()?.into_new()
    }
}

/// Acts as a "buffer" for updates that need to be applied.
///
/// When adding one or more resources, it can happen that multiple updates to the client app need to be issued.
/// In order to not actually send multiple updates, we buffer them in here.
///
/// In the event that the very last one ends up being the state we are already in, no update is issued at all.
struct PendingUpdate<T> {
    current: Option<T>,
    want: T,
}

impl<T> PendingUpdate<T>
where
    T: PartialEq,
{
    pub fn new(current: Option<T>, want: T) -> Self {
        Self { current, want }
    }

    pub fn update_want(&mut self, want: T) {
        self.want = want;
    }

    pub fn into_new(self) -> Option<T> {
        if let Some(current) = self.current
            && current == self.want
        {
            return None;
        };

        Some(self.want)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emits_initial_update() {
        let mut state = TrackedState::default();

        state.update(1);

        assert_eq!(state.take_pending_update(), Some(1))
    }

    #[test]
    fn discards_intermediate_updates() {
        let mut state = TrackedState::default();
        state.update(2);
        state.update(4);
        state.update(3);
        state.update(2);

        assert_eq!(state.take_pending_update(), Some(2));
        assert_eq!(state.take_pending_update(), None);
    }

    #[test]
    fn emits_no_update_if_equal_to_initial() {
        let mut state = TrackedState::default();
        state.update(1);
        let _ = state.take_pending_update();

        state.update(3);
        state.update(1);

        assert_eq!(state.take_pending_update(), None);
    }
}
