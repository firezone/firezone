use connlib_model::ClientId;

use crate::IpConfig;

/// The state of client on another client.
pub(crate) struct ClientOnClient {
    id: ClientId,
    remote_tun: IpConfig,
}

impl ClientOnClient {
    pub(crate) fn new(id: ClientId, remote_tun: IpConfig) -> ClientOnClient {
        ClientOnClient { id, remote_tun }
    }

    pub fn id(&self) -> ClientId {
        self.id
    }

    pub(crate) fn remote_tun(&self) -> IpConfig {
        self.remote_tun
    }
}
