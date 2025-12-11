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
