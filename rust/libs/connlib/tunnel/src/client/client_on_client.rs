use crate::IpConfig;

/// The state of client on another client.
pub(crate) struct ClientOnClient {
    remote_tun: IpConfig,
}

impl ClientOnClient {
    pub(crate) fn new(remote_tun: IpConfig) -> ClientOnClient {
        ClientOnClient { remote_tun }
    }

    pub(crate) fn remote_tun(&self) -> IpConfig {
        self.remote_tun
    }
}
