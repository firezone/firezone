use crate::peer_store::PeerStore;
use crate::{dns, dns::DnsQuery};
use bimap::BiMap;
use connlib_shared::callbacks::Status;
use connlib_shared::error::{ConnlibError as Error, ConnlibError};
use connlib_shared::messages::client::{Site, SiteId};
use connlib_shared::messages::{
    client::ResourceDescription, client::ResourceDescriptionCidr, client::ResourceDescriptionDns,
    Answer, ClientPayload, DnsServer, DomainResponse, GatewayId, Interface as InterfaceConfig,
    IpDnsServer, Key, Offer, Relay, RelayId, RequestConnection, ResourceId, ReuseConnection,
};
use connlib_shared::{callbacks, Callbacks, DomainName, PublicKey, StaticSecret};
use domain::base::Rtype;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, MutableIpPacket};
use itertools::Itertools;

use crate::io::DnsQueryError;
use crate::peer::GatewayOnClient;
use crate::utils::{earliest, stun, turn};
use crate::{ClientEvent, ClientTunnel};
use core::fmt;
use secrecy::{ExposeSecret as _, Secret};
use snownet::{ClientNode, RelaySocket};
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};
use std::iter;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::str::FromStr;
use std::time::{Duration, Instant};
use tracing::Level;

// Using str here because Ipv4/6Network doesn't support `const` 🙃
const IPV4_RESOURCES: &str = "100.96.0.0/11";
const IPV6_RESOURCES: &str = "fd00:2021:1111:8000::/107";

const DNS_PORT: u16 = 53;
const DNS_SENTINELS_V4: &str = "100.100.111.0/24";
const DNS_SENTINELS_V6: &str = "fd00:2021:1111:8000:100:100:111:0/120";

// With this single timer this might mean that some DNS are refreshed too often
// however... this also mean any resource is refresh within a 5 mins interval
// therefore, only the first time it's added that happens, after that it doesn't matter.
const DNS_REFRESH_INTERVAL: Duration = Duration::from_secs(300);

#[derive(Debug, Clone, Hash, PartialEq, Eq)]
pub struct DnsResource {
    pub id: ResourceId,
    pub address: DomainName,
}

impl DnsResource {
    pub fn from_description(
        description: &ResourceDescriptionDns,
        address: DomainName,
    ) -> DnsResource {
        DnsResource {
            id: description.id,
            address,
        }
    }
}

impl<CB> ClientTunnel<CB>
where
    CB: Callbacks + 'static,
{
    pub fn set_resources(
        &mut self,
        resources: Vec<ResourceDescription>,
    ) -> connlib_shared::Result<()> {
        self.role_state.set_resources(resources);

        self.io
            .device_mut()
            .set_routes(self.role_state.routes().collect(), &self.callbacks)?;
        self.callbacks
            .on_update_resources(self.role_state.resources());

        Ok(())
    }

    pub fn update_relays(&mut self, to_remove: HashSet<RelayId>, to_add: Vec<Relay>) {
        self.role_state
            .update_relays(to_remove, turn(&to_add), Instant::now())
    }

    /// Adds a the given resource to the tunnel.
    pub fn add_resources(
        &mut self,
        resources: &[ResourceDescription],
    ) -> connlib_shared::Result<()> {
        self.role_state.add_resources(resources);

        self.io
            .device_mut()
            .set_routes(self.role_state.routes().collect(), &self.callbacks)?;
        self.callbacks
            .on_update_resources(self.role_state.resources());

        Ok(())
    }

    pub fn remove_resources(&mut self, ids: &[ResourceId]) {
        self.role_state.remove_resources(ids);

        if let Err(err) = self
            .io
            .device_mut()
            .set_routes(self.role_state.routes().collect(), &self.callbacks)
        {
            tracing::error!(?ids, "Failed to update routes: {err:?}");
        }

        self.callbacks
            .on_update_resources(self.role_state.resources())
    }

    /// Updates the system's dns
    pub fn set_new_dns(&mut self, new_dns: Vec<IpAddr>) -> connlib_shared::Result<()> {
        // We store the sentinel dns both in the config and in the system's resolvers
        // but when we calculate the dns mapping, those are ignored.
        let dns_changed = self.role_state.update_system_resolvers(new_dns);

        if !dns_changed {
            return Ok(());
        }

        self.io
            .set_upstream_dns_servers(self.role_state.dns_mapping());

        if let Some(config) = self.role_state.interface_config.as_ref().cloned() {
            self.update_device(config, self.role_state.dns_mapping())?;
        };

        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_new_interface_config(
        &mut self,
        config: InterfaceConfig,
    ) -> connlib_shared::Result<()> {
        let dns_changed = self.role_state.update_interface_config(config.clone());

        if dns_changed {
            self.io
                .set_upstream_dns_servers(self.role_state.dns_mapping());
        }

        self.update_device(config, self.role_state.dns_mapping())?;

        Ok(())
    }

    pub(crate) fn update_device(
        &mut self,
        config: InterfaceConfig,
        dns_mapping: BiMap<IpAddr, DnsServer>,
    ) -> connlib_shared::Result<()> {
        let callbacks = self.callbacks.clone();

        self.io.device_mut().set_config(
            &config,
            // We can just sort in here because sentinel ips are created in order
            dns_mapping.left_values().copied().sorted().collect(),
            &callbacks,
        )?;

        self.io
            .device_mut()
            .set_routes(self.role_state.routes().collect(), &self.callbacks)?;
        let name = self.io.device_mut().name().to_owned();

        tracing::debug!(ip4 = %config.ipv4, ip6 = %config.ipv6, %name, "TUN device initialized");

        Ok(())
    }

    pub fn cleanup_connection(&mut self, id: ResourceId) {
        self.role_state.on_connection_failed(id);
    }

    pub fn set_resource_offline(&mut self, id: ResourceId) {
        self.role_state.set_resource_offline(id);

        self.role_state.on_connection_failed(id);

        self.callbacks
            .on_update_resources(self.role_state.resources());
    }

    pub fn add_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.role_state
            .add_ice_candidate(conn_id, ice_candidate, Instant::now());
    }

    pub fn remove_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.role_state.remove_ice_candidate(conn_id, ice_candidate);
    }

    pub fn create_or_reuse_connection(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        relays: Vec<Relay>,
        site_id: SiteId,
    ) -> connlib_shared::Result<Request> {
        self.role_state.create_or_reuse_connection(
            resource_id,
            gateway_id,
            site_id,
            stun(&relays, |addr| self.io.sockets_ref().can_handle(addr)),
            turn(&relays),
        )
    }

    pub fn received_offer_response(
        &mut self,
        resource_id: ResourceId,
        answer: Answer,
        domain_response: Option<DomainResponse>,
        gateway_public_key: PublicKey,
    ) -> connlib_shared::Result<()> {
        self.role_state.accept_answer(
            snownet::Answer {
                credentials: snownet::Credentials {
                    username: answer.username,
                    password: answer.password,
                },
            },
            resource_id,
            gateway_public_key,
            domain_response,
            Instant::now(),
        )?;

        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self, resource_id))]
    pub fn received_domain_parameters(
        &mut self,
        resource_id: ResourceId,
        domain_response: DomainResponse,
    ) -> connlib_shared::Result<()> {
        self.role_state
            .received_domain_parameters(resource_id, domain_response)?;

        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

impl Request {
    pub fn resource_id(&self) -> ResourceId {
        match self {
            Request::NewConnection(i) => i.resource_id,
            Request::ReuseConnection(i) => i.resource_id,
        }
    }

    /// The domain that we need to resolve as part of the connection request.
    pub fn domain_name(&self) -> Option<DomainName> {
        match self {
            Request::NewConnection(i) => i.client_payload.domain.clone(),
            Request::ReuseConnection(i) => i.payload.clone(),
        }
    }
}

fn send_dns_answer(
    role_state: &mut ClientState,
    qtype: Rtype,
    resource_description: &DnsResource,
    addrs: &HashSet<IpAddr>,
) {
    let packet = role_state
        .deferred_dns_queries
        .remove(&(resource_description.clone(), qtype));
    if let Some(packet) = packet {
        let Some(packet) = dns::create_local_answer(addrs, packet) else {
            return;
        };

        tracing::debug!(domain = %resource_description.address, ips = ?addrs, "Resolved DNS query");

        role_state.buffered_packets.push_back(packet);
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
    awaiting_connection: HashMap<ResourceId, AwaitingConnectionDetails>,

    /// Tracks which gateway to use for a particular Resource.
    resources_gateways: HashMap<ResourceId, GatewayId>,
    /// The site a gateway belongs to.
    gateways_site: HashMap<GatewayId, SiteId>,
    /// The online/offline status of a site.
    sites_status: HashMap<SiteId, Status>,

    /// All DNS resources we know about, indexed by their domain (could be wildcard domain like `*.mycompany.com`).
    dns_resources: HashMap<String, ResourceDescriptionDns>,
    /// All CIDR resources we know about, indexed by the IP range they cover (like `1.1.0.0/8`).
    cidr_resources: IpNetworkTable<ResourceDescriptionCidr>,
    /// All resources indexed by their ID.
    resource_ids: HashMap<ResourceId, ResourceDescription>,

    /// The DNS resolvers configured on the system outside of connlib.
    system_resolvers: Vec<IpAddr>,

    /// DNS queries that we need to forward to the system resolver.
    buffered_dns_queries: VecDeque<DnsQuery<'static>>,

    /// The (internal) IPs we have assigned for a certain DNS resource.
    dns_resources_internal_ips: HashMap<IpAddr, DnsResource>,
    /// DNS queries we can only answer once we have connected to the resource.
    ///
    /// See [`dns::ResolveStrategy`] for details.
    deferred_dns_queries: HashMap<(DnsResource, Rtype), IpPacket<'static>>,
    /// Hands out IPs for DNS resources.
    ip_provider: IpProvider,
    /// Maps from connlib-assigned IP of a DNS server back to the originally configured system DNS resolver.
    dns_mapping: BiMap<IpAddr, DnsServer>,
    /// When to next refresh DNS resources.
    ///
    /// "Refreshing" DNS resources means triggering a new DNS lookup for this domain on the gateway.
    next_dns_refresh: Option<Instant>,

    /// Configuration of the TUN device, when it is up.
    interface_config: Option<InterfaceConfig>,

    buffered_events: VecDeque<ClientEvent>,
    buffered_packets: VecDeque<IpPacket<'static>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AwaitingConnectionDetails {
    pub domain: Option<DomainName>,
    gateways: HashSet<GatewayId>,
    pub last_intent_sent_at: Instant,
}

impl ClientState {
    pub(crate) fn new(private_key: StaticSecret) -> Self {
        Self {
            awaiting_connection: Default::default(),
            resources_gateways: Default::default(),
            ip_provider: IpProvider::for_resources(),
            dns_resources_internal_ips: Default::default(),
            dns_resources: Default::default(),
            cidr_resources: IpNetworkTable::new(),
            resource_ids: Default::default(),
            peers: Default::default(),
            deferred_dns_queries: Default::default(),
            dns_mapping: Default::default(),
            buffered_events: Default::default(),
            interface_config: Default::default(),
            buffered_packets: Default::default(),
            buffered_dns_queries: Default::default(),
            next_dns_refresh: Default::default(),
            node: ClientNode::new(private_key),
            system_resolvers: Default::default(),
            sites_status: Default::default(),
            gateways_site: Default::default(),
        }
    }

    pub(crate) fn resources(&self) -> Vec<callbacks::ResourceDescription> {
        self.resource_ids
            .values()
            .sorted()
            .cloned()
            .map(|r| {
                let status = self.resource_status(&r);
                r.with_status(status)
            })
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
        let Some(resource) = self.resource_ids.get(&id).cloned() else {
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

    #[tracing::instrument(level = "trace", skip_all, fields(dst))]
    pub(crate) fn encapsulate<'s>(
        &'s mut self,
        packet: MutableIpPacket<'_>,
        now: Instant,
    ) -> Option<snownet::Transmit<'s>> {
        let (packet, dest) = match self.handle_dns(packet, now) {
            Ok(response) => {
                self.buffered_packets.push_back(response?.to_owned());
                return None;
            }
            Err(non_dns_packet) => non_dns_packet,
        };

        tracing::Span::current().record("dst", tracing::field::display(dest));

        if is_definitely_not_a_resource(dest) {
            return None;
        }

        let Some(resource) = self.get_resource_by_destination(dest) else {
            tracing::trace!("Unknown resource");
            return None;
        };

        let Some(peer) = self.peer_by_resource_mut(resource) else {
            // If the resource are intending to is a DNS resource (i.e. we resolved an IP for it), look up the original name.
            let domain = self
                .dns_resources_internal_ips
                .values()
                .find_map(|r| (r.id == resource).then_some(r.address.clone()));

            self.on_connection_intent_to_resource(resource, domain, now);
            return None;
        };

        let packet = peer.transform_tun_to_network(packet);
        let gateway_id = peer.id();

        let transmit = self
            .node
            .encapsulate(gateway_id, packet.as_immutable(), now)
            .inspect_err(|e| tracing::debug!("Failed to encapsulate: {e}"))
            .ok()??;

        tracing::trace!("Encapsulated packet");

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
        let (conn_id, packet) = self.node.decapsulate(
            local,
            from,
            packet.as_ref(),
            now,
            buffer,
        )
        .inspect_err(|e| tracing::warn!(%local, %from, num_bytes = %packet.len(), "Failed to decapsulate incoming packet: {e}"))
        .ok()??;

        let Some(peer) = self.peers.get_mut(&conn_id) else {
            tracing::error!(%conn_id, %local, %from, "Couldn't find connection");

            return None;
        };

        let packet = match peer.transform_network_to_tun(packet) {
            Ok(packet) => packet,
            Err(e) => {
                tracing::warn!(%conn_id, %local, %from, "Failed to transform packet: {e}");

                return None;
            }
        };

        Some(packet.into_immutable())
    }

    pub fn add_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String, now: Instant) {
        self.node.add_remote_candidate(conn_id, ice_candidate, now);
    }

    pub fn remove_ice_candidate(&mut self, conn_id: GatewayId, ice_candidate: String) {
        self.node.remove_remote_candidate(conn_id, ice_candidate);
    }

    #[tracing::instrument(level = "trace", skip_all, fields(%resource_id))]
    pub fn accept_answer(
        &mut self,
        answer: snownet::Answer,
        resource_id: ResourceId,
        gateway: PublicKey,
        domain_response: Option<DomainResponse>,
        now: Instant,
    ) -> connlib_shared::Result<()> {
        let gateway_id = self
            .gateway_by_resource(&resource_id)
            .ok_or(Error::UnknownResource)?;

        self.node.accept_answer(gateway_id, gateway, answer, now);

        let desc = self
            .resource_ids
            .get(&resource_id)
            .ok_or(Error::ControlProtocolError)?;

        let ips = self.get_resource_ip(desc, &domain_response.as_ref().map(|d| d.domain.clone()));

        // Tidy up state once everything succeeded.
        self.awaiting_connection.remove(&resource_id);

        let resource_ids = HashSet::from([resource_id]);
        let mut peer = GatewayOnClient::new(gateway_id, &ips, resource_ids);
        peer.set_dns(self.dns_mapping());
        self.peers.insert(peer, &[]);

        let peer_ips = if let Some(domain_response) = domain_response {
            self.dns_response(&resource_id, &domain_response, &gateway_id)?
        } else {
            ips
        };

        self.peers
            .add_ips_with_resource(&gateway_id, &peer_ips, &resource_id);

        Ok(())
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%resource_id, %gateway_id))]
    pub fn create_or_reuse_connection(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        site_id: SiteId,
        allowed_stun_servers: HashSet<SocketAddr>,
        allowed_turn_servers: HashSet<(RelayId, RelaySocket, String, String, String)>,
    ) -> connlib_shared::Result<Request> {
        tracing::trace!("create_or_reuse_connection");

        self.gateways_site.insert(gateway_id, site_id);

        let desc = self
            .resource_ids
            .get(&resource_id)
            .ok_or(Error::UnknownResource)?;

        let awaiting_connection = self.get_awaiting_connection(&resource_id)?.clone();
        let domain = awaiting_connection.domain.clone();

        self.resources_gateways.insert(resource_id, gateway_id);

        if self.peers.get(&gateway_id).is_some() {
            self.peers.add_ips_with_resource(
                &gateway_id,
                &self.get_resource_ip(desc, &domain),
                &resource_id,
            );

            self.awaiting_connection.remove(&resource_id);

            return Ok(Request::ReuseConnection(ReuseConnection {
                resource_id,
                gateway_id,
                payload: domain,
            }));
        };

        if self.node.is_expecting_answer(gateway_id) {
            return Err(Error::PendingConnection);
        }

        let offer = self.node.new_connection(
            gateway_id,
            allowed_stun_servers,
            allowed_turn_servers,
            awaiting_connection.last_intent_sent_at,
            Instant::now(),
        );

        return Ok(Request::NewConnection(RequestConnection {
            resource_id,
            gateway_id,
            client_preshared_key: Secret::new(Key(*offer.session_key.expose_secret())),
            client_payload: ClientPayload {
                ice_parameters: Offer {
                    username: offer.credentials.username,
                    password: offer.credentials.password,
                },
                domain,
            },
        }));
    }

    pub fn received_domain_parameters(
        &mut self,
        resource_id: ResourceId,
        domain_response: DomainResponse,
    ) -> connlib_shared::Result<()> {
        let gateway_id = self
            .gateway_by_resource(&resource_id)
            .ok_or(Error::UnknownResource)?;

        let peer_ips = self.dns_response(&resource_id, &domain_response, &gateway_id)?;

        self.peers
            .add_ips_with_resource(&gateway_id, &peer_ips, &resource_id);

        Ok(())
    }

    #[tracing::instrument(level = "debug", skip_all, fields(name = %query.name, server = %query.query.destination()))] // On debug level, we can log potentially sensitive information such as domain names.
    pub(crate) fn on_dns_result(
        &mut self,
        query: DnsQuery<'static>,
        response: Result<
            Result<
                Result<hickory_resolver::lookup::Lookup, hickory_resolver::error::ResolveError>,
                futures_bounded::Timeout,
            >,
            DnsQueryError,
        >,
    ) {
        let query = query.query;
        let make_error_reply = {
            let query = query.clone();

            |e: &dyn fmt::Display| {
                // To avoid sensitive data getting into the logs, only log the error if debug logging is enabled.
                // We always want to see a warning.
                if tracing::enabled!(Level::DEBUG) {
                    tracing::warn!("DNS query failed: {e}");
                } else {
                    tracing::warn!("DNS query failed");
                };

                ip_packet::make::dns_err_response(query, hickory_proto::op::ResponseCode::ServFail)
                    .into_immutable()
            }
        };

        let dns_reply = match response {
            Ok(Ok(response)) => match dns::build_response_from_resolve_result(query, response) {
                Ok(dns_reply) => dns_reply,
                Err(e) => make_error_reply(&e),
            },
            Ok(Err(timeout)) => make_error_reply(&timeout),
            Err(e) => make_error_reply(&e),
        };

        self.buffered_packets.push_back(dns_reply);
    }

    fn dns_response(
        &mut self,
        resource_id: &ResourceId,
        domain_response: &DomainResponse,
        peer_id: &GatewayId,
    ) -> connlib_shared::Result<Vec<IpNetwork>> {
        let peer = self
            .peers
            .get_mut(peer_id)
            .ok_or(Error::ControlProtocolError)?;

        let resource_description = self
            .resource_ids
            .get(resource_id)
            .ok_or(Error::UnknownResource)?
            .clone();

        let ResourceDescription::Dns(resource_description) = resource_description else {
            // We should never get a domain_response for a CIDR resource!
            return Err(Error::ControlProtocolError);
        };

        let resource_description =
            DnsResource::from_description(&resource_description, domain_response.domain.clone());

        let addrs: HashSet<_> = domain_response
            .address
            .iter()
            .filter_map(|external_ip| {
                peer.get_or_assign_translation(external_ip, &mut self.ip_provider)
            })
            .collect();

        for addr in addrs.clone() {
            self.dns_resources_internal_ips
                .insert(addr, resource_description.clone());
        }

        send_dns_answer(self, Rtype::AAAA, &resource_description, &addrs);
        send_dns_answer(self, Rtype::A, &resource_description, &addrs);

        Ok(addrs.iter().copied().map(Into::into).collect())
    }

    /// Attempt to handle the given packet as a DNS packet.
    ///
    /// Returns `Ok` if the packet is in fact a DNS query with an optional response to send back.
    /// Returns `Err` if the packet is not a DNS query.
    fn handle_dns<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
        now: Instant,
    ) -> Result<Option<IpPacket<'a>>, (MutableIpPacket<'a>, IpAddr)> {
        match dns::parse(
            &self.dns_resources,
            &self.dns_resources_internal_ips,
            &self.dns_mapping,
            packet.as_immutable(),
        ) {
            Some(dns::ResolveStrategy::LocalResponse(query)) => Ok(Some(query)),
            Some(dns::ResolveStrategy::ForwardQuery(query)) => {
                // There's an edge case here, where the resolver's ip has been resolved before as
                // a dns resource... we will ignore that weird case for now.
                // Assuming a single upstream dns until #3123 lands
                if let Some(upstream_dns) = self.dns_mapping.get_by_left(&query.query.destination())
                {
                    let ip = upstream_dns.ip();

                    if self.cidr_resources.longest_match(ip).is_some() {
                        tracing::debug!(%ip, "DNS server is a CIDR resource");

                        return Err((packet, ip));
                    }
                }

                self.buffered_dns_queries.push_back(query.into_owned());

                Ok(None)
            }
            Some(dns::ResolveStrategy::DeferredResponse((resource, r_type))) => {
                self.on_connection_intent_to_resource(
                    resource.id,
                    Some(resource.address.clone()),
                    now,
                );
                self.deferred_dns_queries
                    .insert((resource, r_type), packet.as_immutable().to_owned());

                Ok(None)
            }
            None => {
                let dest = packet.destination();
                Err((packet, dest))
            }
        }
    }

    pub(crate) fn get_awaiting_connection(
        &self,
        resource: &ResourceId,
    ) -> Result<&AwaitingConnectionDetails, ConnlibError> {
        self.awaiting_connection
            .get(resource)
            .ok_or(Error::UnexpectedConnectionDetails)
    }

    pub fn on_connection_failed(&mut self, resource: ResourceId) {
        self.awaiting_connection.remove(&resource);
        self.resources_gateways.remove(&resource);
    }

    #[tracing::instrument(level = "debug", skip_all, fields(%resource, ?domain))]
    fn on_connection_intent_to_resource(
        &mut self,
        resource: ResourceId,
        domain: Option<DomainName>,
        now: Instant,
    ) {
        debug_assert!(self.resource_ids.contains_key(&resource));

        let gateways = self
            .resources_gateways
            .values()
            .copied()
            .collect::<HashSet<_>>();

        match self.awaiting_connection.entry(resource) {
            Entry::Occupied(mut occupied) => {
                let time_since_last_intent = now.duration_since(occupied.get().last_intent_sent_at);

                if time_since_last_intent < Duration::from_secs(2) {
                    tracing::trace!(?time_since_last_intent, "Skipping connection intent");

                    return;
                }

                occupied.get_mut().last_intent_sent_at = now;
            }
            Entry::Vacant(vacant) => {
                vacant.insert(AwaitingConnectionDetails {
                    domain,
                    gateways: gateways.clone(),
                    last_intent_sent_at: now,
                });
            }
        }

        tracing::debug!("Sending connection intent");

        self.buffered_events
            .push_back(ClientEvent::ConnectionIntent {
                resource,
                connected_gateway_ids: gateways,
            });
    }

    pub fn gateway_by_resource(&self, resource: &ResourceId) -> Option<GatewayId> {
        self.resources_gateways.get(resource).copied()
    }

    fn set_dns_mapping(&mut self, new_mapping: BiMap<IpAddr, DnsServer>) {
        self.dns_mapping = new_mapping.clone();
        self.peers
            .iter_mut()
            .for_each(|p| p.set_dns(new_mapping.clone()));
    }

    pub fn dns_mapping(&self) -> BiMap<IpAddr, DnsServer> {
        self.dns_mapping.clone()
    }

    fn get_resource_ip(
        &self,
        resource: &ResourceDescription,
        domain: &Option<DomainName>,
    ) -> Vec<IpNetwork> {
        match resource {
            ResourceDescription::Dns(dns_resource) => {
                let Some(domain) = domain else {
                    return vec![];
                };

                let description = DnsResource::from_description(dns_resource, domain.clone());
                dns::ips_of_resource(&self.dns_resources_internal_ips, &description)
                    .map(Into::into)
                    .collect()
            }
            ResourceDescription::Cidr(cidr) => vec![cidr.address],
        }
    }

    pub fn cleanup_connected_gateway(&mut self, gateway_id: &GatewayId) {
        self.update_site_status_by_gateway(gateway_id, Status::Unknown);
        self.peers.remove(gateway_id);
        self.dns_resources_internal_ips.retain(|_, resource| {
            !self
                .resources_gateways
                .get(&resource.id)
                .is_some_and(|r_gateway_id| r_gateway_id == gateway_id)
        });
    }

    fn routes(&self) -> impl Iterator<Item = IpNetwork> + '_ {
        self.cidr_resources
            .iter()
            .map(|(ip, _)| ip)
            .chain(iter::once(IpNetwork::from_str(IPV4_RESOURCES).unwrap()))
            .chain(iter::once(IpNetwork::from_str(IPV6_RESOURCES).unwrap()))
            .chain(self.dns_mapping.left_values().copied().map(Into::into))
    }

    fn get_resource_by_destination(&self, destination: IpAddr) -> Option<ResourceId> {
        let maybe_cidr_resource_id = self
            .cidr_resources
            .longest_match(destination)
            .map(|(_, r)| r.id);

        let maybe_dns_resource_id = self
            .dns_resources_internal_ips
            .get(&destination)
            .map(|r| r.id);

        maybe_cidr_resource_id.or(maybe_dns_resource_id)
    }

    #[must_use]
    pub(crate) fn update_system_resolvers(&mut self, new_dns: Vec<IpAddr>) -> bool {
        self.system_resolvers = new_dns;

        self.update_dns_mapping()
    }

    #[must_use]
    pub(crate) fn update_interface_config(&mut self, config: InterfaceConfig) -> bool {
        self.interface_config = Some(config);

        self.update_dns_mapping()
    }

    pub fn poll_packets(&mut self) -> Option<IpPacket<'static>> {
        self.buffered_packets.pop_front()
    }

    pub fn poll_dns_queries(&mut self) -> Option<DnsQuery<'static>> {
        self.buffered_dns_queries.pop_front()
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        earliest(self.next_dns_refresh, self.node.poll_timeout())
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.node.handle_timeout(now);

        match self.next_dns_refresh {
            Some(next_dns_refresh) if now >= next_dns_refresh => {
                let mut connections = Vec::new();

                self.peers.iter_mut().for_each(|p| p.expire_dns_track());

                for resource in self.dns_resources_internal_ips.values() {
                    let Some(peer) = self.peer_by_resource(resource.id) else {
                        // filter inactive connections
                        continue;
                    };

                    connections.push(ReuseConnection {
                        resource_id: resource.id,
                        gateway_id: peer.id(),
                        payload: Some(resource.address.clone()),
                    });
                }

                self.buffered_events
                    .push_back(ClientEvent::RefreshResources { connections });

                self.next_dns_refresh = Some(now + DNS_REFRESH_INTERVAL);
            }
            None => self.next_dns_refresh = Some(now + DNS_REFRESH_INTERVAL),
            Some(_) => {}
        }

        while let Some(event) = self.node.poll_event() {
            match event {
                snownet::Event::ConnectionFailed(id) => {
                    self.cleanup_connected_gateway(&id);
                    self.buffered_events
                        .push_back(ClientEvent::ResourcesChanged {
                            resources: self.resources(),
                        });
                }
                snownet::Event::NewIceCandidate {
                    connection,
                    candidate,
                } => self
                    .buffered_events
                    .push_back(ClientEvent::NewIceCandidate {
                        conn_id: connection,
                        candidate,
                    }),
                snownet::Event::InvalidateIceCandidate {
                    connection,
                    candidate,
                } => self
                    .buffered_events
                    .push_back(ClientEvent::InvalidatedIceCandidate {
                        conn_id: connection,
                        candidate,
                    }),
                snownet::Event::ConnectionEstablished(id) => {
                    self.update_site_status_by_gateway(&id, Status::Online);
                    self.buffered_events
                        .push_back(ClientEvent::ResourcesChanged {
                            resources: self.resources(),
                        });
                }
            }
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

    pub(crate) fn reconnect(&mut self, now: Instant) {
        tracing::info!("Network change detected, refreshing connections");
        self.node.reconnect(now)
    }

    pub(crate) fn poll_transmit(&mut self) -> Option<snownet::Transmit<'static>> {
        self.node.poll_transmit()
    }

    /// Sets a new set of resources.
    ///
    /// This function does **not** perform a blanket "clear all and set new resources".
    /// Instead, it diffs which resources to remove and which ones to add.
    ///
    /// This is important because we don't want to lose state like resolved DNS names for resources that didn't change.
    ///
    /// TODO: Add a test that asserts the above.
    ///       That is tricky because we need to assert on state deleted by [`ClientState::remove_resources`] and check that it did in fact not get deleted.
    fn set_resources(&mut self, new_resources: Vec<ResourceDescription>) {
        self.remove_resources(
            &HashSet::from_iter(self.resource_ids.keys().copied())
                .difference(&HashSet::<ResourceId>::from_iter(
                    new_resources.iter().map(|r| r.id()),
                ))
                .copied()
                .collect_vec(),
        );

        self.add_resources(
            &HashSet::from_iter(new_resources.iter().cloned())
                .difference(&HashSet::<ResourceDescription>::from_iter(
                    self.resource_ids.values().cloned(),
                ))
                .cloned()
                .collect_vec(),
        );
    }

    pub(crate) fn add_resources(&mut self, resources: &[ResourceDescription]) {
        for resource_description in resources {
            if let Some(resource) = self.resource_ids.get(&resource_description.id()) {
                if resource.has_different_address(resource_description) {
                    self.remove_resources(&[resource.id()]);
                }
            }

            match &resource_description {
                ResourceDescription::Dns(dns) => {
                    self.dns_resources.insert(dns.address.clone(), dns.clone());
                }
                ResourceDescription::Cidr(cidr) => {
                    self.cidr_resources.insert(cidr.address, cidr.clone());
                }
            }

            self.resource_ids
                .insert(resource_description.id(), resource_description.clone());
        }
    }

    #[tracing::instrument(level = "debug", skip_all, fields(?ids))]
    fn remove_resources(&mut self, ids: &[ResourceId]) {
        for id in ids {
            self.awaiting_connection.remove(id);
            self.dns_resources_internal_ips.retain(|_, r| r.id != *id);
            self.dns_resources.retain(|_, r| r.id != *id);
            self.cidr_resources.retain(|_, r| r.id != *id);
            self.deferred_dns_queries.retain(|(r, _), _| r.id != *id);

            self.resource_ids.remove(id);

            let Some(peer) = self.peer_by_resource_mut(*id) else {
                continue;
            };
            let gateway_id = peer.id();

            // First we remove the id from all allowed ips
            for (network, resources) in peer
                .allowed_ips
                .iter_mut()
                .filter(|(_, resources)| resources.contains(id))
            {
                resources.remove(id);

                if !resources.is_empty() {
                    continue;
                }

                // If the allowed_ips doesn't correspond to any resource anymore we
                // clean up any related translation.
                peer.translations.remove_by_left(&network.network_address());
            }

            // We remove all empty allowed ips entry since there's no resource that corresponds to it
            peer.allowed_ips.retain(|_, r| !r.is_empty());

            // If there's no allowed ip left we remove the whole peer because there's no point on keeping it around
            if peer.allowed_ips.is_empty() {
                self.peers.remove(&gateway_id);
                self.update_site_status_by_gateway(&gateway_id, Status::Unknown);
                // TODO: should we have a Node::remove_connection?
            }
        }

        tracing::debug!("Resources removed")
    }

    fn update_dns_mapping(&mut self) -> bool {
        let Some(config) = &self.interface_config else {
            return false;
        };

        let effective_dns_servers =
            effective_dns_servers(config.upstream_dns.clone(), self.system_resolvers.clone());

        if HashSet::<&DnsServer>::from_iter(effective_dns_servers.iter())
            == HashSet::from_iter(self.dns_mapping.right_values())
        {
            return false;
        }

        let dns_mapping = sentinel_dns_mapping(
            &effective_dns_servers,
            self.dns_mapping()
                .left_values()
                .copied()
                .map(Into::into)
                .collect_vec(),
        );

        self.set_dns_mapping(dns_mapping);

        self.buffered_events
            .push_back(ClientEvent::DnsServersChanged {
                dns_by_sentinel: self
                    .dns_mapping
                    .iter()
                    .map(|(sentinel_dns, effective_dns)| (*sentinel_dns, effective_dns.address()))
                    .collect(),
            });

        true
    }

    pub fn update_relays(
        &mut self,
        to_remove: HashSet<RelayId>,
        to_add: HashSet<(RelayId, RelaySocket, String, String, String)>,
        now: Instant,
    ) {
        self.node.update_relays(to_remove, &to_add, now);
    }

    fn peer_by_resource(&self, resource: ResourceId) -> Option<&GatewayOnClient> {
        let gateway_id = self.resources_gateways.get(&resource)?;
        let peer = self.peers.get(gateway_id)?;

        Some(peer)
    }

    fn peer_by_resource_mut(&mut self, resource: ResourceId) -> Option<&mut GatewayOnClient> {
        let gateway_id = self.resources_gateways.get(&resource)?;
        let peer = self.peers.get_mut(gateway_id)?;

        Some(peer)
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
        tracing::error!("No system default DNS servers available! Can't initialize resolver. DNS interception will be disabled.");
        return Vec::new();
    }

    dns_servers.collect()
}

fn not_sentinel(srv: DnsServer) -> Option<DnsServer> {
    (!IpNetwork::from_str(DNS_SENTINELS_V4)
        .unwrap()
        .contains(srv.ip())
        && !IpNetwork::from_str(DNS_SENTINELS_V6)
            .unwrap()
            .contains(srv.ip()))
    .then_some(srv)
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

pub struct IpProvider {
    ipv4: Box<dyn Iterator<Item = Ipv4Addr> + Send + Sync>,
    ipv6: Box<dyn Iterator<Item = Ipv6Addr> + Send + Sync>,
}

impl IpProvider {
    pub fn for_resources() -> Self {
        IpProvider::new(
            IPV4_RESOURCES.parse().unwrap(),
            IPV6_RESOURCES.parse().unwrap(),
            vec![
                DNS_SENTINELS_V4.parse().unwrap(),
                DNS_SENTINELS_V6.parse().unwrap(),
            ],
        )
    }

    pub fn for_stub_dns_servers(exclusions: Vec<IpNetwork>) -> Self {
        IpProvider::new(
            DNS_SENTINELS_V4.parse().unwrap(),
            DNS_SENTINELS_V6.parse().unwrap(),
            exclusions,
        )
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_core::OsRng;

    #[test]
    fn ignores_ip4_igmp_multicast() {
        assert!(is_definitely_not_a_resource(ip("224.0.0.22")))
    }

    #[test]
    fn ignores_ip6_multicast_all_routers() {
        assert!(is_definitely_not_a_resource(ip("ff02::2")))
    }

    #[test]
    fn update_system_dns_works() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_without_dns());

        let dns_changed = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);

        assert!(dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.1.1.1:53")]);
    }

    #[test]
    fn update_system_dns_without_change_is_a_no_op() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_without_dns());

        let _ = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);
        let dns_changed = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);

        assert!(!dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.1.1.1:53")]);
    }

    #[test]
    fn update_system_dns_with_change_works() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_without_dns());

        let _ = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);
        let dns_changed = client_state.update_system_resolvers(vec![ip("1.0.0.1")]);

        assert!(dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.0.0.1:53")]);
    }

    #[test]
    fn update_to_system_with_sentinels_are_ignored() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_without_dns());

        let _ = client_state.update_system_resolvers(vec![ip("1.1.1.1")]);
        let dns_changed = client_state.update_system_resolvers(vec![
            ip("1.1.1.1"),
            ip("100.100.111.1"),
            ip("fd00:2021:1111:8000:100:100:111:0"),
        ]);

        assert!(!dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.1.1.1:53")]);
    }

    #[test]
    fn upstream_dns_wins_over_system() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_with_dns());

        let dns_changed = client_state.update_dns_mapping();
        assert!(dns_changed);

        let dns_changed = client_state.update_system_resolvers(vec![ip("1.0.0.1")]);
        assert!(!dns_changed);

        dns_mapping_is_exactly(client_state.dns_mapping(), dns_list());
    }

    #[test]
    fn upstream_dns_change_updates() {
        let mut client_state = ClientState::for_test();

        let dns_changed = client_state.update_interface_config(interface_config_with_dns());

        assert!(dns_changed);

        let dns_changed = client_state.update_interface_config(InterfaceConfig {
            upstream_dns: vec![dns("8.8.8.8:53")],
            ..interface_config_without_dns()
        });

        assert!(dns_changed);

        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("8.8.8.8:53")]);
    }

    #[test]
    fn upstream_dns_no_change_is_a_no_op() {
        let mut client_state = ClientState::for_test();
        client_state.interface_config = Some(interface_config_with_dns());

        let dns_changed = client_state.update_system_resolvers(vec![ip("1.0.0.1")]);

        assert!(dns_changed);

        let dns_changed = client_state.update_interface_config(interface_config_with_dns());

        assert!(!dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), dns_list());
    }

    #[test]
    fn upstream_dns_sentinels_are_ignored() {
        let mut client_state = ClientState::for_test();
        let mut config = interface_config_with_dns();

        let _ = client_state.update_interface_config(config.clone());

        config.upstream_dns.push(dns("100.100.111.1:53"));
        config
            .upstream_dns
            .push(dns("[fd00:2021:1111:8000:100:100:111:0]:53"));

        let dns_changed = client_state.update_interface_config(config);

        assert!(!dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), dns_list())
    }

    #[test]
    fn system_dns_takes_over_when_upstream_are_unset() {
        let mut client_state = ClientState::for_test();
        let _ = client_state.update_interface_config(interface_config_with_dns());

        let _ = client_state.update_system_resolvers(vec![ip("1.0.0.1")]);
        let dns_changed = client_state.update_interface_config(interface_config_without_dns());

        assert!(dns_changed);
        dns_mapping_is_exactly(client_state.dns_mapping(), vec![dns("1.0.0.1:53")]);
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
            ClientState::new(StaticSecret::random_from_rng(OsRng))
        }
    }

    fn dns_mapping_is_exactly(mapping: BiMap<IpAddr, DnsServer>, servers: Vec<DnsServer>) {
        assert_eq!(
            HashSet::<&DnsServer>::from_iter(mapping.right_values()),
            HashSet::from_iter(servers.iter())
        )
    }

    fn interface_config_without_dns() -> InterfaceConfig {
        InterfaceConfig {
            ipv4: "10.0.0.1".parse().unwrap(),
            ipv6: "fe80::".parse().unwrap(),
            upstream_dns: Vec::new(),
        }
    }

    fn interface_config_with_dns() -> InterfaceConfig {
        InterfaceConfig {
            ipv4: "10.0.0.1".parse().unwrap(),
            ipv6: "fe80::".parse().unwrap(),
            upstream_dns: dns_list(),
        }
    }

    fn sentinel_ranges() -> Vec<IpNetwork> {
        vec![
            IpNetwork::from_str(DNS_SENTINELS_V4).unwrap(),
            IpNetwork::from_str(DNS_SENTINELS_V6).unwrap(),
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

#[cfg(test)]
mod testutils {
    use super::*;

    pub fn expected_routes(resource_routes: Vec<IpNetwork>) -> HashSet<IpNetwork> {
        HashSet::from_iter(
            resource_routes
                .into_iter()
                .chain(iter::once(IpNetwork::from_str(IPV4_RESOURCES).unwrap()))
                .chain(iter::once(IpNetwork::from_str(IPV6_RESOURCES).unwrap())),
        )
    }

    #[allow(clippy::redundant_clone)] // False positive.
    pub fn hashset<T: std::hash::Hash + Eq, B: ToOwned<Owned = T>>(
        val: impl IntoIterator<Item = B>,
    ) -> HashSet<T> {
        HashSet::from_iter(val.into_iter().map(|b| b.to_owned()))
    }
}

#[cfg(all(test, feature = "proptest"))]
mod proptests {
    use super::*;
    use connlib_shared::proptest::*;
    use testutils::*;

    #[test_strategy::proptest]
    fn cidr_resources_are_turned_into_routes(
        #[strategy(cidr_resource(8))] resource1: ResourceDescriptionCidr,
        #[strategy(cidr_resource(8))] resource2: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();

        client_state.add_resources(&[
            ResourceDescription::Cidr(resource1.clone()),
            ResourceDescription::Cidr(resource2.clone()),
        ]);

        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![resource1.address, resource2.address])
        );
    }

    #[test_strategy::proptest]
    fn added_resources_show_up_as_resoucres(
        #[strategy(cidr_resource(8))] resource1: ResourceDescriptionCidr,
        #[strategy(dns_resource())] resource2: ResourceDescriptionDns,
        #[strategy(cidr_resource(8))] resource3: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();

        client_state.add_resources(&[
            ResourceDescription::Cidr(resource1.clone()),
            ResourceDescription::Dns(resource2.clone()),
        ]);

        assert_eq!(
            hashset(
                client_state
                    .resources()
                    .into_iter()
                    .map_into::<ResourceDescription>()
            ),
            hashset([
                ResourceDescription::Cidr(resource1.clone()),
                ResourceDescription::Dns(resource2.clone())
            ])
        );

        client_state.add_resources(&[ResourceDescription::Cidr(resource3.clone())]);

        assert_eq!(
            hashset(
                client_state
                    .resources()
                    .into_iter()
                    .map_into::<ResourceDescription>()
            ),
            hashset([
                ResourceDescription::Cidr(resource1),
                ResourceDescription::Dns(resource2),
                ResourceDescription::Cidr(resource3)
            ])
        );
    }

    #[test_strategy::proptest]
    fn adding_same_resource_with_different_address_updates_the_address(
        #[strategy(cidr_resource(8))] resource: ResourceDescriptionCidr,
        #[strategy(ip_network(8))] new_address: IpNetwork,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&[ResourceDescription::Cidr(resource.clone())]);

        let updated_resource = ResourceDescriptionCidr {
            address: new_address,
            ..resource
        };

        client_state.add_resources(&[ResourceDescription::Cidr(updated_resource.clone())]);

        assert_eq!(
            hashset(
                client_state
                    .resources()
                    .into_iter()
                    .map_into::<ResourceDescription>()
            ),
            hashset([ResourceDescription::Cidr(updated_resource),])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![new_address])
        );
    }

    #[test_strategy::proptest]
    fn adding_cidr_resource_with_same_id_as_dns_resource_replaces_dns_resource(
        #[strategy(dns_resource())] resource: ResourceDescriptionDns,
        #[strategy(ip_network(8))] address: IpNetwork,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&[ResourceDescription::Dns(resource.clone())]);

        let dns_as_cidr_resource = ResourceDescriptionCidr {
            address,
            id: resource.id,
            name: resource.name,
            address_description: resource.address_description,
            sites: resource.sites,
        };

        client_state.add_resources(&[ResourceDescription::Cidr(dns_as_cidr_resource.clone())]);

        assert_eq!(
            hashset(
                client_state
                    .resources()
                    .into_iter()
                    .map_into::<ResourceDescription>()
            ),
            hashset([ResourceDescription::Cidr(dns_as_cidr_resource),])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![address])
        );
    }

    #[test_strategy::proptest]
    fn resources_can_be_removed(
        #[strategy(dns_resource())] dns_resource: ResourceDescriptionDns,
        #[strategy(cidr_resource(8))] cidr_resource: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&[
            ResourceDescription::Dns(dns_resource.clone()),
            ResourceDescription::Cidr(cidr_resource.clone()),
        ]);

        client_state.remove_resources(&[dns_resource.id]);

        assert_eq!(
            hashset(
                client_state
                    .resources()
                    .into_iter()
                    .map_into::<ResourceDescription>()
            ),
            hashset([ResourceDescription::Cidr(cidr_resource.clone())])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![cidr_resource.address])
        );

        client_state.remove_resources(&[cidr_resource.id]);

        assert_eq!(hashset(client_state.resources().iter()), hashset(&[]));
        assert_eq!(hashset(client_state.routes()), expected_routes(vec![]));
    }

    #[test_strategy::proptest]
    fn resources_can_be_replaced(
        #[strategy(dns_resource())] dns_resource1: ResourceDescriptionDns,
        #[strategy(dns_resource())] dns_resource2: ResourceDescriptionDns,
        #[strategy(cidr_resource(8))] cidr_resource1: ResourceDescriptionCidr,
        #[strategy(cidr_resource(8))] cidr_resource2: ResourceDescriptionCidr,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&[
            ResourceDescription::Dns(dns_resource1),
            ResourceDescription::Cidr(cidr_resource1),
        ]);

        client_state.set_resources(vec![
            ResourceDescription::Dns(dns_resource2.clone()),
            ResourceDescription::Cidr(cidr_resource2.clone()),
        ]);

        assert_eq!(
            hashset(
                client_state
                    .resources()
                    .into_iter()
                    .map_into::<ResourceDescription>()
            ),
            hashset([
                ResourceDescription::Dns(dns_resource2),
                ResourceDescription::Cidr(cidr_resource2.clone()),
            ])
        );
        assert_eq!(
            hashset(client_state.routes()),
            expected_routes(vec![cidr_resource2.address])
        );
    }

    #[test_strategy::proptest]
    fn setting_gateway_online_sets_all_related_resources_online(
        #[strategy(resources_sharing_site())] resource_config_online: (
            Vec<ResourceDescription>,
            Site,
        ),
        #[strategy(resources_sharing_site())] resource_config_unknown: (
            Vec<ResourceDescription>,
            Site,
        ),
        #[strategy(gateway_id())] first_resource_gateway_id: GatewayId,
    ) {
        let (resources_online, site) = resource_config_online;
        let (resources_unknown, _) = resource_config_unknown;
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&resources_online);
        client_state.add_resources(&resources_unknown);
        client_state.resources_gateways.insert(
            resources_online.first().unwrap().id(),
            first_resource_gateway_id,
        );
        client_state
            .gateways_site
            .insert(first_resource_gateway_id, site.id);

        client_state.update_site_status_by_gateway(&first_resource_gateway_id, Status::Online);

        for resource in resources_online {
            assert_eq!(client_state.resource_status(&resource), Status::Online);
        }

        for resource in resources_unknown {
            assert_eq!(client_state.resource_status(&resource), Status::Unknown);
        }
    }

    #[test_strategy::proptest]
    fn disconnecting_gateway_sets_related_resources_unknown(
        #[strategy(resources_sharing_site())] resource_config: (Vec<ResourceDescription>, Site),
        #[strategy(gateway_id())] first_resource_gateway_id: GatewayId,
    ) {
        let (resources, site) = resource_config;
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&resources);
        client_state
            .resources_gateways
            .insert(resources.first().unwrap().id(), first_resource_gateway_id);
        client_state
            .gateways_site
            .insert(first_resource_gateway_id, site.id);

        client_state.update_site_status_by_gateway(&first_resource_gateway_id, Status::Online);
        client_state.update_site_status_by_gateway(&first_resource_gateway_id, Status::Unknown);

        for resource in resources {
            assert_eq!(client_state.resource_status(&resource), Status::Unknown);
        }
    }

    #[test_strategy::proptest]
    fn setting_resource_offline_doesnt_set_all_related_resources_offline(
        #[strategy(resources_sharing_site())] resource_config_online: (
            Vec<ResourceDescription>,
            Site,
        ),
    ) {
        let (mut resources, _) = resource_config_online;
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&resources);
        let resource_offline = resources.pop().unwrap();

        client_state.set_resource_offline(resource_offline.id());

        assert_eq!(
            client_state.resource_status(&resource_offline),
            Status::Offline
        );
        for resource in resources {
            assert_eq!(client_state.resource_status(&resource), Status::Unknown);
        }
    }

    #[test_strategy::proptest]
    fn setting_resource_offline_set_all_resources_sharing_all_groups_offline(
        #[strategy(resources_sharing_all_sites())] resources: Vec<ResourceDescription>,
    ) {
        let mut client_state = ClientState::for_test();
        client_state.add_resources(&resources);

        client_state.set_resource_offline(resources.first().unwrap().id());

        for resource in resources {
            assert_eq!(client_state.resource_status(&resource), Status::Offline);
        }
    }
}
