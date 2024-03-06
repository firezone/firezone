use std::task::{ready, Context, Poll};
use std::time::Duration;

use crate::control_protocol::gateway::ResourceDescription;
use crate::device_channel::Device;
use crate::ip_packet::MutableIpPacket;
use crate::peer::PacketTransformGateway;
use crate::peer_store::PeerStore;
use crate::Tunnel;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    ClientId, DomainResponse, Interface as InterfaceConfig, ResourceId,
};
use connlib_shared::{Callbacks, Dname};
use snownet::Server;
use tokio::time::{interval, Interval, MissedTickBehavior};

const PEERS_IPV4: &str = "100.64.0.0/11";
const PEERS_IPV6: &str = "fd00:2021:1111::/107";

impl<CB> Tunnel<CB, GatewayState, Server, ClientId>
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

        let name = device.name().to_owned();

        self.device = Some(device);
        self.no_device_waker.wake();

        tracing::debug!(ip4 = %config.ipv4, ip6 = %config.ipv6, %name, "TUN device initialized");

        Ok(())
    }

    /// Clean up a connection to a resource.
    pub fn cleanup_connection(&mut self, id: &ClientId) {
        self.role_state.peers.remove(id);
    }

    pub fn allow_access(
        &mut self,
        resource: ResourceDescription,
        client: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<Dname>,
    ) -> Option<DomainResponse> {
        self.role_state
            .allow_access(resource, client, expires_at, domain)
    }

    pub fn remove_access(&mut self, id: &ClientId, resource_id: &ResourceId) {
        let Some(peer) = self.role_state.peers.get_mut(id) else {
            return;
        };

        peer.transform.remove_resource(resource_id);
        if peer.transform.is_emptied() {
            self.role_state.peers.remove(id);
        }
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    pub peers: PeerStore<ClientId, PacketTransformGateway, ()>,
    expire_interval: Interval,
}

impl GatewayState {
    pub(crate) fn encapsulate<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
    ) -> Option<(ClientId, MutableIpPacket<'a>)> {
        let dest = packet.destination();

        let peer = self.peers.peer_by_ip_mut(dest)?;
        let packet = peer.transform(packet)?;

        Some((peer.conn_id, packet))
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        ready!(self.expire_interval.poll_tick(cx));
        self.expire_resources();
        Poll::Ready(())
    }

    pub fn allow_access(
        &mut self,
        resource: ResourceDescription,
        client: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<Dname>,
    ) -> Option<DomainResponse> {
        let peer = self.peers.get_mut(&client)?;

        let (addresses, resource_id) = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = domain.clone() else {
                    return None;
                };

                if !crate::dns::is_subdomain(&domain, &r.domain) {
                    return None;
                }

                (r.addresses.clone(), r.id)
            }
            ResourceDescription::Cidr(cidr) => (vec![cidr.address], cidr.id),
        };

        for address in &addresses {
            peer.transform
                .add_resource(*address, resource.clone(), expires_at);
        }

        tracing::info!(%client, resource = %resource_id, expires = ?expires_at.map(|e| e.to_rfc3339()), "Allowing access to resource");

        if let Some(domain) = domain {
            return Some(DomainResponse {
                domain,
                address: addresses.iter().map(|i| i.network_address()).collect(),
            });
        }

        None
    }

    fn expire_resources(&mut self) {
        self.peers
            .iter_mut()
            .for_each(|p| p.transform.expire_resources());
        self.peers.retain(|_, p| !p.transform.is_emptied());
    }
}

impl Default for GatewayState {
    fn default() -> Self {
        let mut expire_interval = interval(Duration::from_secs(1));
        expire_interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
        Self {
            peers: Default::default(),
            expire_interval,
        }
    }
}
