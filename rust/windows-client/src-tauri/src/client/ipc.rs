use connlib_client_shared::ResourceDescription;
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
pub(crate) enum ManagerMsg {
    Connect,
}

#[derive(Deserialize, Serialize)]
pub(crate) enum WorkerMsg {
    DisconnectedTokenExpired,
    OnDisconnect,
    OnUpdateResources(Vec<ResourceDescription>),
    TunnelReady,
}
