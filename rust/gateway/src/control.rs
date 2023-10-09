use async_trait::async_trait;
use connlib_shared::{
    messages::{GatewayId, ResourceDescription},
    Result,
};
use firezone_tunnel::ControlSignal;

#[derive(Clone)]
pub struct ControlSignaler;

#[async_trait]
impl ControlSignal for ControlSignaler {
    async fn signal_connection_to(
        &self,
        resource: &ResourceDescription,
        _connected_gateway_ids: &[GatewayId],
        _: usize,
    ) -> Result<()> {
        tracing::warn!("A message to network resource: {resource:?} was discarded, gateways aren't meant to be used as clients.");
        Ok(())
    }
}
