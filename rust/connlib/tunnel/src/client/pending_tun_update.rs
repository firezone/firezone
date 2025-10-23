use crate::TunConfig;

/// Acts as a "buffer" for updates to the TUN interface that need to be applied.
///
/// When adding one or more resources, it can happen that multiple updates to the TUN device need to be issued.
/// In order to not actually send multiple updates, we buffer them in here.
///
/// In the event that the very last one ends up being the state we are already in, no update is issued at all.
pub struct PendingTunUpdate {
    current: Option<TunConfig>,
    want: TunConfig,
}

impl PendingTunUpdate {
    pub fn new(current: Option<TunConfig>, want: TunConfig) -> Self {
        Self { current, want }
    }

    pub fn update_want(&mut self, want: TunConfig) {
        self.want = want;
    }

    pub fn into_new_config(self) -> Option<TunConfig> {
        if let Some(current) = self.current
            && current == self.want
        {
            return None;
        };

        Some(self.want)
    }
}
