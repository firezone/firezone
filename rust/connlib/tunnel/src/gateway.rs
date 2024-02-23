use crate::device_channel::{Device, Packet};
use crate::ip_packet::MutableIpPacket;
use crate::peer::{PacketTransformGateway, Peer};
use crate::sockets::Received;
use crate::{peer_by_ip, sleep_until, Tunnel};
use boringtun::x25519::StaticSecret;
use connlib_shared::messages::{ClientId, Interface as InterfaceConfig};
use connlib_shared::Callbacks;
use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use ip_network_table::IpNetworkTable;
use itertools::Itertools;
use pnet_packet::Packet as _;
use snownet::{ServerNode, Transmit};
use std::collections::HashMap;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::time::{interval, Interval, MissedTickBehavior};

const PEERS_IPV4: &str = "100.64.0.0/11";
const PEERS_IPV6: &str = "fd00:2021:1111::/107";

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&mut self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        // Note: the dns fallback strategy is irrelevant for gateways
        let mut device = Device::new(config, vec![], self.callbacks())?;

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
        self.role_state.peers_by_id.remove(&id);
        self.role_state.peers_by_ip.retain(|_, p| p.conn_id != id);
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    #[allow(clippy::type_complexity)]
    pub peers_by_ip: IpNetworkTable<Arc<Peer<ClientId, PacketTransformGateway>>>,
    expire_interval: Interval,

    pub node: ServerNode<ClientId>,
    pub peers_by_id: HashMap<ClientId, Arc<Peer<ClientId, PacketTransformGateway>>>,
    node_timeout: BoxFuture<'static, std::time::Instant>,
}

impl GatewayState {
    pub(crate) fn encapsulate<'s>(
        &'s mut self,
        packet: MutableIpPacket<'_>,
    ) -> Option<Transmit<'s>> {
        let dest = packet.destination();

        let peer = peer_by_ip(&self.peers_by_ip, dest)?;
        let packet = peer.transform(packet)?;

        let transmit = self
            .node
            .encapsulate(peer.conn_id, packet.as_immutable().into())
            .inspect_err(
                |e| tracing::warn!(peer = %peer.conn_id, "Failed to encapsulate packet: {e}"),
            )
            .ok()??;

        Some(transmit)
    }

    pub(crate) fn decapsulate<'b>(
        &mut self,
        received: Received<'_>,
        buf: &'b mut [u8],
    ) -> Option<Packet<'b>> {
        let Received {
            local,
            from,
            packet,
        } = received;

        let (conn_id, packet) = match self.node.decapsulate(
            local,
            from,
            packet.as_ref(),
            std::time::Instant::now(),
            buf,
        ) {
            Ok(packet) => packet?,
            Err(e) => {
                tracing::warn!(%local, %from, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}");

                return None;
            }
        };

        tracing::trace!(target: "wire", %local, %from, bytes = %packet.packet().len(), "read new packet");

        let Some(peer) = self.peers_by_id.get(&conn_id) else {
            tracing::error!(%conn_id, %local, %from, "Couldn't find connection");

            return None;
        };

        let packet_len = packet.packet().len();
        let packet = match peer.untransform(packet.source(), &mut buf[..packet_len]) {
            Ok(packet) => packet,
            Err(e) => {
                tracing::warn!(%conn_id, %local, %from, "Failed to transform packet: {e}");

                return None;
            }
        };

        Some(packet)
    }

    pub fn poll_transmit(&mut self) -> Option<snownet::Transmit> {
        self.node.poll_transmit()
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        loop {
            if let Poll::Ready(instant) = self.node_timeout.poll_unpin(cx) {
                self.node.handle_timeout(instant);
                if let Some(timeout) = self.node.poll_timeout() {
                    self.node_timeout = sleep_until(timeout).boxed();
                }

                continue;
            }

            if self.expire_interval.poll_tick(cx).is_ready() {
                for id in self.expire_resources().collect::<Vec<_>>() {
                    self.peers_by_id.remove(&id);
                    self.peers_by_ip.retain(|_, p| p.conn_id != id);
                }

                continue;
            }

            return Poll::Pending;
        }
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

impl GatewayState {
    pub fn new(private_key: StaticSecret) -> Self {
        let mut expire_interval = interval(Duration::from_secs(1));
        expire_interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
        Self {
            peers_by_ip: IpNetworkTable::new(),
            expire_interval,
            node: ServerNode::new(private_key, Instant::now()),
            peers_by_id: Default::default(),
            node_timeout: sleep_until(Instant::now()).boxed(),
        }
    }
}
