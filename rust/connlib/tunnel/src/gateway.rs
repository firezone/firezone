use std::time::{Duration, Instant};

use crate::device_channel::Device;
use crate::ip_packet::{IpPacket, MutableIpPacket};
use crate::peer::{PacketTransformGateway, Peer};
use crate::peer_store::PeerStore;
use crate::sockets::Received;
use crate::utils::{earliest, stun, turn};
use crate::GatewayTunnel;
use boringtun::x25519::StaticSecret;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    Answer, ClientId, ConnectionAccepted, DomainResponse, Interface as InterfaceConfig, Key, Offer,
    Relay, ResourceId,
};
use connlib_shared::{Callbacks, Dname, Error, PublicKey, Result};
use ip_network::IpNetwork;
use pnet_packet::Packet as _;
use quinn_udp::Transmit;
use secrecy::{ExposeSecret as _, Secret};
use snownet::ServerNode;

const PEERS_IPV4: &str = "100.64.0.0/11";
const PEERS_IPV6: &str = "fd00:2021:1111::/107";

const RESOURCE_EXPIRY_INTERVAL: Duration = Duration::from_secs(1);
const PRINT_STATS_INTERVAL: Duration = Duration::from_secs(60);

/// Description of a resource that maps to a DNS record which had its domain already resolved.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ResolvedResourceDescriptionDns {
    pub id: ResourceId,
    /// Internal resource's domain name.
    pub domain: String,
    /// Name of the resource.
    ///
    /// Used only for display.
    pub name: String,

    pub addresses: Vec<IpNetwork>,
}

pub type ResourceDescription =
    connlib_shared::messages::ResourceDescription<ResolvedResourceDescriptionDns>;

impl<CB> GatewayTunnel<CB>
where
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&mut self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        // Note: the dns fallback strategy is irrelevant for gateways
        let mut device = Device::new(config, vec![], &self.callbacks)?;

        let result_v4 = device.add_route(PEERS_IPV4.parse().unwrap(), &self.callbacks);
        let result_v6 = device.add_route(PEERS_IPV6.parse().unwrap(), &self.callbacks);
        result_v4.or(result_v6)?;

        let name = device.name().to_owned();

        self.device = Some(device);
        self.no_device_waker.wake();

        tracing::debug!(ip4 = %config.ipv4, ip6 = %config.ipv6, %name, "TUN device initialized");

        Ok(())
    }

    /// Accept a connection request from a client.
    ///
    /// Sets a connection to a remote SDP, creates the local SDP
    /// and returns it.
    ///
    /// # Returns
    /// The connection details
    #[allow(clippy::too_many_arguments)]
    pub fn accept(
        &mut self,
        client_id: ClientId,
        key: Secret<Key>,
        offer: Offer,
        client: PublicKey,
        ips: Vec<IpNetwork>,
        relays: Vec<Relay>,
        domain: Option<Dname>,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
    ) -> Result<ConnectionAccepted> {
        let resource_addresses = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = domain.clone() else {
                    return Err(Error::ControlProtocolError);
                };

                if !crate::dns::is_subdomain(&domain, &r.domain) {
                    return Err(Error::InvalidResource);
                }

                r.addresses.clone()
            }
            ResourceDescription::Cidr(ref cidr) => vec![cidr.address],
        };

        let answer = self.state.node.accept_connection(
            client_id,
            snownet::Offer {
                session_key: key.expose_secret().0.into(),
                credentials: snownet::Credentials {
                    username: offer.username,
                    password: offer.password,
                },
            },
            client,
            stun(&relays, |addr| self.sockets.can_handle(addr)),
            turn(&relays, |addr| self.sockets.can_handle(addr)),
            Instant::now(),
        );

        self.new_peer(
            ips,
            client_id,
            resource,
            expires_at,
            resource_addresses.clone(),
        )?;

        Ok(ConnectionAccepted {
            ice_parameters: Answer {
                username: answer.credentials.username,
                password: answer.credentials.password,
            },
            domain_response: domain.map(|domain| DomainResponse {
                domain,
                address: resource_addresses
                    .into_iter()
                    .map(|ip| ip.network_address())
                    .collect(),
            }),
        })
    }

    /// Clean up a connection to a resource.
    pub fn cleanup_connection(&mut self, id: &ClientId) {
        self.state.peers.remove(id);
    }

    pub fn allow_access(
        &mut self,
        resource: ResourceDescription,
        client: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<Dname>,
    ) -> Option<DomainResponse> {
        let peer = self.state.peers.get_mut(&client)?;

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

    pub fn remove_access(&mut self, id: &ClientId, resource_id: &ResourceId) {
        let Some(peer) = self.state.peers.get_mut(id) else {
            return;
        };

        peer.transform.remove_resource(resource_id);
        if peer.transform.is_emptied() {
            self.state.peers.remove(id);
        }
    }

    pub fn add_ice_candidate(&mut self, conn_id: ClientId, ice_candidate: String) {
        self.state.node.add_remote_candidate(conn_id, ice_candidate);
    }

    fn new_peer(
        &mut self,
        ips: Vec<IpNetwork>,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
        resource_addresses: Vec<IpNetwork>,
    ) -> Result<()> {
        let mut peer = Peer::new(client_id, PacketTransformGateway::default(), &ips, ());

        for address in resource_addresses {
            peer.transform
                .add_resource(address, resource.clone(), expires_at);
        }

        self.state.peers.insert(peer, &ips);

        Ok(())
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    peers: PeerStore<ClientId, PacketTransformGateway, ()>,
    node: ServerNode<ClientId>,

    next_stats_at: Instant,
    next_resource_expiry_at: Instant,
}

impl GatewayState {
    pub(crate) fn new(private_key: StaticSecret, now: Instant) -> Self {
        Self {
            peers: PeerStore::default(),
            node: ServerNode::new(private_key, now),
            next_stats_at: now + PRINT_STATS_INTERVAL,
            next_resource_expiry_at: now + RESOURCE_EXPIRY_INTERVAL,
        }
    }

    pub(crate) fn encapsulate(&mut self, packet: MutableIpPacket<'_>) -> Option<Transmit> {
        let dest = packet.destination();

        let peer = self.peers.peer_by_ip_mut(dest)?;
        let connection = peer.conn_id;
        let packet = peer.transform(packet)?;

        let transmit = self
            .node
            .encapsulate(connection, packet.as_immutable().into())
            .inspect_err(|e| tracing::debug!(%connection, "Failed to encapsulate packet: {e}"))
            .ok()??;

        Some(quinn_udp::Transmit {
            destination: transmit.dst,
            ecn: None,
            contents: Bytes::copy_from_slice(transmit.payload.as_ref()),
            segment_size: None,
            src_ip: transmit.src.map(|s| s.ip()),
        })
    }

    pub(crate) fn decapsulate<'a>(
        &mut self,
        Received {
            local,
            from,
            packet,
        }: Received<'_>,
        buffer: &'a mut [u8],
    ) -> Option<IpPacket<'a>> {
        let (connection, packet) = self
            .node
            .decapsulate(
                local,
                from,
                packet.as_ref(),
                std::time::Instant::now(), // TODO: Use `now` parameter here.
                buffer,
            )
            .inspect_err(|e| tracing::debug!(%local, %from, num_bytes = %packet.len(), "Failed to decapsulate packet: {e}")).ok()??;

        tracing::trace!(target: "wire", %local, %from, bytes = %packet.packet().len(), "read new packet");

        let packet = self
            .peers
            .get_mut(&connection)?
            .untransform(packet.into())
            .inspect_err(
                |e| tracing::warn!(%connection, %local, %from, "Failed to transform packet: {e}"),
            )
            .ok()?;

        Some(packet.into_immutable())
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        let node_timeout = self.node.poll_timeout();

        earliest(
            earliest(node_timeout, Some(self.next_resource_expiry_at)),
            Some(self.next_stats_at),
        )
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);

        if now >= self.next_resource_expiry_at {
            self.expire_resources();
            self.next_resource_expiry_at = now + RESOURCE_EXPIRY_INTERVAL
        }

        if now >= self.next_stats_at {
            let (node_stats, conn_stats) = self.node.stats();

            tracing::debug!(target: "connlib::stats", "{node_stats:?}");

            for (id, stats) in conn_stats {
                tracing::debug!(target: "connlib::stats", %id, "{stats:?}");
            }

            self.next_stats_at = now + PRINT_STATS_INTERVAL;
        }
    }

    pub(crate) fn poll_event(&mut self) -> Option<Event> {
        loop {
            match self.node.poll_event() {
                Some(snownet::Event::SignalIceCandidate {
                    connection,
                    candidate,
                }) => {
                    return Some(Event::SignalIceCandidate {
                        conn_id: connection,
                        candidate,
                    })
                }
                Some(snownet::Event::ConnectionFailed(id)) => {
                    self.peers.remove(&id);
                    continue;
                }
                Some(snownet::Event::ConnectionEstablished(_)) => {
                    continue;
                }
                None => return None,
            }
        }
    }

    fn expire_resources(&mut self) {
        self.peers
            .iter_mut()
            .for_each(|p| p.transform.expire_resources());
        self.peers.retain(|_, p| !p.transform.is_emptied());
    }
}

pub enum Event {
    SignalIceCandidate {
        conn_id: ClientId,
        candidate: String,
    },
}
