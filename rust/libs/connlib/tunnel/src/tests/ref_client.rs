use super::{
    QueryId,
    dns_records::DnsRecords,
    reference::{PrivateKey, private_key},
    sim_client::SimClient,
    sim_net::{Host, any_ip_stack, host},
    strategies::latency,
    transition::{DPort, Destination, DnsQuery, DnsTransport, Identifier, SPort, Seq},
};
use crate::{
    ClientState,
    client::{CidrResource, DnsResource, InternetResource, Resource},
    dns,
    filter_engine::FilterEngine,
    messages::{Filter, Interface, UpstreamDo53, UpstreamDoH},
};
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, GatewayId, ResourceId, ResourceStatus, Site, SiteId};
use dns_types::{DomainName, RecordType};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_packet::Protocol;
use itertools::Itertools as _;
use proptest::prelude::*;
use std::{
    cmp::Ordering,
    collections::{BTreeMap, BTreeSet, VecDeque},
    iter, mem,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    num::NonZeroU16,
    time::{Duration, Instant},
};

/// Reference state for a particular client.
///
/// The reference state machine is designed to be as abstract as possible over connlib's functionality.
/// For example, we try to model connectivity to _resources_ and don't really care, which gateway is being used to route us there.
#[derive(Clone, derive_more::Debug)]
pub struct RefClient {
    id: ClientId,

    pub(crate) key: PrivateKey,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,

    /// The DNS resolvers configured on the client outside of connlib.
    #[debug(skip)]
    system_dns_resolvers: Vec<IpAddr>,

    routes: Vec<(ResourceId, IpNetwork)>,

    /// Tracks all resources in the order they have been added in.
    ///
    /// When reconnecting to the portal, we simulate them being re-added in the same order.
    #[debug(skip)]
    resources: Vec<Resource>,

    pub(crate) internet_resource_active: bool,

    /// The client's DNS records.
    ///
    /// The IPs assigned to a domain by connlib are an implementation detail that we don't want to model in these tests.
    /// Instead, we just remember what _kind_ of records we resolved to be able to sample a matching src IP.
    #[debug(skip)]
    pub(crate) dns_records: BTreeMap<DomainName, BTreeSet<RecordType>>,

    /// Whether we are connected to the gateway serving the Internet resource.
    #[debug(skip)]
    pub(crate) connected_internet_resource: bool,

    /// The CIDR resources the client is connected to.
    #[debug(skip)]
    pub(crate) connected_cidr_resources: BTreeSet<ResourceId>,

    /// The DNS resources the client is connected to.
    #[debug(skip)]
    pub(crate) connected_dns_resources: BTreeSet<ResourceId>,

    /// The [`ResourceStatus`] of each site.
    #[debug(skip)]
    site_status: BTreeMap<SiteId, ResourceStatus>,

    /// The expected ICMP handshakes with Gateways.
    #[debug(skip)]
    pub(crate) expected_gateway_icmp_handshakes:
        BTreeMap<GatewayId, BTreeMap<u64, (Destination, Seq, Identifier)>>,

    /// The expected ICMP handshakes with Clients.
    #[debug(skip)]
    pub(crate) expected_client_icmp_handshakes:
        BTreeMap<ClientId, BTreeMap<u64, (Destination, Seq, Identifier)>>,

    /// The expected UDP handshakes with Gateways.
    #[debug(skip)]
    pub(crate) expected_gateway_udp_handshakes:
        BTreeMap<GatewayId, BTreeMap<u64, (Destination, SPort, DPort)>>,

    /// The expected UDP handshakes with Clients.
    #[debug(skip)]
    pub(crate) expected_client_udp_handshakes:
        BTreeMap<ClientId, BTreeMap<u64, (Destination, SPort, DPort)>>,

    /// The expected TCP connections.
    #[debug(skip)]
    pub(crate) expected_tcp_connections: BTreeMap<(IpAddr, Destination, SPort, DPort), ResourceId>,

    /// The expected UDP DNS handshakes.
    #[debug(skip)]
    pub(crate) expected_udp_dns_handshakes: VecDeque<(dns::Upstream, QueryId, u16)>,
    /// The expected TCP DNS handshakes.
    #[debug(skip)]
    pub(crate) expected_tcp_dns_handshakes: VecDeque<(dns::Upstream, QueryId)>,

    #[debug(skip)]
    connection_resets: Vec<Instant>,
}

impl RefClient {
    /// Initialize the [`ClientState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(
        self,
        upstream_do53: Vec<UpstreamDo53>,
        upstream_doh: Vec<UpstreamDoH>,
        search_domain: Option<DomainName>,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) -> SimClient {
        let mut client_state = ClientState::new(
            self.key.0,
            Default::default(),
            self.internet_resource_active,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        ); // Cheating a bit here by reusing the key as seed.
        client_state.update_interface_config(Interface {
            ipv4: self.tunnel_ip4,
            ipv6: self.tunnel_ip6,
            upstream_dns: Vec::new(),
            upstream_do53,
            upstream_doh,
            search_domain,
        });
        client_state.update_system_resolvers(self.system_dns_resolvers);

        SimClient::new(self.id, client_state, now)
    }

    pub(crate) fn disconnect_resource(&mut self, resource: &ResourceId) {
        for _ in self.routes.extract_if(.., |(r, _)| r == resource) {}

        self.connected_cidr_resources.remove(resource);
        self.connected_dns_resources.remove(resource);

        if self.internet_resource().is_some_and(|r| r == *resource) {
            self.connected_internet_resource = false;
        }

        let Some(site) = self.site_for_resource(*resource) else {
            tracing::error!(%resource, "No site for resource");
            return;
        };

        // If this was the last resource we were connected to for this site,
        // the connection will be GC'd.
        if self
            .connected_resources()
            .all(|r| self.site_for_resource(r).is_some_and(|s| s != site))
        {
            tracing::debug!(
                last_resource = %resource,
                site = %site.id,
                "We are no longer connected to any resources in this site"
            );

            self.site_status.remove(&site.id);
        }
    }

    pub(crate) fn set_internet_resource_state(&mut self, active: bool) {
        let resource = self
            .resources
            .iter()
            .find(|r| matches!(r, Resource::Internet(_)));

        self.internet_resource_active = active;

        let Some(resource) = resource else {
            return;
        };

        if active {
            self.routes
                .push((resource.id(), Ipv4Network::DEFAULT_ROUTE.into()));
            self.routes
                .push((resource.id(), Ipv6Network::DEFAULT_ROUTE.into()));
        } else {
            self.disconnect_resource(&resource.id());
        }
    }

    pub(crate) fn remove_resource(&mut self, resource: &ResourceId) {
        self.disconnect_resource(resource);

        if self.internet_resource().is_some_and(|r| r == *resource) {
            self.internet_resource_active = false;
        }

        self.resources.retain(|r| r.id() != *resource);
    }

    pub(crate) fn connected_resources(&self) -> impl Iterator<Item = ResourceId> + '_ {
        iter::empty()
            .chain(self.connected_cidr_resources.clone())
            .chain(self.connected_dns_resources.clone())
            .chain(
                self.connected_internet_resource
                    .then(|| self.internet_resource())
                    .flatten(),
            )
    }

    pub(crate) fn restart(&mut self, key: PrivateKey, now: Instant) {
        self.routes.clear();

        self.key = key;

        self.reset_connections(now);
        self.readd_all_resources();
    }

    pub(crate) fn reset_connections(&mut self, now: Instant) {
        self.connection_resets.push(now);

        self.connected_cidr_resources.clear();
        self.connected_dns_resources.clear();
        self.connected_internet_resource = false;

        for status in self.site_status.values_mut() {
            *status = ResourceStatus::Unknown;
        }
    }

    pub(crate) fn add_internet_resource(&mut self, resource: InternetResource) {
        self.resources.push(Resource::Internet(resource.clone()));

        if self.internet_resource_active {
            self.routes
                .push((resource.id, Ipv4Network::DEFAULT_ROUTE.into()));
            self.routes
                .push((resource.id, Ipv6Network::DEFAULT_ROUTE.into()));
        }
    }

    pub(crate) fn add_cidr_resource(&mut self, r: CidrResource) {
        let address = r.address;
        let r = Resource::Cidr(r);
        let rid = r.id();

        if let Some(existing) = self.resources.iter().find(|existing| existing.id() == rid)
            && (existing.has_different_address(&r)
                || existing.has_different_site(&r)
                || existing.has_different_filters(&r))
        {
            self.remove_resource(&existing.id());
        }

        self.resources.push(r);
        self.routes.push((rid, address));

        if self.expected_tcp_connections.values().contains(&rid) {
            self.set_resource_online(rid);
        }
    }

    pub(crate) fn add_dns_resource(&mut self, r: DnsResource) {
        let r = Resource::Dns(r);
        let rid = r.id();

        if let Some(existing) = self.resources.iter().find(|existing| existing.id() == rid)
            && (existing.has_different_address(&r)
                || existing.has_different_ip_stack(&r)
                || existing.has_different_site(&r)
                || existing.has_different_filters(&r))
        {
            self.remove_resource(&existing.id());
        }

        self.resources.push(r);

        if self.expected_tcp_connections.values().contains(&rid) {
            self.set_resource_online(rid);
        }
    }

    /// Re-adds all resources in the order they have been initially added.
    pub(crate) fn readd_all_resources(&mut self) {
        for resource in mem::take(&mut self.resources) {
            match resource {
                Resource::Dns(d) => self.add_dns_resource(d),
                Resource::Cidr(c) => self.add_cidr_resource(c),
                Resource::Internet(i) => self.add_internet_resource(i),
                Resource::StaticDevicePool(_) | Resource::DynamicDevicePool(_) => {}
            }
        }
    }

    pub(crate) fn expected_resource_status(&self) -> BTreeMap<ResourceId, ResourceStatus> {
        self.resources
            .iter()
            .filter_map(|r| {
                let status = self
                    .site_status
                    .get(&r.site().ok()?.id)
                    .copied()
                    .unwrap_or(ResourceStatus::Unknown);

                Some((r.id(), status))
            })
            .collect()
    }

    /// Returns the list of resources where we are not "sure" whether they are online or unknown.
    ///
    /// Resources with TCP connections have an automatic retry and therefore, modelling their exact online/unknown state is difficult.
    pub(crate) fn maybe_online_resources(&self) -> BTreeSet<ResourceId> {
        let resources_with_tcp_connections = self
            .expected_tcp_connections
            .values()
            .copied()
            .collect::<BTreeSet<_>>();

        let maybe_online_sites = resources_with_tcp_connections
            .into_iter()
            .flat_map(|r| self.site_for_resource(r))
            .collect::<BTreeSet<_>>();

        self.resources
            .iter()
            .filter_map(move |r| {
                maybe_online_sites
                    .contains(r.site().unwrap())
                    .then_some(r.id())
            })
            .collect()
    }

    pub(crate) fn tunnel_ip_for(&self, dst: IpAddr) -> IpAddr {
        match dst {
            IpAddr::V4(_) => self.tunnel_ip4.into(),
            IpAddr::V6(_) => self.tunnel_ip6.into(),
        }
    }

    pub(crate) fn on_icmp_packet_to_device(
        &mut self,
        remote_client: ClientId,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
        payload: u64,
    ) {
        self.expected_client_icmp_handshakes
            .entry(remote_client)
            .or_default()
            .insert(payload, (dst, seq, identifier));
    }

    pub(crate) fn on_icmp_packet(
        &mut self,
        dst: Destination,
        seq: Seq,
        identifier: Identifier,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
        gateway_by_ip: impl Fn(IpAddr) -> Option<GatewayId>,
    ) {
        self.on_packet(
            dst.clone(),
            Protocol::IcmpEcho(identifier.0),
            (dst, seq, identifier),
            |ref_client| &mut ref_client.expected_gateway_icmp_handshakes,
            payload,
            gateway_by_resource,
            gateway_by_ip,
        );
    }

    pub(crate) fn on_udp_packet(
        &mut self,
        dst: Destination,
        sport: SPort,
        dport: DPort,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
        gateway_by_ip: impl Fn(IpAddr) -> Option<GatewayId>,
    ) {
        self.on_packet(
            dst.clone(),
            Protocol::Udp(dport.0),
            (dst, sport, dport),
            |ref_client| &mut ref_client.expected_gateway_udp_handshakes,
            payload,
            gateway_by_resource,
            gateway_by_ip,
        );
    }

    #[tracing::instrument(level = "debug", skip_all, fields(dst, resource, gateway))]
    fn on_packet<E>(
        &mut self,
        dst: Destination,
        proto: Protocol,
        packet_id: E,
        map: impl FnOnce(&mut Self) -> &mut BTreeMap<GatewayId, BTreeMap<u64, E>>,
        payload: u64,
        gateway_by_resource: impl Fn(ResourceId) -> Option<GatewayId>,
        gateway_by_ip: impl Fn(IpAddr) -> Option<GatewayId>,
    ) {
        let gateway = if dst.ip_addr().is_some_and(crate::is_peer) {
            let Some(gateway) = gateway_by_ip(dst.ip_addr().unwrap()) else {
                tracing::error!("Unknown gateway");
                return;
            };
            tracing::Span::current().record("gateway", tracing::field::display(gateway));

            gateway
        } else {
            let Some(resource) = self.resource_by_dst(&dst, proto) else {
                tracing::warn!("Unknown resource");
                return;
            };

            tracing::Span::current().record("resource", tracing::field::display(resource));

            let Some(gateway) = gateway_by_resource(resource) else {
                tracing::error!("No gateway for resource");
                return;
            };

            tracing::Span::current().record("gateway", tracing::field::display(gateway));

            self.connect_to_resource(resource, dst);
            self.set_resource_online(resource);

            gateway
        };

        tracing::debug!(%payload, "Sending packet");

        map(self)
            .entry(gateway)
            .or_default()
            .insert(payload, packet_id);
    }

    pub(crate) fn on_connect_tcp(
        &mut self,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
    ) {
        let Some(resource) = self.resource_by_dst(&dst, Protocol::Tcp(dport.0)) else {
            tracing::warn!("Unknown resource");
            return;
        };

        self.connect_to_resource(resource, dst.clone());
        self.set_resource_online(resource);

        self.expected_tcp_connections
            .insert((src, dst, sport, dport), resource);
    }

    fn connect_to_resource(&mut self, resource: ResourceId, destination: Destination) {
        match destination {
            Destination::DomainName { .. } => {
                self.connected_dns_resources.insert(resource);
            }
            Destination::IpAddr(_) => self.connect_to_internet_or_cidr_resource(resource),
        }
    }

    fn set_resource_online(&mut self, rid: ResourceId) {
        let Some(site) = self.site_for_resource(rid) else {
            tracing::error!(%rid, "Unknown resource or multi-site resource");
            return;
        };

        let previous = self.site_status.insert(site.id, ResourceStatus::Online);

        if previous.is_none_or(|s| s != ResourceStatus::Online) {
            tracing::debug!(%rid, sid = %site.id, "Resource is now online");
        }
    }

    fn connect_to_internet_or_cidr_resource(&mut self, rid: ResourceId) {
        if self.internet_resource_active
            && let Some(internet) = self.internet_resource()
            && internet == rid
        {
            self.connected_internet_resource = true;
            return;
        }

        if self.resources.iter().any(|r| r.id() == rid) {
            let is_new = self.connected_cidr_resources.insert(rid);

            if is_new {
                tracing::debug!(%rid, "Now connected to CIDR resource");
            }
        }
    }

    pub(crate) fn on_dns_query(&mut self, query: &DnsQuery, upstream_do53: &[UpstreamDo53]) {
        self.dns_records
            .entry(query.domain.clone())
            .or_default()
            .insert(query.r_type);

        match query.transport {
            DnsTransport::Udp { local_port } => {
                self.expected_udp_dns_handshakes.push_back((
                    query.dns_server.clone(),
                    query.query_id,
                    local_port,
                ));
            }
            DnsTransport::Tcp => {
                self.expected_tcp_dns_handshakes
                    .push_back((query.dns_server.clone(), query.query_id));
            }
        }

        if let Some(resource) = self.is_site_specific_dns_query(query) {
            self.set_resource_online(resource);
            self.connected_dns_resources.insert(resource);
            return;
        }

        if let Some(resource) = self.dns_query_via_resource(query, upstream_do53) {
            self.connect_to_internet_or_cidr_resource(resource);
            self.set_resource_online(resource);
        }
    }

    pub(crate) fn ipv4_cidr_resource_dsts(&self) -> Vec<(Ipv4Network, Vec<Filter>)> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_cidr())
            .filter_map(|c| match c.address {
                IpNetwork::V4(ipv4_network) => Some((ipv4_network, c.filters)),
                IpNetwork::V6(_) => None,
            })
            .collect()
    }

    pub(crate) fn ipv6_cidr_resource_dsts(&self) -> Vec<(Ipv6Network, Vec<Filter>)> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_cidr())
            .filter_map(|c| match c.address {
                IpNetwork::V6(ipv6_network) => Some((ipv6_network, c.filters)),
                IpNetwork::V4(_) => None,
            })
            .collect()
    }

    fn site_for_resource(&self, resource: ResourceId) -> Option<Site> {
        let site = self
            .resources
            .iter()
            .find_map(|r| (r.id() == resource).then_some(r.site()))?
            .ok()?
            .clone();

        Some(site)
    }

    pub(crate) fn active_internet_resource(&self) -> Option<ResourceId> {
        self.internet_resource_active
            .then(|| self.internet_resource())
            .flatten()
    }

    fn resource_by_dst(&self, destination: &Destination, proto: Protocol) -> Option<ResourceId> {
        match destination {
            Destination::DomainName { name, .. } => {
                if let Some(r) = self.dns_resource_by_domain_and_proto(name, proto) {
                    return Some(r.id);
                }
            }
            Destination::IpAddr(addr) => {
                if let Some(id) = self.cidr_resource_by_ip_and_proto(*addr, proto) {
                    return Some(id);
                }
            }
        }

        self.active_internet_resource()
    }

    pub(crate) fn dns_resource_by_domain_and_proto(
        &self,
        domain: &DomainName,
        proto: Protocol,
    ) -> Option<DnsResource> {
        self.dns_resource_by_domain(domain, |r| {
            FilterEngine::new(&r.filters).apply(Ok(proto)).is_ok()
        })
    }

    pub(crate) fn dns_resource_by_domain(
        &self,
        domain: &DomainName,
        predicate: impl Fn(&DnsResource) -> bool,
    ) -> Option<DnsResource> {
        self.resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_dns())
            .filter(|r| is_subdomain(&domain.to_string(), &r.address))
            .max_by(|r1, r2| {
                let by_predicate = match (predicate(r1), predicate(r2)) {
                    (true, true) | (false, false) => Ordering::Equal,
                    (true, false) => Ordering::Greater,
                    (false, true) => Ordering::Less,
                };
                let by_pattern = dns::Pattern::new(&r1.address)
                    .unwrap()
                    .cmp(&dns::Pattern::new(&r2.address).unwrap())
                    .reverse();
                let by_id = r1.id.cmp(&r2.id);

                by_predicate.then(by_pattern).then(by_id)
            })
    }

    fn resolved_domains(&self) -> impl Iterator<Item = (DomainName, BTreeSet<RecordType>)> + '_ {
        self.dns_records
            .iter()
            .filter(|(domain, _)| self.dns_resource_by_domain(domain, |_| true).is_some())
            .map(|(domain, ips)| (domain.clone(), ips.clone()))
    }

    /// An ICMP packet is valid if we didn't yet send an ICMP packet with the same seq, identifier and payload.
    pub(crate) fn is_valid_icmp_packet(
        &self,
        seq: &Seq,
        identifier: &Identifier,
        payload: &u64,
    ) -> bool {
        let not_an_existing_gateway_handshake = self
            .expected_gateway_icmp_handshakes
            .values()
            .flatten()
            .all(
                |(existig_payload, (_, existing_seq, existing_identifier))| {
                    existing_seq != seq
                        && existing_identifier != identifier
                        && existig_payload != payload
                },
            );
        let not_an_existing_client_handshake =
            self.expected_client_icmp_handshakes.values().flatten().all(
                |(existig_payload, (_, existing_seq, existing_identifier))| {
                    existing_seq != seq
                        && existing_identifier != identifier
                        && existig_payload != payload
                },
            );

        not_an_existing_gateway_handshake && not_an_existing_client_handshake
    }

    /// An UDP packet is valid if we didn't yet send an UDP packet with the same sport, dport and payload.
    pub(crate) fn is_valid_udp_packet(&self, sport: &SPort, dport: &DPort, payload: &u64) -> bool {
        self.expected_gateway_udp_handshakes.values().flatten().all(
            |(existig_payload, (_, existing_sport, existing_dport))| {
                existing_dport != dport && existing_sport != sport && existig_payload != payload
            },
        )
    }

    pub(crate) fn resolved_v4_domains(&self) -> Vec<(DomainName, Vec<Filter>)> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                if !records.iter().any(|r| matches!(r, &RecordType::A)) {
                    return None;
                }
                let resource = self.dns_resource_by_domain(&domain, |_| true)?;
                resource
                    .ip_stack
                    .supports_ipv4()
                    .then(|| (domain, resource.filters.clone()))
            })
            .collect()
    }

    pub(crate) fn resolved_v6_domains(&self) -> Vec<(DomainName, Vec<Filter>)> {
        self.resolved_domains()
            .filter_map(|(domain, records)| {
                if !records.iter().any(|r| matches!(r, &RecordType::AAAA)) {
                    return None;
                }
                let resource = self.dns_resource_by_domain(&domain, |_| true)?;
                resource
                    .ip_stack
                    .supports_ipv6()
                    .then(|| (domain, resource.filters.clone()))
            })
            .collect()
    }

    /// Returns the DNS servers that we expect connlib to use.
    ///
    /// If there are upstream Do53 servers configured in the portal, it should use those.
    /// If there are no custom servers defined, it should use the DoH servers specified in the portal.
    /// Otherwise it should use whatever was configured on the system prior to connlib starting.
    ///
    /// This purposely returns a `Vec` so we also assert the order!
    pub(crate) fn expected_dns_servers(
        &self,
        upstream_do53: &[UpstreamDo53],
        upstream_doh: &[UpstreamDoH],
    ) -> Vec<dns::Upstream> {
        if !upstream_do53.is_empty() {
            return upstream_do53
                .iter()
                .map(|u| dns::Upstream::Do53 {
                    server: SocketAddr::new(u.ip, 53),
                })
                .collect();
        }

        if !upstream_doh.is_empty() {
            return upstream_doh
                .iter()
                .map(|u| dns::Upstream::DoH {
                    server: u.url.clone(),
                })
                .collect();
        }

        self.system_dns_resolvers
            .iter()
            .map(|ip| dns::Upstream::Do53 {
                server: SocketAddr::new(*ip, 53),
            })
            .collect()
    }

    pub(crate) fn expected_routes(&self) -> BTreeSet<IpNetwork> {
        iter::empty()
            .chain(self.routes.iter().map(|(_, r)| *r))
            .chain(default_routes_v4())
            .chain(default_routes_v6())
            .collect()
    }

    pub(crate) fn cidr_resource_by_ip_and_proto(
        &self,
        ip: IpAddr,
        proto: Protocol,
    ) -> Option<ResourceId> {
        self.cidr_resource_by_ip(ip, |r| {
            FilterEngine::new(&r.filters).apply(Ok(proto)).is_ok()
        })
    }

    pub(crate) fn cidr_resource_by_ip(
        &self,
        ip: IpAddr,
        predicate: impl Fn(&CidrResource) -> bool,
    ) -> Option<ResourceId> {
        let r = self
            .resources
            .iter()
            .cloned()
            .filter_map(|r| r.into_cidr())
            .filter(|c| c.address.contains(ip))
            .sorted_by(|r1, r2| {
                let by_predicate = match (predicate(r1), predicate(r2)) {
                    (true, true) | (false, false) => Ordering::Equal,
                    (true, false) => Ordering::Greater,
                    (false, true) => Ordering::Less,
                };
                let by_netmask = r1.address.netmask().cmp(&r2.address.netmask());
                let by_id = r1.id.cmp(&r2.id);

                by_predicate.then(by_netmask).then(by_id)
            })
            .next_back()?;

        Some(r.id)
    }

    pub(crate) fn resolved_ip4_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
        at: Instant,
    ) -> Vec<Ipv4Addr> {
        self.resolved_ips_for_non_resources(global_dns_records, at)
            .filter_map(|ip| match ip {
                IpAddr::V4(v4) => Some(v4),
                IpAddr::V6(_) => None,
            })
            .collect()
    }

    pub(crate) fn resolved_ip6_for_non_resources(
        &self,
        global_dns_records: &DnsRecords,
        at: Instant,
    ) -> Vec<Ipv6Addr> {
        self.resolved_ips_for_non_resources(global_dns_records, at)
            .filter_map(|ip| match ip {
                IpAddr::V6(v6) => Some(v6),
                IpAddr::V4(_) => None,
            })
            .collect()
    }

    fn resolved_ips_for_non_resources<'a>(
        &'a self,
        global_dns_records: &'a DnsRecords,
        at: Instant,
    ) -> impl Iterator<Item = IpAddr> + 'a {
        self.dns_records
            .keys()
            .filter_map(move |domain| {
                self.dns_resource_by_domain(domain, |_| true)
                    .is_none()
                    .then_some(global_dns_records.domain_ips_iter(domain, at))
            })
            .flatten()
    }

    /// Returns the resource we will forward the DNS query for the given name to.
    ///
    /// DNS servers may be resources, in which case queries that need to be forwarded actually need to be encapsulated.
    pub(crate) fn dns_query_via_resource(
        &self,
        query: &DnsQuery,
        upstream_do53: &[UpstreamDo53],
    ) -> Option<ResourceId> {
        // Unless we are using upstream resolvers, DNS queries are never routed through the tunnel.
        if upstream_do53.is_empty() {
            return None;
        }

        // If we are querying a DNS resource, we will issue a connection intent to the DNS resource, not the CIDR resource.
        if self
            .dns_resource_by_domain(&query.domain, |_| true)
            .is_some()
            && matches!(
                query.r_type,
                RecordType::A | RecordType::AAAA | RecordType::PTR
            )
        {
            return None;
        }

        // TODO: Verify if we ever generate something that is not port 53 here.
        let server = match query.dns_server {
            dns::Upstream::Do53 { server } => server,
            dns::Upstream::DoH { .. } => return None,
        };

        let maybe_active_cidr_resource = self.cidr_resource_by_ip(server.ip(), |r| {
            let filter_engine = FilterEngine::new(&r.filters);

            filter_engine.apply(Ok(Protocol::Udp(53))).is_ok()
                && filter_engine.apply(Ok(Protocol::Tcp(53))).is_ok()
        });
        let maybe_active_internet_resource = self.active_internet_resource();

        maybe_active_cidr_resource.or(maybe_active_internet_resource)
    }

    pub(crate) fn is_site_specific_dns_query(&self, query: &DnsQuery) -> Option<ResourceId> {
        if !matches!(query.r_type, RecordType::SRV | RecordType::TXT) {
            return None;
        }

        Some(self.dns_resource_by_domain(&query.domain, |_| true)?.id)
    }

    pub(crate) fn all_resource_ids(&self) -> Vec<ResourceId> {
        self.resources.iter().map(|r| r.id()).collect()
    }

    pub(crate) fn has_resource(&self, resource_id: ResourceId) -> bool {
        self.resources.iter().any(|r| r.id() == resource_id)
    }

    pub(crate) fn all_resources(&self) -> Vec<Resource> {
        self.resources.clone()
    }

    fn internet_resource(&self) -> Option<ResourceId> {
        self.resources.iter().find_map(|r| match r {
            Resource::Dns(_)
            | Resource::Cidr(_)
            | Resource::StaticDevicePool(_)
            | Resource::DynamicDevicePool(_) => None,
            Resource::Internet(internet_resource) => Some(internet_resource.id),
        })
    }

    pub(crate) fn system_dns_resolvers(&self) -> Vec<IpAddr> {
        self.system_dns_resolvers.clone()
    }

    pub(crate) fn set_system_dns_resolvers(&mut self, servers: &Vec<IpAddr>) {
        self.system_dns_resolvers.clone_from(servers);
    }

    pub(crate) fn has_tcp_connection(
        &self,
        src: IpAddr,
        dst: Destination,
        sport: SPort,
        dport: DPort,
    ) -> bool {
        self.expected_tcp_connections
            .contains_key(&(src, dst, sport, dport))
    }

    pub(crate) fn tcp_connection_tuple_to_resource(
        &self,
        resource: ResourceId,
    ) -> Option<(SPort, DPort)> {
        self.expected_tcp_connections
            .iter()
            .find_map(|((_, _, sport, dport), res)| (resource == *res).then_some((*sport, *dport)))
    }

    /// Checks whether the given instant falls within a time period T .. T + ICE_TIMEOUT where T marks every point in time where we reset all our connections.
    pub(crate) fn has_reset_connections_within_ice_timeout(&self, at: Instant) -> bool {
        let ice_timeout = Duration::from_millis(22_000); // TODO: Figure out why this isn't exactly ICE timeout but longer?

        self.connection_resets
            .iter()
            .copied()
            .any(|t| (t..t + ice_timeout).contains(&at))
    }

    pub(crate) fn clear_packets(&mut self) {
        self.expected_gateway_icmp_handshakes.clear();
        self.expected_client_icmp_handshakes.clear();
        self.expected_gateway_udp_handshakes.clear();
        self.expected_client_udp_handshakes.clear();
        self.expected_udp_dns_handshakes.clear();
        self.expected_tcp_dns_handshakes.clear();
        self.expected_tcp_connections.clear();
    }

    pub(crate) fn any_resource_allows_tcp_on_port(
        &self,
        destination: &Destination,
        dport: u16,
    ) -> bool {
        self.any_resource_allows(destination, |filters| tcp_filter_allows(filters, dport))
    }

    pub(crate) fn any_resource_allows_icmp(&self, destination: &Destination) -> bool {
        self.any_resource_allows(destination, icmp_filter_allows)
    }

    pub(crate) fn any_resource_allows_udp_on_port(
        &self,
        destination: &Destination,
        dport: u16,
    ) -> bool {
        self.any_resource_allows(destination, |filters| udp_filter_allows(filters, dport))
    }

    fn any_resource_allows(
        &self,
        destination: &Destination,
        filter_allows: impl Fn(&[Filter]) -> bool,
    ) -> bool {
        let matching_resources = self.resources_matching_destination(destination);

        match matching_resources.as_slice() {
            [] => self.internet_resource().is_some(),
            resources => resources.iter().any(|r| match r {
                Resource::Cidr(cidr) => filter_allows(&cidr.filters),
                Resource::Dns(dns) => filter_allows(&dns.filters),
                Resource::Internet(_)
                | Resource::StaticDevicePool(_)
                | Resource::DynamicDevicePool(_) => unreachable!(),
            }),
        }
    }

    fn resources_matching_destination(&self, destination: &Destination) -> Vec<&Resource> {
        match destination {
            Destination::IpAddr(ip) => self
                .resources
                .iter()
                .filter(|r| matches!(r, Resource::Cidr(cidr) if cidr.address.contains(*ip)))
                .collect(),
            Destination::DomainName { name, .. } => self
                .resources
                .iter()
                .filter(|r| {
                    matches!(r, Resource::Dns(dns) if is_subdomain(&name.to_string(), &dns.address))
                })
                .collect(),
        }
    }
}

/// Checks if a set of [`Filter`]s allows the given TCP port.
///
/// This purposely doesn't use [`FilterEngine`] because we are in the reference implementation here.
fn tcp_filter_allows(filters: &[Filter], dport: u16) -> bool {
    filters.is_empty()
        || filters.iter().any(|f| {
            matches!(
                f,
                Filter::Tcp(range)
                    if range.port_range_start <= dport && dport <= range.port_range_end
            )
        })
}

/// Checks if a set of [`Filter`]s allows ICMP traffic.
///
/// This purposely doesn't use [`FilterEngine`] because we are in the reference implementation here.
fn icmp_filter_allows(filters: &[Filter]) -> bool {
    filters.is_empty() || filters.iter().any(|f| matches!(f, Filter::Icmp))
}

/// Checks if a set of [`Filter`]s allows the given UDP port.
///
/// This purposely doesn't use [`FilterEngine`] because we are in the reference implementation here.
fn udp_filter_allows(filters: &[Filter], dport: u16) -> bool {
    filters.is_empty()
        || filters.iter().any(|f| {
            matches!(
                f,
                Filter::Udp(range)
                    if range.port_range_start <= dport && dport <= range.port_range_end
            )
        })
}

// This function only works on the tests because we are limited to resources with a single wildcard at the beginning of the resource.
// This limitation doesn't exists in production.
fn is_subdomain(name: &str, record: &str) -> bool {
    if name == record {
        return true;
    }
    let Some((first, end)) = record.split_once('.') else {
        return false;
    };
    match first {
        "**" => name.ends_with(end) && name.strip_suffix(end).is_some_and(|n| n.ends_with('.')),
        "*" => {
            name.ends_with(end)
                && name
                    .strip_suffix(end)
                    .is_some_and(|n| n.ends_with('.') && n.matches('.').count() == 1)
        }
        _ => false,
    }
}

pub(crate) fn ref_client_host(
    id: ClientId,
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    system_dns: impl Strategy<Value = Vec<IpAddr>>,
) -> impl Strategy<Value = Host<RefClient>> {
    host(
        any_ip_stack(),
        listening_port(),
        ref_client(id, tunnel_ip4s, tunnel_ip6s, system_dns),
        latency(250), // TODO: Increase with #6062.
    )
}

fn ref_client(
    id: ClientId,
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    system_dns: impl Strategy<Value = Vec<IpAddr>>,
) -> impl Strategy<Value = RefClient> {
    (
        tunnel_ip4s,
        tunnel_ip6s,
        system_dns,
        any::<bool>(),
        private_key(),
    )
        .prop_map(
            move |(tunnel_ip4, tunnel_ip6, system_dns_resolvers, internet_resource_active, key)| {
                RefClient {
                    id,
                    key,
                    tunnel_ip4,
                    tunnel_ip6,
                    system_dns_resolvers,
                    internet_resource_active,
                    dns_records: Default::default(),
                    connected_cidr_resources: Default::default(),
                    connected_dns_resources: Default::default(),
                    connected_internet_resource: Default::default(),
                    expected_gateway_icmp_handshakes: Default::default(),
                    expected_client_icmp_handshakes: Default::default(),
                    expected_gateway_udp_handshakes: Default::default(),
                    expected_client_udp_handshakes: Default::default(),
                    expected_tcp_connections: Default::default(),
                    expected_udp_dns_handshakes: Default::default(),
                    expected_tcp_dns_handshakes: Default::default(),
                    resources: Default::default(),
                    routes: Default::default(),
                    site_status: Default::default(),
                    connection_resets: Default::default(),
                }
            },
        )
}

fn listening_port() -> impl Strategy<Value = u16> {
    prop_oneof![
        Just(52625),
        Just(3478), // Make sure connlib works even if a NAT is re-mapping our public port to a relay port.
        any::<NonZeroU16>().prop_map(|p| p.get()),
    ]
}

fn default_routes_v4() -> Vec<IpNetwork> {
    vec![
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 64, 0, 0), 11).unwrap()),
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 96, 0, 0), 11).unwrap()),
        IpNetwork::V4(Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24).unwrap()),
    ]
}

fn default_routes_v6() -> Vec<IpNetwork> {
    vec![
        IpNetwork::V6(
            Ipv6Network::new(Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0), 107).unwrap(),
        ),
        IpNetwork::V6(
            Ipv6Network::new(
                Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0, 0, 0, 0),
                107,
            )
            .unwrap(),
        ),
        IpNetwork::V6(
            Ipv6Network::new(
                Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0),
                120,
            )
            .unwrap(),
        ),
    ]
}
