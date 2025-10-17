use crate::{ClientEvent, TunConfig};

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

    pub fn into_event(self) -> Option<ClientEvent> {
        if let Some(current) = self.current
            && current == self.want
        {
            return None;
        };

        Some(ClientEvent::TunInterfaceUpdated(self.want))
    }
}
