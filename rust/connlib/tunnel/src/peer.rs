use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::{Duration, Instant};

use bimap::BiMap;
use chrono::{DateTime, Utc};
use connlib_shared::messages::gateway::{ResolvedResourceDescriptionDns, ResourceDescription};
use connlib_shared::messages::{
    gateway::Filter, gateway::Filters, ClientId, GatewayId, ResourceId,
};
use connlib_shared::DomainName;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::ip::IpNextHeaderProtocols;
use ip_packet::{IpPacket, MutableIpPacket};
use itertools::Itertools;
use rangemap::RangeInclusiveSet;

use crate::client::IpProvider;
use crate::utils::network_contains_network;
use crate::GatewayEvent;

use nat_table::NatTable;

mod nat_table;

#[derive(Debug)]
enum FilterEngine {
    PermitAll,
    PermitSome(AllowRules),
}

#[derive(Debug)]
struct AllowRules {
    udp: RangeInclusiveSet<u16>,
    tcp: RangeInclusiveSet<u16>,
    icmp: bool,
}

impl FilterEngine {
    fn empty() -> FilterEngine {
        Self::PermitSome(AllowRules::new())
    }

    fn is_allowed(&self, packet: &IpPacket) -> bool {
        match self {
            FilterEngine::PermitAll => true,
            FilterEngine::PermitSome(filter_engine) => filter_engine.is_allowed(packet),
        }
    }

    fn permit_all(&mut self) {
        *self = FilterEngine::PermitAll;
    }

    fn add_filters<'a>(&mut self, filters: impl IntoIterator<Item = &'a Filter>) {
        match self {
            FilterEngine::PermitAll => {}
            FilterEngine::PermitSome(filter_engine) => filter_engine.add_filters(filters),
        }
    }
}

impl AllowRules {
    fn new() -> AllowRules {
        AllowRules {
            udp: RangeInclusiveSet::new(),
            tcp: RangeInclusiveSet::new(),
            icmp: false,
        }
    }

    fn is_allowed(&self, packet: &IpPacket) -> bool {
        match packet.next_header() {
            // Note: possible optimization here
            // if we want to get the port here, and we assume correct formatting
            // we can do packet.payload()[2..=3] (for UDP and TCP bytes 2 and 3 are the port)
            // but it might be a bit harder to read
            IpNextHeaderProtocols::Tcp => packet
                .as_tcp()
                .is_some_and(|p| self.tcp.contains(&p.get_destination())),
            IpNextHeaderProtocols::Udp => packet
                .as_udp()
                .is_some_and(|p| self.udp.contains(&p.get_destination())),
            IpNextHeaderProtocols::Icmp | IpNextHeaderProtocols::Icmpv6 => self.icmp,
            _ => false,
        }
    }

    fn add_filters<'a>(&mut self, filters: impl IntoIterator<Item = &'a Filter>) {
        for filter in filters {
            match filter {
                Filter::Udp(range) => {
                    self.udp
                        .insert(range.port_range_start..=range.port_range_end);
                }
                Filter::Tcp(range) => {
                    self.tcp
                        .insert(range.port_range_start..=range.port_range_end);
                }
                Filter::Icmp => {
                    self.icmp = true;
                }
            }
        }
    }
}

/// The state of one gateway on a client.
pub(crate) struct GatewayOnClient {
    id: GatewayId,
    pub allowed_ips: IpNetworkTable<HashSet<ResourceId>>,

    pub translations: BiMap<IpAddr, IpAddr>,
}

impl GatewayOnClient {
    pub(crate) fn insert_id(&mut self, ip: &IpNetwork, id: &ResourceId) {
        if let Some(resources) = self.allowed_ips.exact_match_mut(*ip) {
            resources.insert(*id);
        } else {
            self.allowed_ips.insert(*ip, HashSet::from([*id]));
        }
    }
}

impl GatewayOnClient {
    pub(crate) fn new(
        id: GatewayId,
        ips: &[IpNetwork],
        resource: HashSet<ResourceId>,
    ) -> GatewayOnClient {
        let mut allowed_ips = IpNetworkTable::new();
        for ip in ips {
            allowed_ips.insert(*ip, resource.clone());
        }

        GatewayOnClient {
            id,
            allowed_ips,
            translations: Default::default(),
        }
    }

    #[tracing::instrument(name = "translation", level = "debug", skip_all, fields(gateway = %self.id))]
    pub fn get_or_assign_translation(
        &mut self,
        real_ip: &IpAddr,
        ip_provider: &mut IpProvider,
    ) -> Option<IpAddr> {
        if let Some(proxy_ip) = self.translations.get_by_right(real_ip) {
            tracing::debug!("Existing translation: {real_ip} -> {proxy_ip}");

            return Some(*proxy_ip);
        }

        let proxy_ip = ip_provider.get_proxy_ip_for(real_ip)?;

        tracing::debug!("New translation: {real_ip} -> {proxy_ip}");

        self.translations.insert(proxy_ip, *real_ip);
        Some(proxy_ip)
    }
}

impl ClientOnGateway {
    pub(crate) fn new(id: ClientId, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> ClientOnGateway {
        ClientOnGateway {
            id,
            ipv4,
            ipv6,
            resources: HashMap::new(),
            filters: IpNetworkTable::new(),
            permanent_translations: Default::default(),
            nat_table: Default::default(),
            buffered_events: Default::default(),
        }
    }

    /// A client is only allowed to send packets from their (portal-assigned) tunnel IPs.
    ///
    /// Failure to enforce this would allow one client to send traffic masquarading as a different client.
    fn allowed_ips(&self) -> [IpAddr; 2] {
        [IpAddr::from(self.ipv4), IpAddr::from(self.ipv6)]
    }

    pub(crate) fn refresh_translation(
        &mut self,
        name: DomainName,
        resource_id: ResourceId,
        resolved_ips: Vec<IpAddr>,
        now: Instant,
    ) {
        let Some(resource) = self.resources.get_mut(&resource_id) else {
            return;
        };

        let old_ips: HashSet<&IpAddr> =
            HashSet::from_iter(self.permanent_translations.values().filter_map(|state| {
                (state.name == name && state.resource_id == resource_id)
                    .then_some(&state.resolved_ip)
            }));
        let new_ips: HashSet<&IpAddr> = HashSet::from_iter(resolved_ips.iter());
        if old_ips == new_ips {
            return;
        }

        for r in resource
            .iter_mut()
            .filter(|ResourceOnGateway { domain, .. }| *domain == Some(name.clone()))
        {
            r.ips = resolved_ips.iter().copied().map_into().collect_vec();
        }

        let proxy_ips = self
            .permanent_translations
            .iter()
            .filter_map(|(k, state)| {
                (state.name == name && state.resource_id == resource_id).then_some(*k)
            })
            .collect_vec();

        self.assign_translations(name, resource_id, &resolved_ips, proxy_ips, now);
        self.recalculate_filters();
    }

    fn assign_translations(
        &mut self,
        name: DomainName,
        resource_id: ResourceId,
        mapped_ips: &[IpAddr],
        proxy_ips: Vec<IpAddr>,
        now: Instant,
    ) {
        let mapped_ipv4 = mapped_ipv4(mapped_ips);
        let mapped_ipv6 = mapped_ipv6(mapped_ips);

        let ipv4_maps = proxy_ips
            .iter()
            .filter(|ip| ip.is_ipv4())
            .zip(mapped_ipv4.into_iter().cycle());

        let ipv6_maps = proxy_ips
            .iter()
            .filter(|ip| ip.is_ipv6())
            .zip(mapped_ipv6.into_iter().cycle());

        let ip_maps = ipv4_maps.chain(ipv6_maps);

        for (proxy_ip, real_ip) in ip_maps {
            tracing::debug!(%proxy_ip, %real_ip, %name, "Assigned translation");

            self.permanent_translations.insert(
                *proxy_ip,
                TranslationState::new(resource_id, name.clone(), real_ip, now),
            );
        }
    }

    pub(crate) fn assign_proxies(
        &mut self,
        resource: &ResourceDescription<ResolvedResourceDescriptionDns>,
        domain_ips: Option<(DomainName, Vec<IpAddr>)>,
        now: Instant,
    ) -> connlib_shared::Result<()> {
        match (resource, domain_ips) {
            (ResourceDescription::Dns(r), Some((name, resource_ips))) => {
                if resource_ips.is_empty() {
                    tracing::debug!("Client hasn't sent us any proxy IPs, skipping IP translation");
                    return Ok(());
                }

                self.assign_translations(name, r.id, &r.addresses, resource_ips, now);
            }
            (ResourceDescription::Cidr(_), None) => {}
            _ => {
                return Err(connlib_shared::Error::InvalidResource);
            }
        }
        Ok(())
    }

    pub(crate) fn is_emptied(&self) -> bool {
        self.resources.is_empty()
    }

    pub(crate) fn expire_resources(&mut self, now: DateTime<Utc>) {
        for resource in self.resources.values_mut() {
            resource.retain(|r| !r.expires_at.is_some_and(|e| e <= now));
        }

        self.resources.retain(|_, r| !r.is_empty());
        self.recalculate_filters();
    }

    pub(crate) fn poll_event(&mut self) -> Option<GatewayEvent> {
        self.buffered_events.pop_front()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        let expired_translations = self
            .permanent_translations
            .iter()
            .filter(|(_, state)| state.no_response_in_30s(now));

        let mut for_refresh = HashSet::new();

        for (proxy_ip, expired_state) in expired_translations {
            let domain = &expired_state.name;
            let resource_id = expired_state.resource_id;
            let resolved_ip = expired_state.resolved_ip;

            // Only refresh DNS for a domain if all of the resolved IPs stop responding in order to not kill existing connections.
            if self
                .permanent_translations
                .values()
                .filter(|state| state.resource_id == resource_id && state.name == domain)
                .all(|state| state.no_response_in_30s(now))
            {
                tracing::debug!(%domain, conn_id = %self.id, %resource_id, %resolved_ip, %proxy_ip, "Refreshing DNS");

                for_refresh.insert((expired_state.name.clone(), expired_state.resource_id));
            }
        }

        for (name, resource_id) in for_refresh {
            self.buffered_events.push_back(GatewayEvent::RefreshDns {
                name,
                conn_id: self.id,
                resource_id,
            });
        }

        let mut dead_ips = BTreeMap::<DomainName, BTreeSet<IpAddr>>::new();

        for state in self.permanent_translations.values() {
            // Check each state individually for whether it is being used but dead.
            if state.is_used(now) && state.is_dead(now) {
                dead_ips
                    .entry(state.name.clone())
                    .or_default()
                    .insert(state.resolved_ip);
            }
        }

        if !dead_ips.is_empty() {
            tracing::warn!(
                ?dead_ips,
                "Dead IPs detected (never received any traffic); check your DNS configuration"
            );
        }

        self.nat_table.handle_timeout(now);
    }

    pub(crate) fn remove_resource(&mut self, resource: &ResourceId) {
        self.resources.remove(resource);
        self.recalculate_filters();
    }

    pub(crate) fn add_resource(
        &mut self,
        ips: Vec<IpNetwork>,
        resource: ResourceId,
        filters: Filters,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<DomainName>,
    ) {
        self.resources
            .entry(resource)
            .or_default()
            .push(ResourceOnGateway {
                domain,
                ips,
                filters,
                // Each resource subdomain can expire individually so it's worth keeping a list
                expires_at,
            });
        self.recalculate_filters();
    }

    // Note: we only allow updating filters and names
    // but names updates have no effect on the gateway
    pub(crate) fn update_resource(&mut self, resource: &ResourceDescription) {
        let Some(old_resource) = self.resources.get_mut(&resource.id()) else {
            return;
        };
        for r in old_resource {
            r.filters = resource.filters();
        }

        self.recalculate_filters();
    }

    // Call this after any resources change
    //
    // This recalculate the ip-table rules, this allows us to remove and add resources and keep the allow-list correct
    // in case that 2 or more resources have overlapping rules.
    fn recalculate_filters(&mut self) {
        self.filters = IpNetworkTable::new();
        for resource in self.resources.values().flatten() {
            for ip in &resource.ips {
                let mut filter_engine = FilterEngine::empty();
                let filters = self.resources.values().flatten().filter_map(|r| {
                    r.ips
                        .iter()
                        .any(|r_ip| network_contains_network(*r_ip, *ip))
                        .then_some(&r.filters)
                });

                // Empty filters means permit all
                if filters.clone().any(|f| f.is_empty()) {
                    filter_engine.permit_all();
                }

                filter_engine.add_filters(filters.flatten());
                self.filters.insert(*ip, filter_engine);
            }
        }
    }

    fn transform_network_to_tun<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
        now: Instant,
    ) -> Result<MutableIpPacket<'a>, connlib_shared::Error> {
        let Some(state) = self.permanent_translations.get_mut(&packet.destination()) else {
            return Ok(packet);
        };

        let (source_protocol, real_ip) =
            self.nat_table
                .translate_outgoing(packet.as_immutable(), state.resolved_ip, now)?;

        let mut packet = packet
            .translate_destination(self.ipv4, self.ipv6, real_ip)
            .ok_or(connlib_shared::Error::FailedTranslation)?;
        packet.set_source_protocol(source_protocol.value());
        packet.update_checksum();

        state.on_outgoing_traffic(now);

        Ok(packet)
    }

    pub fn decapsulate<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
        now: Instant,
    ) -> Result<MutableIpPacket<'a>, connlib_shared::Error> {
        self.ensure_allowed_src(&packet)?;

        let packet = self.transform_network_to_tun(packet, now)?;

        self.ensure_allowed_dst(&packet)?;

        Ok(packet)
    }

    pub fn encapsulate<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
        now: Instant,
    ) -> Result<Option<MutableIpPacket<'a>>, connlib_shared::Error> {
        let Some((proto, ip)) = self
            .nat_table
            .translate_incoming(packet.as_immutable(), now)?
        else {
            return Ok(Some(packet));
        };

        let Some(mut packet) = packet.translate_source(self.ipv4, self.ipv6, ip) else {
            return Ok(None);
        };

        self.permanent_translations
            .get_mut(&ip)
            .expect("inconsistent state")
            .on_incoming_traffic(now);

        packet.set_destination_protocol(proto.value());
        packet.update_checksum();

        Ok(Some(packet))
    }

    fn ensure_allowed_src(
        &self,
        packet: &MutableIpPacket<'_>,
    ) -> Result<(), connlib_shared::Error> {
        if !self.allowed_ips().contains(&packet.source()) {
            return Err(connlib_shared::Error::UnallowedPacket {
                src: packet.source(),
                allowed_ips: HashSet::from(self.allowed_ips()),
            });
        }

        Ok(())
    }

    /// Check if an incoming packet arriving over the network is ok to be forwarded to the TUN device.
    fn ensure_allowed_dst(
        &self,
        packet: &MutableIpPacket<'_>,
    ) -> Result<(), connlib_shared::Error> {
        let dst = packet.destination();
        if !self
            .filters
            .longest_match(dst)
            .is_some_and(|(_, filter)| filter.is_allowed(&packet.to_immutable()))
        {
            tracing::warn!(%dst, "unallowed packet");
            return Err(connlib_shared::Error::InvalidDst);
        };

        Ok(())
    }

    pub fn id(&self) -> ClientId {
        self.id
    }
}

impl GatewayOnClient {
    /// Transform a packet that arrived via the network for the TUN device.
    pub(crate) fn transform_network_to_tun<'a>(
        &mut self,
        mut pkt: MutableIpPacket<'a>,
    ) -> Result<MutableIpPacket<'a>, connlib_shared::Error> {
        let addr = pkt.source();
        let src = *self.translations.get_by_right(&addr).unwrap_or(&addr);

        if self.allowed_ips.longest_match(src).is_none() {
            return Err(connlib_shared::Error::UnallowedPacket {
                src,

                allowed_ips: self
                    .allowed_ips
                    .iter()
                    .map(|(ip, _)| ip.network_address())
                    .collect(),
            });
        }

        pkt.set_src(src);
        pkt.update_checksum();

        Ok(pkt)
    }

    /// Transform a packet that arrvied on the TUN device for the network.
    pub(crate) fn transform_tun_to_network<'a>(
        &mut self,
        mut packet: MutableIpPacket<'a>,
    ) -> MutableIpPacket<'a> {
        if let Some(translated_ip) = self.translations.get_by_left(&packet.destination()) {
            packet.set_dst(*translated_ip);
            packet.update_checksum();
        }

        packet
    }

    pub fn id(&self) -> GatewayId {
        self.id
    }
}

#[derive(Debug)]
struct ResourceOnGateway {
    ips: Vec<IpNetwork>,
    filters: Filters,
    expires_at: Option<DateTime<Utc>>,
    domain: Option<DomainName>,
}

// Current state of a translation for a given proxy ip
#[derive(Debug)]
struct TranslationState {
    /// Which (DNS) resource we belong to.
    resource_id: ResourceId,
    /// The concrete domain we have resolved (could be a sub-domain of a `*` or `?` resource).
    name: DomainName,
    /// The IP we have resolved for the domain.
    resolved_ip: IpAddr,

    /// When we've last received a packet from the resolved IP.
    ///
    /// Initially set to `created_at`.
    last_incoming: Instant,
    /// When we've sent the first packet to the resolved IP.
    ///
    /// Initially set to `created_at`.
    first_outgoing: Instant,
    /// When we've last sent a packet to the resolved IP.
    ///
    /// Initially set to `created_at`.
    last_outgoing: Instant,

    /// When this translation state was created.
    created_at: Instant,
}

impl TranslationState {
    fn new(
        resource_id: ResourceId,
        name: DomainName,
        resolved_ip: IpAddr,
        created_at: Instant,
    ) -> Self {
        Self {
            resource_id,
            name,
            resolved_ip,
            last_incoming: created_at,
            first_outgoing: created_at,
            last_outgoing: created_at,
            created_at,
        }
    }

    /// We define a [`TranslationState`] as dead if we have seen outgoing traffic that is at least 10s old and _never_ received incoming traffic.
    fn is_dead(&self, now: Instant) -> bool {
        let sent_at_least_one_packet_10s_ago =
            now.duration_since(self.first_outgoing) >= Duration::from_secs(10);
        let received_no_packets = self.last_incoming == self.created_at;

        sent_at_least_one_packet_10s_ago && received_no_packets
    }

    /// We define a [`TranslationState`] as used if we have seen outgoing traffic in the last 10s.
    fn is_used(&self, now: Instant) -> bool {
        now.duration_since(self.last_outgoing) <= Duration::from_secs(10)
    }

    fn no_response_in_30s(&self, now: Instant) -> bool {
        now.duration_since(self.last_incoming) >= Duration::from_secs(30)
    }

    fn on_incoming_traffic(&mut self, now: Instant) {
        self.last_incoming = now;
    }

    fn on_outgoing_traffic(&mut self, now: Instant) {
        self.last_outgoing = now;

        if self.first_outgoing > self.created_at {
            return;
        }
        self.first_outgoing = now;
    }
}

/// The state of one client on a gateway.
pub struct ClientOnGateway {
    id: ClientId,
    ipv4: Ipv4Addr,
    ipv6: Ipv6Addr,
    resources: HashMap<ResourceId, Vec<ResourceOnGateway>>,
    filters: IpNetworkTable<FilterEngine>,
    permanent_translations: HashMap<IpAddr, TranslationState>,
    nat_table: NatTable,
    buffered_events: VecDeque<GatewayEvent>,
}

#[cfg(test)]
mod tests {
    use std::{
        net::{IpAddr, Ipv4Addr, Ipv6Addr},
        time::{Duration, Instant},
    };

    use chrono::Utc;
    use connlib_shared::messages::{
        gateway::{Filter, PortRange},
        ClientId, ResourceId,
    };
    use ip_network::Ipv4Network;

    use super::{ClientOnGateway, TranslationState};

    #[test]
    fn gateway_filters_expire_individually() {
        let mut peer = ClientOnGateway::new(client_id(), source_v4_addr(), source_v6_addr());
        let now = Utc::now();
        let then = now + Duration::from_secs(10);
        let after_then = then + Duration::from_secs(10);
        peer.add_resource(
            vec![cidr_v4_resource().into()],
            resource_id(),
            vec![Filter::Tcp(PortRange {
                port_range_start: 20,
                port_range_end: 100,
            })],
            Some(then),
            None,
        );

        peer.add_resource(
            vec![cidr_v4_resource().into()],
            resource2_id(),
            vec![Filter::Udp(PortRange {
                port_range_start: 20,
                port_range_end: 100,
            })],
            Some(after_then),
            None,
        );

        let tcp_packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap(),
            5401,
            80,
            vec![0; 100],
        );

        let udp_packet = ip_packet::make::udp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap(),
            5401,
            80,
            vec![0; 100],
        );

        peer.expire_resources(now);

        assert!(peer.ensure_allowed_dst(&tcp_packet).is_ok());
        assert!(peer.ensure_allowed_dst(&udp_packet).is_ok());

        peer.expire_resources(then);

        assert!(matches!(
            peer.ensure_allowed_dst(&tcp_packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
        assert!(peer.ensure_allowed_dst(&udp_packet).is_ok());

        peer.expire_resources(after_then);

        assert!(matches!(
            peer.ensure_allowed_dst(&tcp_packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
        assert!(matches!(
            peer.ensure_allowed_dst(&udp_packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
    }

    #[test]
    fn initial_translation_state_is_not_dead() {
        let now = Instant::now();
        let state = TranslationState::new(
            ResourceId::random(),
            "example.com".parse().unwrap(),
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            now,
        );

        assert!(!state.is_dead(now))
    }

    #[test]
    fn initial_translation_state_is_not_active_if_last_packet_was_more_than_30s_ago() {
        let mut now = Instant::now();
        let mut state = TranslationState::new(
            ResourceId::random(),
            "example.com".parse().unwrap(),
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            now,
        );

        now += Duration::from_secs(5);
        state.on_outgoing_traffic(now);

        now += Duration::from_secs(31);

        assert!(!state.is_used(now))
    }

    #[test]
    fn initial_translation_state_is_active_if_last_packet_was_1s_ago() {
        let mut now = Instant::now();
        let mut state = TranslationState::new(
            ResourceId::random(),
            "example.com".parse().unwrap(),
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            now,
        );

        now += Duration::from_secs(5);
        state.on_outgoing_traffic(now);

        now += Duration::from_secs(1);

        assert!(state.is_used(now))
    }

    #[test]
    fn is_only_dead_if_initial_outgoing_traffic_is_at_least_10s_old() {
        let mut now = Instant::now();
        let mut state = TranslationState::new(
            ResourceId::random(),
            "example.com".parse().unwrap(),
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            now,
        );

        now += Duration::from_secs(1);
        state.on_outgoing_traffic(now);

        assert!(
            !state.is_dead(now),
            "1 second after outgoing traffic is not yet dead"
        );

        now += Duration::from_secs(9);
        state.on_outgoing_traffic(now);
        assert!(
            !state.is_dead(now),
            "9 second after outgoing traffic is not yet dead"
        );

        now += Duration::from_secs(1);
        state.on_outgoing_traffic(now);
        assert!(
            state.is_dead(now),
            "10 second after outgoing traffic is not yet dead"
        );
    }

    fn source_v4_addr() -> Ipv4Addr {
        "100.64.0.1".parse().unwrap()
    }

    fn source_v6_addr() -> Ipv6Addr {
        "fd00:2021:1111::1".parse().unwrap()
    }

    fn cidr_v4_resource() -> Ipv4Network {
        "10.0.0.0/24".parse().unwrap()
    }

    fn resource_id() -> ResourceId {
        "9d4b79f6-1db7-4cb3-a077-712102204d73".parse().unwrap()
    }

    fn resource2_id() -> ResourceId {
        "ed29c148-2acf-4ceb-8db5-d796c2671631".parse().unwrap()
    }

    fn client_id() -> ClientId {
        "9d4b79f6-1db7-4cb3-a077-712102204d73".parse().unwrap()
    }
}

#[cfg(all(test, feature = "proptest"))]
mod proptests {
    use std::{
        net::{Ipv4Addr, Ipv6Addr},
        ops::RangeInclusive,
    };

    use super::*;
    use connlib_shared::{messages::gateway::PortRange, proptest::*};
    use ip_network::{Ipv4Network, Ipv6Network};
    use ip_packet::make::{icmp_request_packet, tcp_packet, udp_packet};
    use itertools::Itertools;
    use proptest::{
        arbitrary::any,
        collection, prop_oneof,
        sample::select,
        strategy::{Just, Strategy},
    };
    use test_strategy::Arbitrary;

    #[test_strategy::proptest()]
    fn gateway_accepts_allowed_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(vec![resource_id(); 5])] resources_id: Vec<ResourceId>,
        #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
        #[strategy(cidr_with_host())] config: (IpNetwork, IpAddr),
        #[strategy(collection::vec(filters_with_allowed_protocol(), 1..=5))] protocol_config: Vec<
            (Filters, Protocol),
        >,
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (resource_addr, dest) = config;
        let src = if dest.is_ipv4() {
            src_v4.into()
        } else {
            src_v6.into()
        };
        let mut filters = protocol_config.iter();
        // This test could be extended to test multiple src
        let mut peer = ClientOnGateway::new(client_id, src_v4, src_v6);
        let mut resource_addr = Some(resource_addr);
        let mut resources = 0;

        loop {
            let Some(addr) = resource_addr else {
                break;
            };
            let Some((filter, _)) = filters.next() else {
                break;
            };
            peer.add_resource(
                vec![addr],
                resources_id[resources],
                filter.clone(),
                None,
                None,
            );
            resources += 1;
            resource_addr = supernet(addr);
        }

        for (_, protocol) in &protocol_config[0..resources] {
            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(src, dest, sport, *dport, payload.clone()),
                Protocol::Udp { dport } => udp_packet(src, dest, sport, *dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
            };
            assert!(peer.ensure_allowed_dst(&packet).is_ok());
        }
    }

    #[test_strategy::proptest()]
    fn gateway_accepts_allowed_packet_multiple_ips_resource(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(resource_id())] resource_id: ResourceId,
        #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
        #[strategy(collection::vec(cidr_with_host(), 1..=5))] config: Vec<(IpNetwork, IpAddr)>,
        #[strategy(filters_with_allowed_protocol())] protocol_config: (Filters, Protocol),
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (resource_addr, dest): (Vec<_>, Vec<_>) = config.into_iter().unzip();
        let (filters, protocol) = protocol_config;
        let mut peer = ClientOnGateway::new(client_id, src_v4, src_v6);

        peer.add_resource(resource_addr, resource_id, filters, None, None);

        for dest in dest {
            let src = if dest.is_ipv4() {
                src_v4.into()
            } else {
                src_v6.into()
            };
            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
            };
            assert!(peer.ensure_allowed_dst(&packet).is_ok());
        }
    }

    #[test_strategy::proptest()]
    fn gateway_accepts_allowed_packet_multiple_ips_resource_multiple_adds(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(resource_id())] resource_id: ResourceId,
        #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
        #[strategy(collection::vec(cidr_with_host(), 1..=5))] config_res_1: Vec<(
            IpNetwork,
            IpAddr,
        )>,
        #[strategy(collection::vec(cidr_with_host(), 1..=5))] config_res_2: Vec<(
            IpNetwork,
            IpAddr,
        )>,
        #[strategy(filters_with_allowed_protocol())] protocol_config: (Filters, Protocol),
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (resource_addr_1, dest_1): (Vec<_>, Vec<_>) = config_res_1.into_iter().unzip();
        let (resource_addr_2, dest_2): (Vec<_>, Vec<_>) = config_res_2.into_iter().unzip();
        let (filters, protocol) = protocol_config;
        let mut peer = ClientOnGateway::new(client_id, src_v4, src_v6);

        peer.add_resource(resource_addr_1, resource_id, filters.clone(), None, None);
        peer.add_resource(resource_addr_2, resource_id, filters, None, None);

        for dest in dest_1 {
            let src = if dest.is_ipv4() {
                src_v4.into()
            } else {
                src_v6.into()
            };
            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
            };
            assert!(peer.ensure_allowed_dst(&packet).is_ok());
        }

        for dest in dest_2 {
            let src = if dest.is_ipv4() {
                src_v4.into()
            } else {
                src_v6.into()
            };
            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
            };
            assert!(peer.ensure_allowed_dst(&packet).is_ok());
        }
    }

    #[test_strategy::proptest()]
    fn gateway_accepts_different_resources_with_same_ip_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(vec![resource_id(); 10])] resources_ids: Vec<ResourceId>,
        #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
        #[strategy(cidr_with_host())] config: (IpNetwork, IpAddr),
        #[strategy(collection::vec(filters_with_allowed_protocol(), 1..=10))] protocol_config: Vec<
            (Filters, Protocol),
        >,
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (resource_addr, dest) = config;
        let src = if dest.is_ipv4() {
            src_v4.into()
        } else {
            src_v6.into()
        };
        let mut peer = ClientOnGateway::new(client_id, src_v4, src_v6);
        let mut resources_ids = resources_ids.iter();
        for (filters, _) in &protocol_config {
            // This test could be extended to test multiple src
            peer.add_resource(
                vec![resource_addr],
                *resources_ids.next().unwrap(),
                filters.clone(),
                None,
                None,
            );
        }

        for (_, protocol) in protocol_config {
            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
            };

            assert!(peer.ensure_allowed_dst(&packet).is_ok());
        }
    }

    #[test_strategy::proptest()]
    fn gateway_reject_unallowed_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(resource_id())] resource_id: ResourceId,
        #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
        #[strategy(cidr_with_host())] config: (IpNetwork, IpAddr),
        #[strategy(filters_with_rejected_protocol())] protocol_config: (Filters, Protocol),
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (resource_addr, dest) = config;
        let src = if dest.is_ipv4() {
            src_v4.into()
        } else {
            src_v6.into()
        };
        let (filters, protocol) = protocol_config;
        // This test could be extended to test multiple src
        let mut peer = ClientOnGateway::new(client_id, src_v4, src_v6);
        let packet = match protocol {
            Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload),
            Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload),
            Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
        };

        peer.add_resource(vec![resource_addr], resource_id, filters, None, None);

        assert!(matches!(
            peer.ensure_allowed_dst(&packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
    }

    #[test_strategy::proptest()]
    fn gateway_reject_removed_filter_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(resource_id())] resource_id_allowed: ResourceId,
        #[strategy(resource_id())] resource_id_removed: ResourceId,
        #[strategy(any::<Ipv4Addr>())] src_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] src_v6: Ipv6Addr,
        #[strategy(cidr_with_host())] config: (IpNetwork, IpAddr),
        #[strategy(non_overlapping_non_empty_filters_with_allowed_protocol())] protocol_config: (
            (Filters, Protocol),
            (Filters, Protocol),
        ),
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (resource_addr, dest) = config;
        let src = if dest.is_ipv4() {
            src_v4.into()
        } else {
            src_v6.into()
        };
        let ((filters_allowed, protocol_allowed), (filters_removed, protocol_removed)) =
            protocol_config;
        // This test could be extended to test multiple src
        let mut peer = ClientOnGateway::new(client_id, src_v4, src_v6);

        let packet_allowed = match protocol_allowed {
            Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload.clone()),
            Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload.clone()),
            Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
        };

        let packet_rejected = match protocol_removed {
            Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload),
            Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload),
            Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
        };

        peer.add_resource(
            vec![supernet(resource_addr).unwrap_or(resource_addr)],
            resource_id_allowed,
            filters_allowed,
            None,
            None,
        );

        peer.add_resource(
            vec![resource_addr],
            resource_id_removed,
            filters_removed,
            None,
            None,
        );
        peer.remove_resource(&resource_id_removed);

        assert!(peer.ensure_allowed_dst(&packet_allowed).is_ok());
        assert!(matches!(
            peer.ensure_allowed_dst(&packet_rejected),
            Err(connlib_shared::Error::InvalidDst)
        ));
    }

    // Note: for these tests we don't really care that it's a valid host
    // we only need a host.
    // If we filter valid hosts it generates too many rejects
    fn host_v4(ip: Ipv4Network) -> impl Strategy<Value = Ipv4Addr> {
        (0u32..2u32.pow(32 - ip.netmask() as u32)).prop_map(move |n| {
            if ip.netmask() == 32 {
                ip.network_address()
            } else {
                ip.subnets_with_prefix(32)
                    .nth(n as usize)
                    .unwrap()
                    .network_address()
            }
        })
    }

    // Note: for these tests we don't really care that it's a valid host
    // we only need a host.
    // If we filter valid hosts it generates too many rejects
    fn host_v6(ip: Ipv6Network) -> impl Strategy<Value = Ipv6Addr> {
        (0u128..2u128.pow(128 - ip.netmask() as u32)).prop_map(move |n| {
            if ip.netmask() == 128 {
                ip.network_address()
            } else {
                ip.subnets_with_prefix(128)
                    .nth(n as usize)
                    .unwrap()
                    .network_address()
            }
        })
    }

    fn cidr_with_host() -> impl Strategy<Value = (IpNetwork, IpAddr)> {
        prop_oneof![cidrv4_with_host(), cidrv6_with_host()]
    }

    // max netmask here picked arbitrarily since using max size made the tests run for too long
    fn cidrv6_with_host() -> impl Strategy<Value = (IpNetwork, IpAddr)> {
        (1usize..=8).prop_flat_map(|host_mask| {
            ip6_network(host_mask)
                .prop_flat_map(|net| host_v6(net).prop_map(move |host| (net.into(), host.into())))
        })
    }

    fn cidrv4_with_host() -> impl Strategy<Value = (IpNetwork, IpAddr)> {
        (1usize..=8).prop_flat_map(|host_mask| {
            ip4_network(host_mask)
                .prop_flat_map(|net| host_v4(net).prop_map(move |host| (net.into(), host.into())))
        })
    }

    fn filters_with_allowed_protocol() -> impl Strategy<Value = (Filters, Protocol)> {
        filters().prop_flat_map(|filters| {
            if filters.is_empty() {
                any::<Protocol>().prop_map(|p| (vec![], p)).boxed()
            } else {
                select(filters.clone())
                    .prop_flat_map(move |filter| {
                        let filters = filters.clone();
                        protocol_from_filter(filter).prop_map(move |p| (filters.clone(), p))
                    })
                    .boxed()
            }
        })
    }

    fn non_overlapping_non_empty_filters_with_allowed_protocol(
    ) -> impl Strategy<Value = ((Filters, Protocol), (Filters, Protocol))> {
        filters_with_allowed_protocol()
            .prop_filter("empty filters accepts every packet", |(f, _)| !f.is_empty())
            .prop_flat_map(|(filters_a, protocol_a)| {
                filters_in_gaps(filters_a.clone())
                    .prop_filter(
                        "we reject empty filters since it increases complexity",
                        |f| !f.is_empty(),
                    )
                    .prop_flat_map(|filters| {
                        select(filters.clone()).prop_flat_map(move |filter| {
                            let filters = filters.clone();
                            protocol_from_filter(filter).prop_map(move |p| (filters.clone(), p))
                        })
                    })
                    .prop_map(move |(filters_b, protocol_b)| {
                        ((filters_a.clone(), protocol_a), (filters_b, protocol_b))
                    })
            })
    }

    fn filters_with_rejected_protocol() -> impl Strategy<Value = (Filters, Protocol)> {
        filters()
            .prop_filter("empty filters accepts every packet", |f| !f.is_empty())
            .prop_flat_map(|f| {
                let filters = f.clone();
                any::<ProtocolKind>()
                    .prop_filter_map(
                        "If ICMP is contained there is no way to generate gaps",
                        move |p| {
                            (p != ProtocolKind::Icmp || !filters.contains(&Filter::Icmp))
                                .then_some(p)
                        },
                    )
                    .prop_flat_map(move |p| {
                        if p == ProtocolKind::Icmp {
                            Just((f.clone(), Protocol::Icmp)).boxed()
                        } else {
                            let f = f.clone();
                            select(gaps(f.clone(), p))
                                .prop_flat_map(move |g| {
                                    let f = f.clone();
                                    g.prop_map(move |dport| (f.clone(), p.into_protocol(dport)))
                                })
                                .boxed()
                        }
                    })
            })
    }

    fn gaps(filters: Filters, protocol: ProtocolKind) -> Vec<RangeInclusive<u16>> {
        filters
            .into_iter()
            .filter_map(|f| match (f, protocol) {
                (Filter::Udp(inner), ProtocolKind::Udp) => {
                    Some(inner.port_range_start..=inner.port_range_end)
                }
                (Filter::Tcp(inner), ProtocolKind::Tcp) => {
                    Some(inner.port_range_start..=inner.port_range_end)
                }
                (_, _) => None,
            })
            .collect::<RangeInclusiveSet<u16>>()
            .gaps(&(0..=u16::MAX))
            .collect_vec()
    }

    fn protocol_from_filter(f: Filter) -> impl Strategy<Value = Protocol> {
        match f {
            Filter::Udp(PortRange {
                port_range_end,
                port_range_start,
            }) => (port_range_start..=port_range_end)
                .prop_map(|dport| Protocol::Udp { dport })
                .boxed(),
            Filter::Tcp(PortRange {
                port_range_end,
                port_range_start,
            }) => (port_range_start..=port_range_end)
                .prop_map(|dport| Protocol::Tcp { dport })
                .boxed(),
            Filter::Icmp => Just(Protocol::Icmp).boxed(),
        }
    }

    fn filters_in_gaps(filters: Filters) -> impl Strategy<Value = Filters> {
        let contains_icmp_filter = filters.contains(&Filter::Icmp);

        let ranges_without_tcp_filter = gaps(filters.clone(), ProtocolKind::Tcp);
        let tcp_filters = filter_from_vec(ranges_without_tcp_filter, ProtocolKind::Tcp);

        let ranges_without_udp_filter = gaps(filters, ProtocolKind::Udp);
        let udp_filters = filter_from_vec(ranges_without_udp_filter, ProtocolKind::Udp);

        let icmp_filter = if contains_icmp_filter {
            Just(vec![])
        } else {
            Just(vec![Filter::Icmp])
        };

        (tcp_filters, udp_filters, icmp_filter)
            .prop_map(|(udp, tcp, icmp)| Vec::from_iter(tcp.into_iter().chain(udp).chain(icmp)))
    }

    fn filter_from_vec(
        ranges: Vec<RangeInclusive<u16>>,
        empty_protocol: ProtocolKind,
    ) -> impl Strategy<Value = Filters> + Clone {
        if ranges.is_empty() {
            return Just(vec![]).boxed();
        }

        collection::vec(
            select(ranges.clone()).prop_flat_map(move |r| {
                let range = r.clone();
                range.prop_flat_map(move |s| {
                    (s..=*r.end()).prop_map(move |e| empty_protocol.into_filter(s..=e))
                })
            }),
            1..=ranges.len(),
        )
        .boxed()
    }

    fn filters() -> impl Strategy<Value = Filters> {
        collection::vec(
            prop_oneof![
                Just(Filter::Icmp),
                port_range().prop_map(Filter::Udp),
                port_range().prop_map(Filter::Tcp),
            ],
            0..=100,
        )
    }

    fn port_range() -> impl Strategy<Value = PortRange> {
        any::<u16>().prop_flat_map(|s| {
            (s..=u16::MAX).prop_map(move |d| PortRange {
                port_range_start: s,
                port_range_end: d,
            })
        })
    }

    fn supernet(ip: IpNetwork) -> Option<IpNetwork> {
        match ip {
            IpNetwork::V4(v4) => v4.supernet().map(Into::into),
            IpNetwork::V6(v6) => v6.supernet().map(Into::into),
        }
    }

    #[derive(Debug, Clone, Copy, Arbitrary)]
    enum Protocol {
        Tcp { dport: u16 },
        Udp { dport: u16 },
        Icmp,
    }

    impl From<&Filter> for ProtocolKind {
        fn from(value: &Filter) -> Self {
            match value {
                Filter::Udp(_) => ProtocolKind::Udp,
                Filter::Tcp(_) => ProtocolKind::Tcp,
                Filter::Icmp => ProtocolKind::Icmp,
            }
        }
    }

    #[derive(Debug, Clone, Copy, Arbitrary, PartialEq, Eq)]
    enum ProtocolKind {
        Tcp,
        Udp,
        Icmp,
    }

    impl ProtocolKind {
        fn into_protocol(self, dport: u16) -> Protocol {
            match self {
                ProtocolKind::Tcp => Protocol::Tcp { dport },
                ProtocolKind::Udp => Protocol::Udp { dport },
                ProtocolKind::Icmp => Protocol::Icmp,
            }
        }

        fn into_filter(self, range: RangeInclusive<u16>) -> Filter {
            match self {
                ProtocolKind::Tcp => Filter::Tcp(PortRange {
                    port_range_start: *range.start(),
                    port_range_end: *range.end(),
                }),
                ProtocolKind::Udp => Filter::Udp(PortRange {
                    port_range_start: *range.start(),
                    port_range_end: *range.end(),
                }),
                ProtocolKind::Icmp => Filter::Icmp,
            }
        }
    }
}

fn ipv4_addresses(ip: &[IpAddr]) -> Vec<IpAddr> {
    ip.iter().filter(|ip| ip.is_ipv4()).copied().collect_vec()
}

fn ipv6_addresses(ip: &[IpAddr]) -> Vec<IpAddr> {
    ip.iter().filter(|ip| ip.is_ipv6()).copied().collect_vec()
}

fn mapped_ipv4(ips: &[IpAddr]) -> Vec<IpAddr> {
    if !ipv4_addresses(ips).is_empty() {
        ipv4_addresses(ips)
    } else {
        ipv6_addresses(ips)
    }
}
fn mapped_ipv6(ips: &[IpAddr]) -> Vec<IpAddr> {
    if !ipv6_addresses(ips).is_empty() {
        ipv6_addresses(ips)
    } else {
        ipv4_addresses(ips)
    }
}
