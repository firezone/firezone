/// Acts as a "buffer" for updates that need to be applied.
///
/// When adding one or more resources, it can happen that multiple updates to the client app need to be issued.
/// In order to not actually send multiple updates, we buffer them in here.
///
/// In the event that the very last one ends up being the state we are already in, no update is issued at all.
pub struct PendingUpdate<T> {
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
        let pending = PendingUpdate::new(None, 1);

        assert_eq!(pending.into_new(), Some(1))
    }

    #[test]
    fn discards_intermediate_updates() {
        let mut pending = PendingUpdate::new(None, 1);
        pending.update_want(2);
        pending.update_want(4);
        pending.update_want(3);
        pending.update_want(2);

        assert_eq!(pending.into_new(), Some(2))
    }

    #[test]
    fn emits_no_update_if_equal_to_initial() {
        let mut pending = PendingUpdate::new(Some(1), 2);
        pending.update_want(1);
        pending.update_want(3);
        pending.update_want(1);

        assert_eq!(pending.into_new(), None);
    }
}
