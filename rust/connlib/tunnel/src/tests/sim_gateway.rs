use super::{
    reference::{private_key, PrivateKey},
    sim_net::{any_ip_stack, any_port, host, Host},
};
use crate::GatewayState;
use connlib_shared::{messages::GatewayId, proptest::gateway_id};
use proptest::prelude::*;

/// Simulation state for a particular client.
#[derive(Debug, Clone)]
pub(crate) struct SimGateway {
    pub(crate) id: GatewayId,
}

/// Reference state for a particular gateway.
#[derive(Debug, Clone)]
pub struct RefGateway {
    pub(crate) key: PrivateKey,
}

impl RefGateway {
    /// Initialize the [`GatewayState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(self) -> GatewayState {
        GatewayState::new(self.key)
    }
}

pub(crate) fn ref_gateway_host() -> impl Strategy<Value = Host<RefGateway, SimGateway>> {
    host(any_ip_stack(), any_port(), ref_gateway(), sim_gateway())
}

fn ref_gateway() -> impl Strategy<Value = RefGateway> {
    private_key().prop_map(move |key| RefGateway { key })
}

fn sim_gateway() -> impl Strategy<Value = SimGateway> {
    gateway_id().prop_map(move |id| SimGateway { id })
}
