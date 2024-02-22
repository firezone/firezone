use crate::device_channel::Device;
use crate::ip_packet::MutableIpPacket;
use crate::peer::{PacketTransformGateway, Peer};
use crate::{peer_by_ip, Tunnel};
use connlib_shared::messages::{ClientId, Interface as InterfaceConfig};
use connlib_shared::Callbacks;
use ip_network_table::IpNetworkTable;
use itertools::Itertools;
use snownet::Server;
use std::sync::Arc;
use std::task::{ready, Context, Poll};
use std::time::Duration;
use tokio::time::{interval, Interval, MissedTickBehavior};

const PEERS_IPV4: &str = "100.64.0.0/11";
const PEERS_IPV6: &str = "fd00:2021:1111::/107";

impl<CB> Tunnel<CB, GatewayState, Server, ClientId, PacketTransformGateway>
where
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&mut self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        // Note: the dns fallback strategy is irrelevant for gateways
        let device = Device::new(config, vec![], self.callbacks())?;

        let result_v4 = device.add_route(PEERS_IPV4.parse().unwrap(), self.callbacks());
        let result_v6 = device.add_route(PEERS_IPV6.parse().unwrap(), self.callbacks());
        result_v4.or(result_v6)?;

        self.device = Some(device);
        self.no_device_waker.wake();

        tracing::debug!("background_loop_started");

        Ok(())
    }

    /// Clean up a connection to a resource.
    pub fn cleanup_connection(&mut self, id: ClientId) {
        self.connections_state.peers_by_id.remove(&id);
        self.role_state.peers_by_ip.retain(|_, p| p.conn_id != id);
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    #[allow(clippy::type_complexity)]
    pub peers_by_ip: IpNetworkTable<Arc<Peer<ClientId, PacketTransformGateway>>>,
    expire_interval: Interval,
}

impl GatewayState {
    pub(crate) fn encapsulate<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
    ) -> Option<(ClientId, MutableIpPacket<'a>)> {
        let dest = packet.destination();

        let peer = peer_by_ip(&self.peers_by_ip, dest)?;
        let packet = peer.transform(packet)?;

        Some((peer.conn_id, packet))
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Vec<ClientId>> {
        ready!(self.expire_interval.poll_tick(cx));
        Poll::Ready(self.expire_resources().collect_vec())
    }

    fn expire_resources(&self) -> impl Iterator<Item = ClientId> + '_ {
        self.peers_by_ip
            .iter()
            .unique_by(|(_, p)| p.conn_id)
            .for_each(|(_, p)| p.transform.expire_resources());
        self.peers_by_ip.iter().filter_map(|(_, p)| {
            if p.transform.is_emptied() {
                Some(p.conn_id)
            } else {
                None
            }
        })
    }
}

impl Default for GatewayState {
    fn default() -> Self {
        let mut expire_interval = interval(Duration::from_secs(1));
        expire_interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
        Self {
            peers_by_ip: IpNetworkTable::new(),
            expire_interval,
        }
    }
}
