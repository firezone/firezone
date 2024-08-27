use crate::dns::StubResolver;
use crate::peer_store::PeerStore;
use crate::{dns, BUF_SIZE};
use anyhow::Context;
use bimap::BiMap;
use connlib_shared::callbacks::Status;
use connlib_shared::messages::client::{Site, SiteId};
use connlib_shared::messages::ResolveRequest;
use connlib_shared::messages::{
    client::ResourceDescription, client::ResourceDescriptionCidr, Answer, DnsServer, GatewayId,
    Interface as InterfaceConfig, IpDnsServer, Key, Offer, Relay, RelayId, ResourceId,
};
use connlib_shared::{callbacks, PublicKey, StaticSecret};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, MutableIpPacket, Packet as _};
use itertools::Itertools;

use crate::peer::GatewayOnClient;
use crate::utils::{self, earliest, turn};
use crate::{ClientEvent, ClientTunnel, Tun};
use domain::base::Message;
use lru::LruCache;
use ringbuffer::{AllocRingBuffer, RingBuffer};
use secrecy::{ExposeSecret as _, Secret};
use snownet::{ClientNode, RelaySocket, Transmit};
use std::borrow::Cow;
use std::collections::hash_map::Entry;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::iter;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::num::NonZeroUsize;
use std::time::{Duration, Instant};

pub(crate) const IPV4_RESOURCES: Ipv4Network =
    match Ipv4Network::new(Ipv4Addr::new(100, 96, 0, 0), 11) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };
pub(crate) const IPV6_RESOURCES: Ipv6Network = match Ipv6Network::new(
    Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0, 0, 0, 0),
    107,
) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};

const DNS_PORT: u16 = 53;

pub(crate) const DNS_SENTINELS_V4: Ipv4Network =
    match Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24) {
        Ok(n) => n,
        Err(_) => unreachable!(),
    };
pub(crate) const DNS_SENTINELS_V6: Ipv6Network = match Ipv6Network::new(
    Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0),
    120,
) {
    Ok(n) => n,
    Err(_) => unreachable!(),
};

// The max time a dns request can be configured to live in resolvconf
// is 30 seconds. See resolvconf(5) timeout.
const IDS_EXPIRE: std::time::Duration = std::time::Duration::from_secs(60);

/// How many gateways we at most remember that we connected to.
///
/// 100 has been chosen as a pretty arbitrary value.
/// We only store [`GatewayId`]s so the memory footprint is negligible.
const MAX_REMEMBERED_GATEWAYS: NonZeroUsize = unsafe { NonZeroUsize::new_unchecked(100) };

/// How many packets we will at most buffer per resource that we are trying to connect to.
///
/// Our MTU is 1280, meaning this will at most occupy 128KB.
const MAX_BUFFERED_PACKETS_PER_RESOURCE: usize = 100;

impl ClientTunnel {
    pub fn set_resources(&mut self, resources: Vec<ResourceDescription>) {
        self.role_state.set_resources(resources);

        // FIXME: It would be good to add this event from _within_ `ClientState` but we don't want to emit duplicates.
        self.role_state
            .buffered_events
            .push_back(ClientEvent::TunRoutesUpdated {
                ip4: self.role_state.routes().filter_map(utils::ipv4).collect(),
                ip6: self.role_state.routes().filter_map(utils::ipv6).collect(),
            });
        self.role_state
            .buffered_events
            .push_back(ClientEvent::ResourcesChanged {
                resources: self.role_state.resources(),
            });
    }

    pub fn set_disabled_resources(&mut self, new_disabled_resources: BTreeSet<ResourceId>) {
        let old_routes = HashSet::<IpNetwork>::from_iter(self.role_state.routes());
        self.role_state
            .set_disabled_resource(new_disabled_resources);

        if HashSet::<IpNetwork>::from_iter(self.role_state.routes()) == old_routes {
            return;
        }

        self.role_state
            .buffered_events
            .push_back(ClientEvent::TunRoutesUpdated {
                ip4: self.role_state.routes().filter_map(utils::ipv4).collect(),
                ip6: self.role_state.routes().filter_map(utils::ipv6).collect(),
            });
    }

    pub fn set_tun(&mut self, tun: Box<dyn Tun>) {
        self.io.device_mut().set_tun(tun);
    }

    pub fn update_relays(&mut self, to_remove: BTreeSet<RelayId>, to_add: Vec<Relay>) {
        self.role_state
            .update_relays(to_remove, turn(&to_add), Instant::now())
    }

    /// Adds a the given resource to the tunnel.
    pub fn add_resource(&mut self, resource: ResourceDescription) {
        self.role_state.add_resource(resource);

        self.role_state
            .buffered_events
            .push_back(ClientEvent::TunRoutesUpdated {
                ip4: self.role_state.routes().filter_map(utils::ipv4).collect(),
                ip6: self.role_state.routes().filter_map(utils::ipv6).collect(),
            });
        self.role_state
            .buffered_events
            .push_back(ClientEvent::ResourcesChanged {
                resources: self.role_state.resources(),
            });
    }

    pub fn remove_resource(&mut self, id: ResourceId) {
        self.role_state.remove_resource(id);

        self.role_state
            .buffered_events
            .push_back(ClientEvent::TunRoutesUpdated {
                ip4: self.role_state.routes().filter_map(utils::ipv4).collect(),
                ip6: self.role_state.routes().filter_map(utils::ipv6).collect(),
            });
        self.role_state
            .buffered_events
            .push_back(ClientEvent::ResourcesChanged {
                resources: self.role_state.resources(),
            });
    }

    /// Updates the system's dns
    pub fn set_new_dns(&mut self, new_dns: Vec<IpAddr>) {
        // We store the sentinel dns both in the config and in the system's resolvers
        // but when we calculate the dns mapping, those are ignored.
        self.role_state.update_system_resolvers(new_dns);
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_new_interface_config(&mut self, config: InterfaceConfig) {
        self.role_state.update_interface_config(config);
    }

    pub fn set_resource_offline(&mut self, id: ResourceId) {
        self.role_state.set_resource_offline(id);

        self.role_state.on_connection_failed(id);

        self.role_state
            .buffered_events
            .push_back(ClientEvent::ResourcesChanged {
                resources: self.role_state.resources(),
            });
    }

    pub fn add_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.role_state
            .add_ice_candidate(conn_id, ice_candidate, Instant::now());
    }

    pub fn remove_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.role_state.remove_ice_candidate(conn_id, ice_candidate);
    }

    pub fn on_routing_details(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        site_id: SiteId,
    ) -> anyhow::Result<()> {
        self.role_state
            .on_routing_details(resource_id, gateway_id, site_id, Instant::now())
    }

    pub fn received_offer_response(
        &mut self,
        resource_id: ResourceId,
        answer: Answer,
        gateway_public_key: PublicKey,
    ) -> anyhow::Result<()> {
        self.role_state.accept_answer(
            snownet::Answer {
                credentials: snownet::Credentials {
                    username: answer.username,
                    password: answer.password,
                },
            },
            resource_id,
            gateway_public_key,
            Instant::now(),
        )?;

        Ok(())
    }
}

/// A sans-IO implementation of a Client's functionality.
///
/// Internally, this composes a [`snownet::ClientNode`] with firezone's policy engine around resources.
/// Clients differ from gateways in that they also implement a DNS resolver for DNS resources.
/// They also initiate connections to Gateways based on packets sent to Resources. Gateways only accept incoming connections.
pub struct ClientState {
    /// Manages wireguard tunnels to gateways.
    node: ClientNode<GatewayId, RelayId>,
    /// All gateways we are connected to and the associated, connection-specific state.
    peers: PeerStore<GatewayId, GatewayOnClient>,
    /// Which Resources we are trying to connect to.
    awaiting_connection_details: HashMap<ResourceId, AwaitingConnectionDetails>,

    /// Tracks which gateway to use for a particular Resource.
    resources_gateways: HashMap<ResourceId, GatewayId>,
    /// The site a gateway belongs to.
    gateways_site: HashMap<GatewayId, SiteId>,
    /// The online/offline status of a site.
    sites_status: HashMap<SiteId, Status>,

    /// All CIDR resources we know about, indexed by the IP range they cover (like `1.1.0.0/8`).
    active_cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    /// `Some` if the Internet resource is enabled.
    internet_resource: Option<ResourceId>,
    /// All resources indexed by their ID.
    resources_by_id: BTreeMap<ResourceId, ResourceDescription>,

    /// The DNS resolvers configured on the system outside of connlib.
    system_resolvers: Vec<IpAddr>,

    /// Maps from connlib-assigned IP of a DNS server back to the originally configured system DNS resolver.
    dns_mapping: BiMap<IpAddr, DnsServer>,
    /// DNS queries that had their destination IP mangled because the servers is a CIDR resource.
    ///
    /// The [`Instant`] tracks when the DNS query expires.
    mangled_dns_queries: HashMap<u16, Instant>,
    /// DNS queries that were forwarded to an upstream server, indexed by the DNS query ID + the server we sent it to.
    ///
    /// The value is a tuple of:
    ///
    /// - The [`SocketAddr`] is the original source IP.
    /// - The [`Instant`] tracks when the DNS query expires.
    ///
    /// We store an explicit expiry to avoid a memory leak in case of a non-responding DNS server.
    ///
    /// DNS query IDs don't appear to be unique across servers they are being sent to on some operating systems (looking at you, Windows).
    /// Hence, we need to index by ID + socket of the DNS server.
    forwarded_dns_queries: HashMap<(u16, SocketAddr), (SocketAddr, Instant)>,
    /// Manages internal dns records and emits forwarding event when not internally handled
    stub_resolver: StubResolver,

    /// Configuration of the TUN device, when it is up.
    interface_config: Option<InterfaceConfig>,

    /// Resources that have been disabled by the UI
    disabled_resources: BTreeSet<ResourceId>,

    /// Stores the gateways we recently connected to.
    ///
    /// We use this as a hint to the portal to re-connect us to the same gateway for a resource.
    recently_connected_gateways: LruCache<GatewayId, ()>,

    /// Whilst we are setting up a connection, we need to buffer access requests until <https://github.com/firezone/firezone/pull/6403> is rolled out to most gatewways.
    buffered_access_requests: BTreeMap<GatewayId, Vec<(ResourceId, Option<ResolveRequest>)>>,

    buffered_events: VecDeque<ClientEvent>,
    buffered_packets: VecDeque<IpPacket<'static>>,
    buffered_transmits: VecDeque<Transmit<'static>>,
}

#[derive(Debug, Clone, PartialEq)]
struct AwaitingConnectionDetails {
    last_intent_sent_at: Instant,
    domain: Option<ResolveRequest>,
    /// IP packets which need to be routed to the resource.
    packets: AllocRingBuffer<IpPacket<'static>>,
}

impl ClientState {
    pub(crate) fn new(
        private_key: impl Into<StaticSecret>,
        known_hosts: BTreeMap<String, Vec<IpAddr>>,
        seed: [u8; 32],
    ) -> Self {
        Self {
            awaiting_connection_details: Default::default(),
            resources_gateways: Default::default(),
            active_cidr_resources: IpNetworkTable::new(),
            resources_by_id: Default::default(),
            peers: Default::default(),
            dns_mapping: Default::default(),
            buffered_events: Default::default(),
            interface_config: Default::default(),
            buffered_packets: Default::default(),
            node: ClientNode::new(private_key.into(), BUF_SIZE, seed),
            system_resolvers: Default::default(),
            sites_status: Default::default(),
            gateways_site: Default::default(),
            mangled_dns_queries: Default::default(),
            forwarded_dns_queries: Default::default(),
            stub_resolver: StubResolver::new(known_hosts),
            disabled_resources: Default::default(),
            buffered_transmits: Default::default(),
            internet_resource: None,
            recently_connected_gateways: LruCache::new(MAX_REMEMBERED_GATEWAYS),
            buffered_access_requests: Default::default(),
        }
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip4(&self) -> Option<Ipv4Addr> {
        Some(self.interface_config.as_ref()?.ipv4)
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip6(&self) -> Option<Ipv6Addr> {
        Some(self.interface_config.as_ref()?.ipv6)
    }

    #[cfg(all(test, feature = "proptest"))]
    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> Option<IpAddr> {
        Some(match dst {
            IpAddr::V4(_) => self.tunnel_ip4()?.into(),
            IpAddr::V6(_) => self.tunnel_ip6()?.into(),
        })
    }

    pub(crate) fn resources(&self) -> Vec<callbacks::ResourceDescription> {
        self.resources_by_id
            .values()
            .cloned()
            .map(|r| {
                let status = self.resource_status(&r);
                r.with_status(status)
            })
            .sorted()
            .collect_vec()
    }

    fn resource_status(&self, resource: &ResourceDescription) -> Status {
        if resource.sites().iter().any(|s| {
            self.sites_status
                .get(&s.id)
                .is_some_and(|s| *s == Status::Online)
        }) {
            return Status::Online;
        }

        if resource.sites().iter().all(|s| {
            self.sites_status
                .get(&s.id)
                .is_some_and(|s| *s == Status::Offline)
        }) {
            return Status::Offline;
        }

        Status::Unknown
    }

    fn set_resource_offline(&mut self, id: ResourceId) {
        let Some(resource) = self.resources_by_id.get(&id).cloned() else {
            return;
        };

        for Site { id, .. } in resource.sites() {
            self.sites_status.insert(*id, Status::Offline);
        }
    }

    #[cfg(all(feature = "proptest", test))]
    pub(crate) fn public_key(&self) -> PublicKey {
        self.node.public_key()
    }

    fn request_access(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        maybe_domain: Option<ResolveRequest>,
    ) {
        use tracing::field;

        let domain = maybe_domain.as_ref().map(|r| field::display(&r.name));
        let proxy_ips = maybe_domain.as_ref().map(|r| field::debug(&r.proxy_ips));

        tracing::debug!(rid = %resource_id, gid = %gateway_id, domain, proxy_ips, "Requesting access");

        self.buffered_events.push_back(ClientEvent::RequestAccess {
            resource_id,
            gateway_id,
            maybe_domain,
        })
    }

    pub(crate) fn encapsulate<'s>(
        &'s mut self,
        packet: MutableIpPacket<'_>,
        now: Instant,
    ) -> Option<snownet::Transmit<'s>> {
        let (packet, dst) = match self.try_handle_dns_query(packet, now) {
            Ok(response) => {
                self.buffered_packets.push_back(response?.to_owned());
                return None;
            }
            Err(non_dns_packet) => non_dns_packet,
        };

        if is_definitely_not_a_resource(dst) {
            return None;
        }

        let Some(resource) = self.get_resource_by_destination(dst) else {
            tracing::trace!(%dst, "Unknown resource");
            return None;
        };

        let packet = maybe_mangle_dns_query_to_cidr_resource(
            packet,
            &self.dns_mapping,
            &mut self.mangled_dns_queries,
            now,
        );

        let Some(peer) = peer_by_resource_mut(&self.resources_gateways, &mut self.peers, resource)
        else {
            self.on_not_connected_resource(resource, &dst, packet.as_immutable(), now);
            return None;
        };

        let gid = peer.id();

        // Allowed IPs will track the IPs that we have sent to the gateway along with a list of ResourceIds
        // for DNS resource we will send the IP one at a time.
        if peer.allowed_ips.exact_match(dst).is_none() {
            if let Some((fqdn, ips)) = self.stub_resolver.get_fqdn(&dst) {
                self.peers.add_ips_with_resource(
                    &gid,
                    &ips.iter().copied().map_into().collect_vec(),
                    &resource,
                );

                self.request_access(
                    resource,
                    gid,
                    Some(ResolveRequest {
                        name: fqdn.clone(),
                        proxy_ips: ips.clone(),
                    }),
                );
            }
        }

        let transmit = self
            .node
            .encapsulate(gid, packet.as_immutable(), now)
            .inspect_err(|e| tracing::debug!(%gid, "Failed to encapsulate: {e}"))
            .ok()??;

        Some(transmit)
    }

    pub(crate) fn decapsulate<'b>(
        &mut self,
        local: SocketAddr,
        from: SocketAddr,
        packet: &[u8],
        now: Instant,
        buffer: &'b mut [u8],
    ) -> Option<IpPacket<'b>> {
        if let Some(response) = self.try_handle_forwarded_dns_response(from, packet) {
            return Some(response);
        };

        let (gid, packet) = self.node.decapsulate(
            local,
            from,
            packet.as_ref(),
            now,
            buffer,
        )
        .inspect_err(|e| tracing::debug!(%local, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}"))
        .ok()??;

        let Some(peer) = self.peers.get_mut(&gid) else {
            tracing::error!(%gid, "Couldn't find connection by ID");

            return None;
        };

        peer.ensure_allowed_src(&packet)
            .inspect_err(|e| tracing::debug!(%gid, %local, %from, "{e}"))
            .ok()?;

        let packet = maybe_mangle_dns_response_from_cidr_resource(
            packet,
            &self.dns_mapping,
            &mut self.mangled_dns_queries,
            now,
        );

        Some(packet.into_immutable())
    }

    pub fn add_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String, now: Instant) {
        self.node.add_remote_candidate(conn_id, ice_candidate, now);
    }

    pub fn remove_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.node.remove_remote_candidate(conn_id, ice_candidate);
    }

    pub fn accept_answer(
        &mut self,
        answer: snownet::Answer,
        resource_id: ResourceId,
        gateway: PublicKey,
        now: Instant,
    ) -> anyhow::Result<()> {
        debug_assert!(!self.awaiting_connection_details.contains_key(&resource_id));

        let gateway_id = self
            .gateway_by_resource(&resource_id)
            .with_context(|| format!("No gateway associated with resource {resource_id}"))?;

        tracing::Span::current().record("gid", tracing::field::display(gateway_id));

        self.node.accept_answer(gateway_id, gateway, answer, now);

        let Some(buffered_allow_access_requests) =
            self.buffered_access_requests.remove(&gateway_id)
        else {
            return Ok(());
        };

        for (resource_id, maybe_domain) in buffered_allow_access_requests {
            self.request_access(resource_id, gateway_id, maybe_domain)
        }

        Ok(())
    }

    /// Updates the "routing table".
    ///
    /// In a nutshell, this tells us which gateway in which site to use for the given resource.
    pub fn on_routing_details(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        site_id: SiteId,
        now: Instant,
    ) -> anyhow::Result<()> {
        tracing::debug!(rid = %resource_id, gid = %gateway_id, "Updating resource routing table");

        let desc = self
            .resources_by_id
            .get(&resource_id)
            .context("Unknown resource")?;

        let awaiting_connection_details = self
            .awaiting_connection_details
            .remove(&resource_id)
            .context("No connection details found for resource")?;
        let ips = get_addresses_for_awaiting_resource(desc, &awaiting_connection_details);

        if let Some(old_gateway_id) = self.resources_gateways.insert(resource_id, gateway_id) {
            if self.peers.get(&old_gateway_id).is_some() {
                assert_eq!(old_gateway_id, gateway_id, "Resources are not expected to change gateways without a previous message, resource_id = {resource_id}");
            }
        }

        self.gateways_site.insert(gateway_id, site_id);
        self.recently_connected_gateways.put(gateway_id, ());
        self.peers
            .add_ips_with_resource(&gateway_id, &ips, &resource_id);

        if !self.node.has_connection(gateway_id) {
            let (offer, buffer) = self.node.new_connection(
                gateway_id,
                awaiting_connection_details.last_intent_sent_at,
                now,
            );
            buffer.extend(awaiting_connection_details.packets);

            self.buffered_events
                .push_back(ClientEvent::RequestConnection {
                    resource_id,
                    gateway_id,
                    preshared_key: Secret::new(Key(*offer.session_key.expose_secret())),
                    offer: Offer {
                        username: offer.credentials.username,
                        password: offer.credentials.password,
                    },
                    maybe_domain: awaiting_connection_details.domain,
                });

            return Ok(());
        }

        for packet in awaiting_connection_details.packets {
            match self.node.encapsulate(gateway_id, packet, now) {
                Ok(Some(transmit)) => self.buffered_transmits.push_back(transmit.into_owned()),
                Err(other) => {
                    tracing::debug!("Failed to encapsulate buffered packet: {other}");
                }
                Ok(None) => {}
            }
        }

        // Once most / all gateways can handle out-of-order allow-access request, we can remove this buffering.
        // See <https://github.com/firezone/firezone/pull/6403>.
        if self.node.is_connecting(gateway_id).is_some() {
            tracing::debug!("Still connecting to gateway, buffering allow access");

            self.buffered_access_requests
                .entry(gateway_id)
                .or_default()
                .push((resource_id, awaiting_connection_details.domain))
        } else {
            self.request_access(resource_id, gateway_id, awaiting_connection_details.domain);
        }

        Ok(())
    }

    fn is_upstream_set_by_the_portal(&self) -> bool {
        let Some(interface) = &self.interface_config else {
            return false;
        };

        !interface.upstream_dns.is_empty()
    }

    /// For DNS queries to IPs that are a CIDR resources we want to mangle and forward to the gateway that handles that resource.
    ///
    /// We only want to do this if the upstream DNS server is set by the portal, otherwise, the server might be a local IP.
    fn should_forward_dns_query_to_gateway(&self, dns_server: IpAddr) -> bool {
        if !self.is_upstream_set_by_the_portal() {
            return false;
        }
        if self.internet_resource.is_some() {
            return true;
        }

        self.active_cidr_resources
            .longest_match(dns_server)
            .is_some()
    }

    /// Attempt to handle the given packet as a DNS query packet.
    ///
    /// Returns `Ok` if the packet is in fact a DNS query with an optional response to send back.
    /// Returns `Err` if the packet is not a DNS query.
    fn try_handle_dns_query<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
        now: Instant,
    ) -> Result<Option<IpPacket<'a>>, (MutableIpPacket<'a>, IpAddr)> {
        match self
            .stub_resolver
            .handle(&self.dns_mapping, packet.as_immutable())
        {
            Some(dns::ResolveStrategy::LocalResponse(query)) => Ok(Some(query)),
            Some(dns::ResolveStrategy::ForwardQuery {
                upstream: server,
                query_id,
                payload,
                original_src,
            }) => {
                let ip = server.ip();

                if self.should_forward_dns_query_to_gateway(ip) {
                    return Err((packet, ip));
                }

                tracing::trace!(%server, %query_id, "Forwarding DNS query");

                self.forwarded_dns_queries
                    .insert((query_id, server), (original_src, now + IDS_EXPIRE));
                self.buffered_transmits.push_back(Transmit {
                    src: None,
                    dst: server,
                    payload: Cow::Owned(payload),
                });

                Ok(None)
            }
            None => {
                let dest = packet.destination();
                Err((packet, dest))
            }
        }
    }

    fn try_handle_forwarded_dns_response<'a>(
        &mut self,
        from: SocketAddr,
        packet: &[u8],
    ) -> Option<IpPacket<'a>> {
        // The sentinel DNS server shall be the source. If we don't have a sentinel DNS for this socket, it cannot be a DNS response.
        let saddr = *self.dns_mapping.get_by_right(&DnsServer::from(from))?;
        let sport = DNS_PORT;

        let message = Message::from_slice(packet).ok()?;
        let query_id = message.header().id();

        let (destination, _) = self.forwarded_dns_queries.remove(&(query_id, from))?;

        tracing::trace!(server = %from, %query_id, "Received forwarded DNS response");

        let daddr = destination.ip();
        let dport = destination.port();

        let ip_packet = ip_packet::make::udp_packet(saddr, daddr, sport, dport, packet.to_vec())
            .inspect_err(|_| tracing::warn!("Failed to find original dst for DNS response"))
            .ok()?;

        Some(ip_packet.into_immutable())
    }

    pub fn on_connection_failed(&mut self, resource: ResourceId) {
        self.awaiting_connection_details.remove(&resource);
        self.resources_gateways.remove(&resource);

        for requests in self.buffered_access_requests.values_mut() {
            requests.retain(|(r, _)| r != &resource)
        }
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%resource))]
    fn on_not_connected_resource(
        &mut self,
        resource: ResourceId,
        destination: &IpAddr,
        packet: IpPacket,
        now: Instant,
    ) {
        debug_assert!(self.resources_by_id.contains_key(&resource));

        if let Some(buffer) = self
            .gateway_by_resource(&resource)
            .and_then(|gateway_id| self.node.is_connecting(gateway_id))
        {
            buffer.extend(iter::once(packet.to_owned()));

            return;
        }

        match self.awaiting_connection_details.entry(resource) {
            Entry::Occupied(mut occupied) => {
                let time_since_last_intent = now.duration_since(occupied.get().last_intent_sent_at);

                occupied.get_mut().packets.push(packet.to_owned());

                if time_since_last_intent < Duration::from_secs(2) {
                    tracing::trace!(?time_since_last_intent, "Skipping connection intent");

                    return;
                }

                occupied.get_mut().last_intent_sent_at = now;
            }
            Entry::Vacant(vacant) => {
                let mut packets = AllocRingBuffer::new(MAX_BUFFERED_PACKETS_PER_RESOURCE);
                packets.push(packet.to_owned());

                vacant.insert(AwaitingConnectionDetails {
                    last_intent_sent_at: now,
                    // Note: in case of an overlapping CIDR resource this should be None instead of Some if the resource_id
                    // is for a CIDR resource.
                    // But this should never happen as DNS resources are always preferred, so we don't encode the logic here.
                    // Tests will prevent this from ever happening.
                    domain: self.stub_resolver.get_fqdn(destination).map(|(fqdn, ips)| {
                        ResolveRequest {
                            name: fqdn.clone(),
                            proxy_ips: ips.clone(),
                        }
                    }),
                    packets,
                });
            }
        }

        tracing::debug!("Sending connection intent");

        // We tell the portal about all gateways we ever connected to, to encourage re-connecting us to the same ones during a session.
        // The LRU cache visits them in MRU order, meaning a gateway that we recently connected to should still be preferred.
        let connected_gateway_ids = self
            .recently_connected_gateways
            .iter()
            .map(|(g, _)| *g)
            .collect();

        self.buffered_events
            .push_back(ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids,
            });
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    fn set_dns_mapping(&mut self, new_mapping: BiMap<IpAddr, DnsServer>) {
        tracing::debug!(mapping = ?new_mapping, "Updating DNS servers");

        self.dns_mapping = new_mapping;
        self.mangled_dns_queries.clear();
    }

    pub fn set_disabled_resource(&mut self, new_disabled_resources: BTreeSet<ResourceId>) {
        let current_disabled_resources = self.disabled_resources.clone();

        // We set disabled_resources before anything else so that add_resource knows what resources are enabled right now.
        self.disabled_resources.clone_from(&new_disabled_resources);

        for re_enabled_resource in current_disabled_resources.difference(&new_disabled_resources) {
            let Some(resource) = self.resources_by_id.get(re_enabled_resource) else {
                continue;
            };

            self.add_resource(resource.clone());
        }

        for disabled_resource in &new_disabled_resources {
            self.disable_resource(*disabled_resource);
        }
    }

    pub fn dns_mapping(&self) -> BiMap<IpAddr, DnsServer> {
        self.dns_mapping.clone()
    }

    #[tracing::instrument(level = "debug", skip_all, fields(gateway = %gateway_id))]
    pub fn cleanup_connected_gateway(&mut self, gateway_id: &GatewayId) {
        self.update_site_status_by_gateway(gateway_id, Status::Unknown);
        self.peers.remove(gateway_id);
        self.resources_gateways.retain(|_, g| g != gateway_id);
    }

    fn routes(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.active_cidr_resources
            .iter()
            .map(|(ip, _)| ip)
            .chain(iter::once(IPV4_RESOURCES.into()))
            .chain(iter::once(IPV6_RESOURCES.into()))
            .chain(
                self.internet_resource
                    .map(|_| Ipv4Network::DEFAULT_ROUTE.into()),
            )
            .chain(
                self.internet_resource
                    .map(|_| Ipv6Network::DEFAULT_ROUTE.into()),
            )
            .chain(self.dns_mapping.left_values().copied().map(Into::into))
    }

    fn is_resource_enabled(&self, resource: &ResourceId) -> bool {
        !self.disabled_resources.contains(resource) && self.resources_by_id.contains_key(resource)
    }

    fn get_resource_by_destination(&self, destination: IpAddr) -> Option<ResourceId> {
        // We need to filter disabled resources because we never remove resources from the stub_resolver
        let maybe_dns_resource_id = self
            .stub_resolver
            .resolve_resource_by_ip(&destination)
            .filter(|resource| self.is_resource_enabled(resource));

        // We don't need to filter from here because resources are removed from the active_cidr_resources as soon as they are disabled.
        let maybe_cidr_resource_id = self
            .active_cidr_resources
            .longest_match(destination)
            .map(|(_, res)| res.id);

        maybe_dns_resource_id
            .or(maybe_cidr_resource_id)
            .or(self.internet_resource)
    }

    pub(crate) fn update_system_resolvers(&mut self, new_dns: Vec<IpAddr>) {
        self.system_resolvers = new_dns;

        self.update_dns_mapping()
    }

    pub(crate) fn update_interface_config(&mut self, config: InterfaceConfig) {
        self.interface_config = Some(config);

        self.update_dns_mapping()
    }

    pub fn poll_packets(&mut self) -> Option<IpPacket<'static>> {
        self.buffered_packets.pop_front()
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        // The number of mangled DNS queries is expected to be fairly small because we only track them whilst connecting to a CIDR resource that is a DNS server.
        // Thus, sorting these values on-demand even within `poll_timeout` is expected to be performant enough.
        let next_dns_query_expiry = self.mangled_dns_queries.values().min().copied();
        let next_node_timeout = self.node.poll_timeout();

        earliest(next_dns_query_expiry, next_node_timeout)
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);
        self.mangled_dns_queries.retain(|_, exp| now < *exp);
        self.forwarded_dns_queries.retain(|_, (_, exp)| now < *exp);

        self.drain_node_events();
    }

    fn drain_node_events(&mut self) {
        let mut resources_changed = false; // Track this separately to batch together `ResourcesChanged` events.
        let mut added_ice_candidates = BTreeMap::<GatewayId, BTreeSet<String>>::default();
        let mut removed_ice_candidates = BTreeMap::<GatewayId, BTreeSet<String>>::default();

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) | snownet::Event::ConnectionClosed(id) => {
                    self.cleanup_connected_gateway(&id);
                    resources_changed = true;
                }
                snownet::Event::NewIceCandidate {
                    connection,
                    candidate,
                } => {
                    added_ice_candidates
                        .entry(connection)
                        .or_default()
                        .insert(candidate);
                }
                snownet::Event::InvalidateIceCandidate {
                    connection,
                    candidate,
                } => {
                    removed_ice_candidates
                        .entry(connection)
                        .or_default()
                        .insert(candidate);
                }
                snownet::Event::ConnectionEstablished(id) => {
                    self.update_site_status_by_gateway(&id, Status::Online);
                    resources_changed = true;
                }
            }
        }

        if resources_changed {
            self.buffered_events
                .push_back(ClientEvent::ResourcesChanged {
                    resources: self.resources(),
                });
        }

        for (conn_id, candidates) in added_ice_candidates.into_iter() {
            self.buffered_events
                .push_back(ClientEvent::AddedIceCandidates {
                    conn_id,
                    candidates,
                })
        }

        for (conn_id, candidates) in removed_ice_candidates.into_iter() {
            self.buffered_events
                .push_back(ClientEvent::RemovedIceCandidates {
                    conn_id,
                    candidates,
                })
        }
    }

    fn update_site_status_by_gateway(&mut self, gateway_id: &GatewayId, status: Status) {
        // Note: we can do this because in theory we shouldn't have multiple gateways for the same site
        // connected at the same time.
        self.sites_status.insert(
            *self.gateways_site.get(gateway_id).expect(
                "if we're updating a site status there should be an associated site to a gateway",
            ),
            status,
        );
    }

    pub(crate) fn poll_event(&mut self) -> Option<ClientEvent> {
        self.buffered_events.pop_front()
    }

    pub(crate) fn reset(&mut self) {
        tracing::info!("Resetting network state");

        self.node.reset();
        self.recently_connected_gateways.clear(); // Ensure we don't have sticky gateways when we roam.
        self.drain_node_events();
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit<'static>> {
        self.buffered_transmits
            .pop_front()
            .or_else(|| self.node.poll_transmit())
    }

    /// Sets a new set of resources.
    ///
    /// This function does **not** perform a blanket "clear all and set new resources".
    /// Instead, it diffs which resources to remove first and then adds the new ones.
    ///
    /// Removing a resource interrupts routing for all packets, even if the resource is added back right away because [`GatewayOnClient`] tracks the allowed IPs which has to contain the resource ID.
    ///
    /// TODO: Add a test that asserts the above.
    ///       That is tricky because we need to assert on state deleted by [`ClientState::remove_resource`] and check that it did in fact not get deleted.
    pub(crate) fn set_resources(&mut self, new_resources: Vec<ResourceDescription>) {
        let current_resource_ids = self
            .resources_by_id
            .keys()
            .copied()
            .collect::<BTreeSet<_>>();
        let new_resource_ids = new_resources.iter().map(|r| r.id()).collect();

        tracing::debug!(?current_resource_ids, ?new_resource_ids);

        // First, remove all resources that are not present in the new resource list.
        for id in current_resource_ids.difference(&new_resource_ids).copied() {
            self.remove_resource(id);
        }

        // Second, add all resources.
        for resource in new_resources {
            self.add_resource(resource)
        }
    }

    pub(crate) fn add_resource(&mut self, new_resource: ResourceDescription) {
        if let Some(resource) = self.resources_by_id.get(&new_resource.id()) {
            if resource.has_different_address(&new_resource) {
                self.remove_resource(resource.id());
            }
        }

        self.resources_by_id
            .insert(new_resource.id(), new_resource.clone());

        if !self.is_resource_enabled(&(new_resource.id())) {
            return;
        }

        let added = match &new_resource {
            ResourceDescription::Dns(dns) => {
                self.stub_resolver.add_resource(dns.id, dns.address.clone())
            }
            ResourceDescription::Cidr(cidr) => {
                let existing = self
                    .active_cidr_resources
                    .insert(cidr.address, cidr.clone());

                match existing {
                    Some(existing) => existing.id != cidr.id,
                    None => true,
                }
            }
            ResourceDescription::Internet(resource) => {
                self.internet_resource.replace(resource.id) != Some(resource.id)
            }
        };

        if !added {
            return;
        }

        let name = new_resource.name();
        let address = new_resource.address_string().map(tracing::field::display);
        let sites = new_resource.sites_string();

        tracing::info!(%name, address, %sites, "Activating resource");
    }

    #[tracing::instrument(level = "debug", skip_all, fields(?id))]
    pub(crate) fn remove_resource(&mut self, id: ResourceId) {
        self.disable_resource(id);
        self.resources_by_id.remove(&id);
    }

    fn disable_resource(&mut self, id: ResourceId) {
        let Some(resource) = self.resources_by_id.get(&id) else {
            return;
        };

        match resource {
            ResourceDescription::Dns(_) => self.stub_resolver.remove_resource(id),
            ResourceDescription::Cidr(_) => self.active_cidr_resources.retain(|_, r| r.id != id),
            ResourceDescription::Internet(_) => {
                if self.internet_resource.is_some_and(|r_id| r_id == id) {
                    self.internet_resource = None;
                }
            }
        }

        let name = resource.name();
        let address = resource.address_string().map(tracing::field::display);
        let sites = resource.sites_string();

        tracing::info!(%name, address, %sites, "Deactivating resource");

        self.awaiting_connection_details.remove(&id);

        let Some(peer) = peer_by_resource_mut(&self.resources_gateways, &mut self.peers, id) else {
            return;
        };
        let gateway_id = peer.id();

        // First we remove the id from all allowed ips
        for (_, resources) in peer
            .allowed_ips
            .iter_mut()
            .filter(|(_, resources)| resources.contains(&id))
        {
            resources.remove(&id);

            if !resources.is_empty() {
                continue;
            }
        }

        // We remove all empty allowed ips entry since there's no resource that corresponds to it
        peer.allowed_ips.retain(|_, r| !r.is_empty());

        // If there's no allowed ip left we remove the whole peer because there's no point on keeping it around
        if peer.allowed_ips.is_empty() {
            self.peers.remove(&gateway_id);
            self.update_site_status_by_gateway(&gateway_id, Status::Unknown);
            // TODO: should we have a Node::remove_connection?
        }

        self.resources_gateways.remove(&id);
    }

    fn update_dns_mapping(&mut self) {
        let Some(config) = &self.interface_config else {
            tracing::debug!("Unable to update DNS servesr without interface configuration");

            return;
        };

        let effective_dns_servers =
            effective_dns_servers(config.upstream_dns.clone(), self.system_resolvers.clone());

        if HashSet::<&DnsServer>::from_iter(effective_dns_servers.iter())
            == HashSet::from_iter(self.dns_mapping.right_values())
        {
            tracing::debug!("Effective DNS servers are unchanged");

            return;
        }

        let dns_mapping = sentinel_dns_mapping(
            &effective_dns_servers,
            self.dns_mapping()
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        let ip4 = config.ipv4;
        let ip6 = config.ipv6;

        self.set_dns_mapping(dns_mapping);

        self.buffered_events
            .push_back(ClientEvent::TunInterfaceUpdated {
                ip4,
                ip6,
                dns_by_sentinel: self
                    .dns_mapping
                    .iter()
                    .map(|(sentinel_dns, effective_dns)| (*sentinel_dns, effective_dns.address()))
                    .collect(),
            });
        self.buffered_events
            .push_back(ClientEvent::TunRoutesUpdated {
                ip4: self.routes().filter_map(utils::ipv4).collect(),
                ip6: self.routes().filter_map(utils::ipv6).collect(),
            });
    }

    pub fn update_relays(
        &mut self,
        to_remove: BTreeSet<RelayId>,
        to_add: BTreeSet<(RelayId, RelaySocket, String, String, String)>,
        now: Instant,
    ) {
        self.node.update_relays(to_remove, &to_add, now);
    }
}

fn peer_by_resource_mut<'p>(
    resources_gateways: &HashMap<ResourceId, GatewayId>,
    peers: &'p mut PeerStore<GatewayId, GatewayOnClient>,
    resource: ResourceId,
) -> Option<&'p mut GatewayOnClient> {
    let gateway_id = resources_gateways.get(&resource)?;
    let peer = peers.get_mut(gateway_id)?;

    Some(peer)
}

fn get_addresses_for_awaiting_resource(
    desc: &ResourceDescription,
    awaiting_connection_details: &AwaitingConnectionDetails,
) -> Vec<IpNetwork> {
    match desc {
        ResourceDescription::Dns(_) => awaiting_connection_details
            .domain
            .as_ref()
            .expect("for dns resources the awaiting connection should have an ip")
            .proxy_ips
            .iter()
            .copied()
            .map_into()
            .collect_vec(),
        ResourceDescription::Cidr(r) => vec![r.address],
        ResourceDescription::Internet(_) => vec![
            Ipv4Network::DEFAULT_ROUTE.into(),
            Ipv6Network::DEFAULT_ROUTE.into(),
        ],
    }
}

fn effective_dns_servers(
    upstream_dns: Vec<DnsServer>,
    default_resolvers: Vec<IpAddr>,
) -> Vec<DnsServer> {
    let mut upstream_dns = upstream_dns.into_iter().filter_map(not_sentinel).peekable();
    if upstream_dns.peek().is_some() {
        return upstream_dns.collect();
    }

    let mut dns_servers = default_resolvers
        .into_iter()
        .map(|ip| {
            DnsServer::IpPort(IpDnsServer {
                address: (ip, DNS_PORT).into(),
            })
        })
        .filter_map(not_sentinel)
        .peekable();

    if dns_servers.peek().is_none() {
        tracing::warn!("No system default DNS servers available! Can't initialize resolver. DNS interception will be disabled.");
        return Vec::new();
    }

    dns_servers.collect()
}

fn not_sentinel(srv: DnsServer) -> Option<DnsServer> {
    let is_v4_dns = IpNetwork::V4(DNS_SENTINELS_V4).contains(srv.ip());
    let is_v6_dns = IpNetwork::V6(DNS_SENTINELS_V6).contains(srv.ip());

    (!is_v4_dns && !is_v6_dns).then_some(srv)
}

fn sentinel_dns_mapping(
    dns: &[DnsServer],
    old_sentinels: Vec<IpNetwork>,
) -> BiMap<IpAddr, DnsServer> {
    let mut ip_provider = IpProvider::for_stub_dns_servers(old_sentinels);

    dns.iter()
        .cloned()
        .map(|i| {
            (
                ip_provider
                    .get_proxy_ip_for(&i.ip())
                    .expect("We only support up to 256 IPv4 DNS servers and 256 IPv6 DNS servers"),
                i,
            )
        })
        .collect()
}
/// Compares the given [`IpAddr`] against a static set of ignored IPs that are definitely not resources.
fn is_definitely_not_a_resource(ip: IpAddr) -> bool {
    /// Source: https://en.wikipedia.org/wiki/Multicast_address#Notable_IPv4_multicast_addresses
    const IPV4_IGMP_MULTICAST: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 22);

    /// Source: <https://en.wikipedia.org/wiki/Multicast_address#Notable_IPv6_multicast_addresses>
    const IPV6_MULTICAST_ALL_ROUTERS: Ipv6Addr = Ipv6Addr::new(0xFF02, 0, 0, 0, 0, 0, 0, 0x0002);

    match ip {
        IpAddr::V4(ip4) => {
            if ip4 == IPV4_IGMP_MULTICAST {
                return true;
            }
        }
        IpAddr::V6(ip6) => {
            if ip6 == IPV6_MULTICAST_ALL_ROUTERS {
                return true;
            }
        }
    }

    false
}

/// In case the given packet is a DNS query, change its source IP to that of the actual DNS server.
fn maybe_mangle_dns_query_to_cidr_resource<'p>(
    mut packet: MutableIpPacket<'p>,
    dns_mapping: &BiMap<IpAddr, DnsServer>,
    mangeled_dns_queries: &mut HashMap<u16, Instant>,
    now: Instant,
) -> MutableIpPacket<'p> {
    let dst = packet.destination();

    let Some(srv) = dns_mapping.get_by_left(&dst) else {
        return packet;
    };

    let Some(dgm) = packet.as_udp() else {
        return packet;
    };

    let Ok(message) = domain::base::Message::from_slice(dgm.payload()) else {
        return packet;
    };

    tracing::trace!(old_dst = %dst, new_dst = %srv.ip(), "Mangling DNS query to CIDR resource");

    mangeled_dns_queries.insert(message.header().id(), now + IDS_EXPIRE);
    packet.set_dst(srv.ip());
    packet.update_checksum();

    packet
}

fn maybe_mangle_dns_response_from_cidr_resource<'p>(
    mut packet: MutableIpPacket<'p>,
    dns_mapping: &BiMap<IpAddr, DnsServer>,
    mangeled_dns_queries: &mut HashMap<u16, Instant>,
    now: Instant,
) -> MutableIpPacket<'p> {
    let src_ip = packet.source();

    let Some(udp) = packet.as_udp() else {
        return packet;
    };

    let src_port = udp.get_source();

    let Some(sentinel) = dns_mapping.get_by_right(&DnsServer::from((src_ip, src_port))) else {
        return packet;
    };

    let Ok(message) = domain::base::Message::from_slice(udp.payload()) else {
        return packet;
    };

    let Some(query_sent_at) = mangeled_dns_queries
        .remove(&message.header().id())
        .map(|expires_at| expires_at - IDS_EXPIRE)
    else {
        return packet;
    };

    let rtt = now.duration_since(query_sent_at);

    let domains = message
        .question()
        .filter_map(|q| Some(q.ok()?.into_qname()))
        .join(",");

    tracing::trace!(old_src = %src_ip, new_src = %sentinel, ?rtt, %domains, "Mangling DNS response from CIDR resource");

    packet.set_src(*sentinel);
    packet.update_checksum();

    packet
}

pub struct IpProvider {
    ipv4: Box<dyn Iterator<Item = Ipv4Addr> + Send + Sync>,
    ipv6: Box<dyn Iterator<Item = Ipv6Addr> + Send + Sync>,
}

impl IpProvider {
    pub fn for_resources() -> Self {
        IpProvider::new(
            IPV4_RESOURCES,
            IPV6_RESOURCES,
            vec![
                IpNetwork::V4(DNS_SENTINELS_V4),
                IpNetwork::V6(DNS_SENTINELS_V6),
            ],
        )
    }

    pub fn for_stub_dns_servers(exclusions: Vec<IpNetwork>) -> Self {
        IpProvider::new(DNS_SENTINELS_V4, DNS_SENTINELS_V6, exclusions)
    }

    fn new(ipv4: Ipv4Network, ipv6: Ipv6Network, exclusions: Vec<IpNetwork>) -> Self {
        Self {
            ipv4: Box::new({
                let exclusions = exclusions.clone();
                ipv4.hosts()
                    .filter(move |ip| !exclusions.iter().any(|e| e.contains(*ip)))
            }),
            ipv6: Box::new({
                ipv6.subnets_with_prefix(128)
                    .map(|ip| ip.network_address())
                    .filter(move |ip| !exclusions.iter().any(|e| e.contains(*ip)))
            }),
        }
    }

    pub fn get_proxy_ip_for(&mut self, ip: &IpAddr) -> Option<IpAddr> {
        let proxy_ip = match ip {
            IpAddr::V4(_) => self.ipv4.next().map(Into::into),
            IpAddr::V6(_) => self.ipv6.next().map(Into::into),
        };

        if proxy_ip.is_none() {
            // TODO: we might want to make the iterator cyclic or another strategy to prevent ip exhaustion
            // this might happen in ipv4 if tokens are too long lived.
            tracing::error!("IP exhaustion: Please reset your client");
        }

        proxy_ip
    }

    pub fn get_n_ipv4(&mut self, n: usize) -> Vec<IpAddr> {
        self.ipv4.by_ref().take(n).map_into().collect_vec()
    }

    pub fn get_n_ipv6(&mut self, n: usize) -> Vec<IpAddr> {
        self.ipv6.by_ref().take(n).map_into().collect_vec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::OsRng;

    #[test]
    fn ignores_ip4_igmp_multicast() {
        assert!(is_definitely_not_a_resource(ip("224.0.0.22")))
    }

    #[test]
    fn ignores_ip6_multicast_all_routers() {
        assert!(is_definitely_not_a_resource(ip("ff02::2")))
    }

    #[test]
    fn sentinel_dns_works() {
        let servers = dns_list();
        let sentinel_dns = sentinel_dns_mapping(&servers, vec![]);

        for server in servers {
            assert!(sentinel_dns
                .get_by_right(&server)
                .is_some_and(|s| sentinel_ranges().iter().any(|e| e.contains(*s))))
        }
    }

    #[test]
    fn sentinel_dns_excludes_old_ones() {
        let servers = dns_list();
        let sentinel_dns_old = sentinel_dns_mapping(&servers, vec![]);
        let sentinel_dns_new = sentinel_dns_mapping(
            &servers,
            sentinel_dns_old
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        assert!(
            HashSet::<&IpAddr>::from_iter(sentinel_dns_old.left_values())
                .is_disjoint(&HashSet::from_iter(sentinel_dns_new.left_values()))
        )
    }

    impl ClientState {
        pub fn for_test() -> ClientState {
            ClientState::new(
                StaticSecret::random_from_rng(OsRng),
                BTreeMap::new(),
                rand::random(),
            )
        }
    }

    fn sentinel_ranges() -> Vec<IpNetwork> {
        vec![
            IpNetwork::V4(DNS_SENTINELS_V4),
            IpNetwork::V6(DNS_SENTINELS_V6),
        ]
    }

    fn dns_list() -> Vec<DnsServer> {
        vec![
            dns("1.1.1.1:53"),
            dns("1.0.0.1:53"),
            dns("[2606:4700:4700::1111]:53"),
        ]
    }

    fn dns(address: &str) -> DnsServer {
        DnsServer::IpPort(IpDnsServer {
            address: address.parse().unwrap(),
        })
    }

    fn ip(addr: &str) -> IpAddr {
        addr.parse().unwrap()
    }
}

#[cfg(all(test, feature = "proptest"))]
mod proptests {
    use super::*;
    use crate::proptest::*;
    use connlib_shared::messages::client::ResourceDescriptionDns;
    use prop::collection;
    use proptest::prelude::*;

    #[test_strategy::proptest]
    fn cidr_resources_are_turned_into_routes(
        #[strategy(cidr_resource())] resource1: ResourceDescriptionCidr,
        #[strategy(cidr_resource())] resource2: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();

        client_state.add_resource(ResourceDescription::Cidr(resource1.clone()));
        client_state.add_resource(ResourceDescription::Cidr(resource2.clone()));

        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![resource1.address, resource2.address])
        );
    }

    #[test_strategy::proptest]
    fn added_resources_show_up_as_resoucres(
        #[strategy(cidr_resource())] resource1: ResourceDescriptionCidr,
        #[strategy(dns_resource())] resource2: ResourceDescriptionDns,
        #[strategy(cidr_resource())] resource3: ResourceDescriptionCidr,
    ) {
        use callbacks as cb;

        let mut client_state = ClientState::for_test();

        client_state.add_resource(ResourceDescription::Cidr(resource1.clone()));
        client_state.add_resource(ResourceDescription::Dns(resource2.clone()));

        assert_eq!(
            hashset(client_state.resources()),
            hashset([
                cb::ResourceDescription::Cidr(resource1.clone().with_status(Status::Unknown)),
                cb::ResourceDescription::Dns(resource2.clone().with_status(Status::Unknown))
            ])
        );

        client_state.add_resource(ResourceDescription::Cidr(resource3.clone()));

        assert_eq!(
            hashset(client_state.resources()),
            hashset([
                cb::ResourceDescription::Cidr(resource1.with_status(Status::Unknown)),
                cb::ResourceDescription::Dns(resource2.with_status(Status::Unknown)),
                cb::ResourceDescription::Cidr(resource3.with_status(Status::Unknown)),
            ])
        );
    }

    #[test_strategy::proptest]
    fn adding_same_resource_with_different_address_updates_the_address(
        #[strategy(cidr_resource())] resource: ResourceDescriptionCidr,
        #[strategy(any_ip_network(8))] new_address: IpNetwork,
    ) {
        use callbacks as cb;

        let mut client_state = ClientState::for_test();
        client_state.add_resource(ResourceDescription::Cidr(resource.clone()));

        let updated_resource = ResourceDescriptionCidr {
            address: new_address,
            ..resource
        };

        client_state.add_resource(ResourceDescription::Cidr(updated_resource.clone()));

        assert_eq!(
            hashset(client_state.resources()),
            hashset([cb::ResourceDescription::Cidr(
                updated_resource.with_status(Status::Unknown)
            )])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![new_address])
        );
    }

    #[test_strategy::proptest]
    fn adding_cidr_resource_with_same_id_as_dns_resource_replaces_dns_resource(
        #[strategy(dns_resource())] resource: ResourceDescriptionDns,
        #[strategy(any_ip_network(8))] address: IpNetwork,
    ) {
        use callbacks as cb;

        let mut client_state = ClientState::for_test();
        client_state.add_resource(ResourceDescription::Dns(resource.clone()));

        let dns_as_cidr_resource = ResourceDescriptionCidr {
            address,
            id: resource.id,
            name: resource.name,
            address_description: resource.address_description,
            sites: resource.sites,
        };

        client_state.add_resource(ResourceDescription::Cidr(dns_as_cidr_resource.clone()));

        assert_eq!(
            hashset(client_state.resources()),
            hashset([cb::ResourceDescription::Cidr(
                dns_as_cidr_resource.with_status(Status::Unknown)
            )])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![address])
        );
    }

    #[test_strategy::proptest]
    fn resources_can_be_removed(
        #[strategy(dns_resource())] dns_resource: ResourceDescriptionDns,
        #[strategy(cidr_resource())] cidr_resource: ResourceDescriptionCidr,
    ) {
        use callbacks as cb;

        let mut client_state = ClientState::for_test();
        client_state.add_resource(ResourceDescription::Dns(dns_resource.clone()));
        client_state.add_resource(ResourceDescription::Cidr(cidr_resource.clone()));

        client_state.remove_resource(dns_resource.id);

        assert_eq!(
            hashset(client_state.resources()),
            hashset([cb::ResourceDescription::Cidr(
                cidr_resource.clone().with_status(Status::Unknown)
            )])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![cidr_resource.address])
        );

        client_state.remove_resource(cidr_resource.id);

        assert_eq!(hashset(client_state.resources().iter()), hashset(&[]));
        assert_eq!(hashset(client_state.routes()), expected_routes(vec![]));
    }

    #[test_strategy::proptest]
    fn resources_can_be_replaced(
        #[strategy(dns_resource())] dns_resource1: ResourceDescriptionDns,
        #[strategy(dns_resource())] dns_resource2: ResourceDescriptionDns,
        #[strategy(cidr_resource())] cidr_resource1: ResourceDescriptionCidr,
        #[strategy(cidr_resource())] cidr_resource2: ResourceDescriptionCidr,
    ) {
        use callbacks as cb;

        let mut client_state = ClientState::for_test();
        client_state.add_resource(ResourceDescription::Dns(dns_resource1));
        client_state.add_resource(ResourceDescription::Cidr(cidr_resource1));

        client_state.set_resources(vec![
            ResourceDescription::Dns(dns_resource2.clone()),
            ResourceDescription::Cidr(cidr_resource2.clone()),
        ]);

        assert_eq!(
            hashset(client_state.resources()),
            hashset([
                cb::ResourceDescription::Dns(dns_resource2.with_status(Status::Unknown)),
                cb::ResourceDescription::Cidr(cidr_resource2.clone().with_status(Status::Unknown)),
            ])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![cidr_resource2.address])
        );
    }

    #[test_strategy::proptest]
    fn setting_gateway_online_sets_all_related_resources_online(
        #[strategy(resources_sharing_n_sites(1))] resources_online: Vec<ResourceDescription>,
        #[strategy(resources_sharing_n_sites(1))] resources_unknown: Vec<ResourceDescription>,
        #[strategy(gateway_id())] gateway: GatewayId,
    ) {
        let mut client_state = ClientState::for_test();

        for r in resources_online.iter().chain(resources_unknown.iter()) {
            client_state.add_resource(r.clone())
        }

        let first_resource = resources_online.first().unwrap();
        client_state
            .resources_gateways
            .insert(first_resource.id(), gateway);
        client_state
            .gateways_site
            .insert(gateway, first_resource.sites().iter().next().unwrap().id);

        client_state.update_site_status_by_gateway(&gateway, Status::Online);

        for resource in resources_online {
            assert_eq!(client_state.resource_status(&resource), Status::Online);
        }

        for resource in resources_unknown {
            assert_eq!(client_state.resource_status(&resource), Status::Unknown);
        }
    }

    #[test_strategy::proptest]
    fn disconnecting_gateway_sets_related_resources_unknown(
        #[strategy(resources_sharing_n_sites(1))] resources: Vec<ResourceDescription>,
        #[strategy(gateway_id())] gateway: GatewayId,
    ) {
        let mut client_state = ClientState::for_test();
        for r in &resources {
            client_state.add_resource(r.clone())
        }
        let first_resources = resources.first().unwrap();
        client_state
            .resources_gateways
            .insert(first_resources.id(), gateway);
        client_state
            .gateways_site
            .insert(gateway, first_resources.sites().iter().next().unwrap().id);

        client_state.update_site_status_by_gateway(&gateway, Status::Online);
        client_state.update_site_status_by_gateway(&gateway, Status::Unknown);

        for resource in resources {
            assert_eq!(client_state.resource_status(&resource), Status::Unknown);
        }
    }

    #[test_strategy::proptest]
    fn setting_resource_offline_doesnt_set_all_related_resources_offline(
        #[strategy(resources_sharing_n_sites(2))] multi_site_resources: Vec<ResourceDescription>,
        #[strategy(resource())] single_site_resource: ResourceDescription,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resource(single_site_resource.clone());
        for r in &multi_site_resources {
            client_state.add_resource(r.clone())
        }

        client_state.set_resource_offline(single_site_resource.id());

        assert_eq!(
            client_state.resource_status(&single_site_resource),
            Status::Offline
        );
        for resource in multi_site_resources {
            assert_eq!(client_state.resource_status(&resource), Status::Unknown);
        }
    }

    pub fn expected_routes(resource_routes: Vec<IpNetwork>) -> HashSet<IpNetwork> {
        HashSet::from_iter(
            resource_routes
                .into_iter()
                .chain(iter::once(IPV4_RESOURCES.into()))
                .chain(iter::once(IPV6_RESOURCES.into())),
        )
    }

    #[allow(clippy::redundant_clone)] // False positive.
    pub fn hashset<T: std::hash::Hash + Eq, B: ToOwned<Owned = T>>(
        val: impl IntoIterator<Item = B>,
    ) -> HashSet<T> {
        HashSet::from_iter(val.into_iter().map(|b| b.to_owned()))
    }

    fn resource() -> impl Strategy<Value = ResourceDescription> {
        crate::proptest::resource(site().prop_map(|s| vec![s]))
    }

    fn cidr_resource() -> impl Strategy<Value = ResourceDescriptionCidr> {
        crate::proptest::cidr_resource(any_ip_network(8), site().prop_map(|s| vec![s]))
    }

    fn dns_resource() -> impl Strategy<Value = ResourceDescriptionDns> {
        crate::proptest::dns_resource(site().prop_map(|s| vec![s]))
    }

    // Generate resources sharing 1 site
    fn resources_sharing_n_sites(
        num_sites: usize,
    ) -> impl Strategy<Value = Vec<ResourceDescription>> {
        collection::vec(site(), num_sites)
            .prop_flat_map(|sites| collection::vec(crate::proptest::resource(Just(sites)), 1..=100))
    }
}
