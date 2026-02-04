use connlib_model::ClientId;

/// The state of client on another client.
pub(crate) struct ClientOnClient {
    id: ClientId,
}

impl ClientOnClient {
    pub(crate) fn new(id: ClientId) -> ClientOnClient {
        ClientOnClient { id }
    }

    pub fn id(&self) -> ClientId {
        self.id
    }
}
