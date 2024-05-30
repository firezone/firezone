use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Instant;

use bimap::BiMap;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{
    gateway::Filter, gateway::Filters, ClientId, DnsServer, GatewayId, ResourceId,
};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::ip::IpNextHeaderProtocols;
use ip_packet::{IpPacket, MutableIpPacket, Packet};
use rangemap::RangeInclusiveSet;

use crate::client::IpProvider;
use crate::utils::network_contains_network;

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

// The max time a dns request can be configured to live in resolvconf
// is 30 seconds. See resolvconf(5) timeout.
const IDS_EXPIRE: std::time::Duration = std::time::Duration::from_secs(60);

/// The state of one gateway on a client.
pub(crate) struct GatewayOnClient {
    id: GatewayId,
    pub allowed_ips: IpNetworkTable<HashSet<ResourceId>>,

    pub translations: BiMap<IpAddr, IpAddr>,
    dns_mapping: BiMap<IpAddr, DnsServer>,
    mangled_dns_ids: HashMap<u16, std::time::Instant>,
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
            dns_mapping: Default::default(),
            mangled_dns_ids: Default::default(),
        }
    }

    pub fn get_or_assign_translation(
        &mut self,
        ip: &IpAddr,
        ip_provider: &mut IpProvider,
    ) -> Option<IpAddr> {
        if let Some(proxy_ip) = self.translations.get_by_right(ip) {
            return Some(*proxy_ip);
        }

        let proxy_ip = ip_provider.get_proxy_ip_for(ip)?;

        self.translations.insert(proxy_ip, *ip);
        Some(proxy_ip)
    }

    pub fn expire_dns_track(&mut self) {
        self.mangled_dns_ids
            .retain(|_, exp| exp.elapsed() < IDS_EXPIRE);
    }

    pub fn set_dns(&mut self, mapping: BiMap<IpAddr, DnsServer>) {
        self.mangled_dns_ids.clear();
        self.dns_mapping = mapping;
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
        }
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
    ) {
        self.resources
            .entry(resource)
            .or_default()
            .push(ResourceOnGateway {
                ips,
                filters,
                // Each resource subdomain can expire individually so it's worth keeping a list
                expires_at,
            });
        self.recalculate_filters();
    }

    // Note: we only allow updating filters and names
    // but names updates have no effect on the gateway
    pub(crate) fn update_resource(
        &mut self,
        resource: &connlib_shared::messages::gateway::ResourceDescription,
    ) {
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

    /// Check if an incoming packet arriving over the network is ok to be forwarded to the TUN device.
    pub fn ensure_allowed(
        &self,
        packet: &MutableIpPacket<'_>,
    ) -> Result<(), connlib_shared::Error> {
        if packet.source() != IpAddr::from(self.ipv4) && packet.source() != IpAddr::from(self.ipv6)
        {
            return Err(connlib_shared::Error::UnallowedPacket {
                src: packet.source(),
                allowed_ips: HashSet::from_iter([self.ipv4.into(), self.ipv6.into()]),
            });
        }

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
        let mut src = *self.translations.get_by_right(&addr).unwrap_or(&addr);

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

        if let Some(dgm) = pkt.as_udp() {
            if let Some(sentinel) = self
                .dns_mapping
                .get_by_right(&(src, dgm.get_source()).into())
            {
                if let Ok(message) = domain::base::Message::from_slice(dgm.payload()) {
                    if self
                        .mangled_dns_ids
                        .remove(&message.header().id())
                        .is_some_and(|exp| exp.elapsed() < IDS_EXPIRE)
                    {
                        src = *sentinel;
                    }
                }
            }
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

        if let Some(srv) = self.dns_mapping.get_by_left(&packet.destination()) {
            if let Some(dgm) = packet.as_udp() {
                if let Ok(message) = domain::base::Message::from_slice(dgm.payload()) {
                    self.mangled_dns_ids
                        .insert(message.header().id(), Instant::now());
                    packet.set_dst(srv.ip());
                    packet.update_checksum();
                }
            }
        }

        packet
    }

    pub fn id(&self) -> GatewayId {
        self.id
    }
}

struct ResourceOnGateway {
    ips: Vec<IpNetwork>,
    filters: Filters,
    expires_at: Option<DateTime<Utc>>,
}

/// The state of one client on a gateway.
pub struct ClientOnGateway {
    id: ClientId,
    ipv4: Ipv4Addr,
    ipv6: Ipv6Addr,
    resources: HashMap<ResourceId, Vec<ResourceOnGateway>>,
    filters: IpNetworkTable<FilterEngine>,
}

#[cfg(test)]
mod tests {
    use std::{
        net::{Ipv4Addr, Ipv6Addr},
        time::Duration,
    };

    use chrono::Utc;
    use connlib_shared::messages::{
        gateway::{Filter, PortRange},
        ClientId, ResourceId,
    };
    use ip_network::Ipv4Network;

    use super::ClientOnGateway;

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
        );

        peer.add_resource(
            vec![cidr_v4_resource().into()],
            resource2_id(),
            vec![Filter::Udp(PortRange {
                port_range_start: 20,
                port_range_end: 100,
            })],
            Some(after_then),
        );

        let tcp_packet = ip_packet::make::tcp_packet(
            source_v4_addr().into(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        let udp_packet = ip_packet::make::udp_packet(
            source_v4_addr().into(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        peer.expire_resources(now);

        assert!(peer.ensure_allowed(&tcp_packet).is_ok());
        assert!(peer.ensure_allowed(&udp_packet).is_ok());

        peer.expire_resources(then);

        assert!(matches!(
            peer.ensure_allowed(&tcp_packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
        assert!(peer.ensure_allowed(&udp_packet).is_ok());

        peer.expire_resources(after_then);

        assert!(matches!(
            peer.ensure_allowed(&tcp_packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
        assert!(matches!(
            peer.ensure_allowed(&udp_packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
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
            peer.add_resource(vec![addr], resources_id[resources], filter.clone(), None);
            resources += 1;
            resource_addr = supernet(addr);
        }

        for (_, protocol) in &protocol_config[0..resources] {
            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(src, dest, sport, *dport, payload.clone()),
                Protocol::Udp { dport } => udp_packet(src, dest, sport, *dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
            };
            assert!(peer.ensure_allowed(&packet).is_ok());
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

        peer.add_resource(resource_addr, resource_id, filters, None);

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
            assert!(peer.ensure_allowed(&packet).is_ok());
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

        peer.add_resource(resource_addr_1, resource_id, filters.clone(), None);
        peer.add_resource(resource_addr_2, resource_id, filters, None);

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
            assert!(peer.ensure_allowed(&packet).is_ok());
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
            assert!(peer.ensure_allowed(&packet).is_ok());
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
            );
        }

        for (_, protocol) in protocol_config {
            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, dest, 1, 0),
            };

            assert!(peer.ensure_allowed(&packet).is_ok());
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

        peer.add_resource(vec![resource_addr], resource_id, filters, None);

        assert!(matches!(
            peer.ensure_allowed(&packet),
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
        );

        peer.add_resource(
            vec![resource_addr],
            resource_id_removed,
            filters_removed,
            None,
        );
        peer.remove_resource(&resource_id_removed);

        assert!(peer.ensure_allowed(&packet_allowed).is_ok());
        assert!(matches!(
            peer.ensure_allowed(&packet_rejected),
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
        filter_from_vec(gaps(filters.clone(), ProtocolKind::Tcp), ProtocolKind::Tcp).prop_flat_map(
            move |tcp_filters| {
                let f = filters.clone();
                filter_from_vec(gaps(filters.clone(), ProtocolKind::Udp), ProtocolKind::Udp)
                    .prop_map(move |udp_filters| {
                        let mut filters = tcp_filters.clone();
                        filters.extend(udp_filters);
                        if !f.contains(&Filter::Icmp) {
                            filters.push(Filter::Icmp)
                        }

                        filters
                    })
            },
        )
    }

    fn filter_from_vec(
        ranges: Vec<RangeInclusive<u16>>,
        empty_protocol: ProtocolKind,
    ) -> impl Strategy<Value = Filters> {
        collection::vec(
            select(ranges.clone()).prop_flat_map(move |r| {
                let range = r.clone();
                range.prop_flat_map(move |s| {
                    (s..=*r.end()).prop_map(move |e| empty_protocol.into_filter(s..=e))
                })
            }),
            1..=ranges.len(),
        )
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
