use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
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
use crate::utils::contains;

#[derive(Debug)]
enum FilterEngine {
    PermitAll,
    PermitSome(FilterEngineInner),
}

#[derive(Debug)]
struct FilterEngineInner {
    udp: RangeInclusiveSet<u16>,
    tcp: RangeInclusiveSet<u16>,
    icmp: bool,
}

impl From<&Filters> for FilterEngine {
    fn from(value: &Filters) -> Self {
        FilterEngine::PermitSome(value.into())
    }
}

impl FilterEngine {
    fn new() -> FilterEngine {
        Self::PermitSome(FilterEngineInner::new())
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

    fn add_filters<'a>(&mut self, filters: impl Iterator<Item = &'a Filter>) {
        match self {
            FilterEngine::PermitAll => {}
            FilterEngine::PermitSome(filter_engine) => filter_engine.add_filters(filters),
        }
    }
}

impl FilterEngineInner {
    fn new() -> FilterEngineInner {
        FilterEngineInner {
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

    fn add_filters<'a>(&mut self, filters: impl Iterator<Item = &'a Filter>) {
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

impl From<&Filters> for FilterEngineInner {
    fn from(filters: &Filters) -> Self {
        let mut filter_engine = FilterEngineInner::new();
        filter_engine.add_filters(filters.iter());
        filter_engine
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
    pub(crate) fn new(id: ClientId, ips: &[IpNetwork]) -> ClientOnGateway {
        let mut allowed_ips = IpNetworkTable::new();
        for ip in ips {
            allowed_ips.insert(*ip, ());
        }

        ClientOnGateway {
            id,
            allowed_ips,
            resources: HashMap::new(),
            filters: IpNetworkTable::new(),
        }
    }

    pub(crate) fn is_emptied(&self) -> bool {
        self.resources.is_empty()
    }

    pub(crate) fn expire_resources(&mut self, now: DateTime<Utc>) {
        self.resources
            .retain(|_, r| !r.expires_at.is_some_and(|e| e <= now));
        self.recalculate_filters();
    }

    pub(crate) fn remove_resource(&mut self, resource: &ResourceId) {
        self.resources.remove(resource);
        self.recalculate_filters();
    }

    pub(crate) fn add_resource(
        &mut self,
        ip: IpNetwork,
        resource: ResourceId,
        filters: Filters,
        expires_at: Option<DateTime<Utc>>,
    ) {
        self.resources.insert(
            resource,
            GatewayResource {
                ip,
                filters,
                expires_at,
            },
        );
        self.recalculate_filters();
    }

    fn recalculate_filters(&mut self) {
        self.filters = IpNetworkTable::new();
        for resource in self.resources.values() {
            let mut filter_engine = FilterEngine::new();
            let filters = self
                .resources
                .values()
                .filter_map(|r| contains(r.ip, resource.ip).then_some(&r.filters));

            // Empty filters means permit all
            if filters.clone().any(|f| f.is_empty()) {
                filter_engine.permit_all();
            }

            filter_engine.add_filters(filters.flatten());
            self.filters.insert(resource.ip, filter_engine);
        }
    }

    /// Check if an incoming packet arriving over the network is ok to be forwarded to the TUN device.
    pub fn ensure_allowed(
        &self,
        packet: &MutableIpPacket<'_>,
    ) -> Result<(), connlib_shared::Error> {
        if self.allowed_ips.longest_match(packet.source()).is_none() {
            return Err(connlib_shared::Error::UnallowedPacket(packet.source()));
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
            return Err(connlib_shared::Error::UnallowedPacket(src));
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

struct GatewayResource {
    ip: IpNetwork,
    filters: Filters,
    expires_at: Option<DateTime<Utc>>,
}

/// The state of one client on a gateway.
pub struct ClientOnGateway {
    id: ClientId,
    allowed_ips: IpNetworkTable<()>,
    resources: HashMap<ResourceId, GatewayResource>,
    filters: IpNetworkTable<FilterEngine>,
}

#[cfg(test)]
mod tests {
    use std::{net::IpAddr, time::Duration};

    use chrono::Utc;
    use connlib_shared::messages::{
        gateway::{Filter, FilterInner},
        ClientId, ResourceId,
    };
    use ip_network::Ipv4Network;

    use super::ClientOnGateway;

    #[test]
    fn gateway_filters_expire_individually() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        let now = Utc::now();
        let then = now + Duration::from_secs(10);
        let after_then = then + Duration::from_secs(10);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Tcp(FilterInner {
                port_range_start: 20,
                port_range_end: 100,
            })],
            Some(then),
        );

        peer.add_resource(
            cidr_v4_resource().into(),
            resource2_id(),
            vec![Filter::Udp(FilterInner {
                port_range_start: 20,
                port_range_end: 100,
            })],
            Some(after_then),
        );

        let tcp_packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        let udp_packet = ip_packet::make::udp_packet(
            source_v4_addr(),
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

    #[test]
    // Note: this is a special case that is correctly handled by the gateway
    // but there are still problems for the control protocol and client to support this
    // See: #4789
    fn gateway_filters_work_for_subranges() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            "10.0.0.0/24".parse().unwrap(),
            resource_id(),
            vec![Filter::Tcp(FilterInner {
                port_range_start: 20,
                port_range_end: 100,
            })],
            None,
        );
        peer.add_resource(
            "10.0.0.0/16".parse().unwrap(),
            resource2_id(),
            vec![Filter::Tcp(FilterInner {
                port_range_start: 100,
                port_range_end: 200,
            })],
            None,
        );

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            "10.0.0.1".parse().unwrap(),
            5401,
            80,
            vec![0; 100],
        );
        assert!(peer.ensure_allowed(&packet).is_ok());

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            "10.0.0.1".parse().unwrap(),
            5401,
            120,
            vec![0; 100],
        );
        assert!(peer.ensure_allowed(&packet).is_ok());

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            "10.0.1.1".parse().unwrap(),
            5401,
            80,
            vec![0; 100],
        );
        assert!(matches!(
            peer.ensure_allowed(&packet),
            Err(connlib_shared::Error::InvalidDst)
        ));

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            "10.0.1.1".parse().unwrap(),
            5401,
            120,
            vec![0; 100],
        );
        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_filters_work_for_subranges_with_permit_all() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            "10.0.0.0/24".parse().unwrap(),
            resource_id(),
            vec![Filter::Tcp(FilterInner {
                port_range_start: 20,
                port_range_end: 100,
            })],
            None,
        );
        peer.add_resource("10.0.0.0/16".parse().unwrap(), resource2_id(), vec![], None);

        let packet = ip_packet::make::udp_packet(
            source_v4_addr(),
            "10.0.0.1".parse().unwrap(),
            5401,
            200,
            vec![0; 100],
        );
        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    fn source_v4_addr() -> IpAddr {
        "100.64.0.1".parse().unwrap()
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
    use connlib_shared::{messages::gateway::FilterInner, proptest::*};
    use ip_network::{Ipv4Network, Ipv6Network};
    use ip_packet::make::{icmp_request_packet, tcp_packet, udp_packet};
    use itertools::Itertools;
    use proptest::{
        arbitrary::any,
        collection,
        prelude::ProptestConfig,
        prop_oneof,
        sample::select,
        strategy::{Just, Strategy},
    };
    use test_strategy::Arbitrary;

    #[test_strategy::proptest(ProptestConfig {max_shrink_iters: 10_000, ..Default::default()})]
    fn gateway_accepts_allowed_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(resource_id())] resource_id: ResourceId,
        #[strategy(source_resource_and_host_within())] config: (IpAddr, IpNetwork, IpAddr),
        #[strategy(filters_with_protocol())] protocol_config: (Filters, Protocol),
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (src, resource_addr, dest) = config;
        let (filters, protocol) = protocol_config;
        // This test could be extended to test multiple src
        let mut peer = ClientOnGateway::new(client_id, &[src.into()]);
        peer.add_resource(resource_addr, resource_id, filters, None);

        let packet = match protocol {
            Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload),
            Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload),
            Protocol::Icmp => icmp_request_packet(src, dest),
        };

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test_strategy::proptest(ProptestConfig {max_shrink_iters: 10_000, ..Default::default()})]
    fn gateway_reject_unallowed_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(resource_id())] resource_id: ResourceId,
        #[strategy(source_resource_and_host_within())] config: (IpAddr, IpNetwork, IpAddr),
        #[strategy(filters_with_rejected_protocol())] protocol_config: (Filters, Protocol),
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (src, resource_addr, dest) = config;
        let (filters, protocol) = protocol_config;
        // This test could be extended to test multiple src
        let mut peer = ClientOnGateway::new(client_id, &[src.into()]);
        peer.add_resource(resource_addr, resource_id, filters, None);

        let packet = match protocol {
            Protocol::Tcp { dport } => tcp_packet(src, dest, sport, dport, payload),
            Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload),
            Protocol::Icmp => icmp_request_packet(src, dest),
        };

        assert!(matches!(
            peer.ensure_allowed(&packet),
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
        // .prop_filter("not a valid host", |ip| {
        //     !ip.is_unspecified() && !ip.is_broadcast()
        // })
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
        // .prop_filter("not a valid host", |ip| !ip.is_unspecified())
    }

    fn source_resource_and_host_within() -> impl Strategy<Value = (IpAddr, IpNetwork, IpAddr)> {
        any::<bool>().prop_flat_map(|is_v4| {
            if is_v4 {
                cidrv4_with_host()
                    .prop_flat_map(|(net, dst)| {
                        any::<Ipv4Addr>().prop_map(move |src| (src.into(), net.into(), dst.into()))
                    })
                    .boxed()
            } else {
                cidrv6_with_host()
                    .prop_flat_map(|(net, dst)| {
                        any::<Ipv6Addr>().prop_map(move |src| (src.into(), net.into(), dst.into()))
                    })
                    .boxed()
            }
        })
    }

    // max netmask here picked arbitrarily since using max size made the tests run for too long
    fn cidrv6_with_host() -> impl Strategy<Value = (Ipv6Network, Ipv6Addr)> {
        (1usize..=8).prop_flat_map(|host_mask| {
            ip6_network(host_mask)
                .prop_flat_map(|net| host_v6(net).prop_map(move |host| (net, host)))
        })
    }

    fn cidrv4_with_host() -> impl Strategy<Value = (Ipv4Network, Ipv4Addr)> {
        (1usize..=8).prop_flat_map(|host_mask| {
            ip4_network(host_mask)
                .prop_flat_map(|net| host_v4(net).prop_map(move |host| (net, host)))
        })
    }

    fn filters_with_protocol() -> impl Strategy<Value = (Filters, Protocol)> {
        filters().prop_flat_map(|f| {
            if f.is_empty() {
                any::<Protocol>().prop_map(|p| (vec![], p)).boxed()
            } else {
                (0..f.len())
                    .prop_flat_map(move |i| {
                        // TODO: ????? why was this needed shouuld be able to access f from the inner closure here...
                        // anyways there should be a better way to write this composed strategies
                        (Just(f.clone()), protocol_from_filter(f[i])).prop_map(move |(f, p)| (f, p))
                    })
                    .boxed()
            }
        })
    }

    fn filters_with_rejected_protocol() -> impl Strategy<Value = (Filters, Protocol)> {
        // TODO: This can be cleaned up
        filters()
            .prop_filter("empty filters accepts every packet", |f| !f.is_empty())
            .prop_flat_map(|f| {
                let filters = f.clone();
                any::<EmptyProtocol>()
                    .prop_filter_map(
                        "If ICMP is contained there is no way to generate gaps",
                        move |p| {
                            (p != EmptyProtocol::Icmp || !filters.contains(&Filter::Icmp))
                                .then_some(p)
                        },
                    )
                    .prop_flat_map(move |p| {
                        if p == EmptyProtocol::Icmp {
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

    fn gaps(filters: Filters, protocol: EmptyProtocol) -> Vec<RangeInclusive<u16>> {
        filters
            .into_iter()
            .filter_map(|f| match (f, protocol) {
                (Filter::Udp(inner), EmptyProtocol::Udp) => {
                    Some(inner.port_range_start..=inner.port_range_end)
                }
                (Filter::Tcp(inner), EmptyProtocol::Tcp) => {
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
            Filter::Udp(FilterInner {
                port_range_end,
                port_range_start,
            }) => (port_range_start..=port_range_end)
                .prop_map(|dport| Protocol::Udp { dport })
                .boxed(),
            Filter::Tcp(FilterInner {
                port_range_end,
                port_range_start,
            }) => (port_range_start..=port_range_end)
                .prop_map(|dport| Protocol::Tcp { dport })
                .boxed(),
            Filter::Icmp => Just(Protocol::Icmp).boxed(),
        }
    }

    fn filters() -> impl Strategy<Value = Filters> {
        collection::vec(
            prop_oneof![
                Just(Filter::Icmp),
                port_range().prop_map(|inner| Filter::Udp(inner)),
                port_range().prop_map(|inner| Filter::Tcp(inner)),
            ],
            0..=100,
        )
    }

    fn port_range() -> impl Strategy<Value = FilterInner> {
        any::<u16>().prop_flat_map(|s| {
            (s..=u16::MAX).prop_map(move |d| FilterInner {
                port_range_start: s,
                port_range_end: d,
            })
        })
    }

    #[derive(Debug, Clone, Copy, Arbitrary)]
    enum Protocol {
        Tcp { dport: u16 },
        Udp { dport: u16 },
        Icmp,
    }

    impl From<&Filter> for EmptyProtocol {
        fn from(value: &Filter) -> Self {
            match value {
                Filter::Udp(_) => EmptyProtocol::Udp,
                Filter::Tcp(_) => EmptyProtocol::Tcp,
                Filter::Icmp => EmptyProtocol::Icmp,
            }
        }
    }

    #[derive(Debug, Clone, Copy, Arbitrary, PartialEq, Eq)]
    enum EmptyProtocol {
        Tcp,
        Udp,
        Icmp,
    }

    impl EmptyProtocol {
        fn into_protocol(self, dport: u16) -> Protocol {
            match self {
                EmptyProtocol::Tcp => Protocol::Tcp { dport },
                EmptyProtocol::Udp => Protocol::Udp { dport },
                EmptyProtocol::Icmp => Protocol::Icmp,
            }
        }
    }
}
