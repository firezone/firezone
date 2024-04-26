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

    // TODO: if some filter is permit all just call permit_all
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
            IpNextHeaderProtocols::Icmp => self.icmp,
            _ => false,
        }
    }

    fn add_filters<'a>(&mut self, filters: impl Iterator<Item = &'a Filter>) {
        // TODO: ICMP is not handled by the portal yet!
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

    pub(crate) fn expire_resources(&mut self, now: &DateTime<Utc>) {
        self.resources
            .retain(|_, r| !r.expires_at.is_some_and(|e| e <= *now));
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
    fn gateway_accept_icmp_without_filters() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(cidr_v4_resource().into(), resource_id(), Vec::new(), None);

        let packet = ip_packet::make::icmp_request_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
        );

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_accept_tcp_without_filters() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(cidr_v4_resource().into(), resource_id(), Vec::new(), None);

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_accept_udp_without_filters() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(cidr_v4_resource().into(), resource_id(), Vec::new(), None);

        let packet = ip_packet::make::udp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_accept_icmp_with_filters() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Icmp],
            None,
        );

        let packet = ip_packet::make::icmp_request_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
        );

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_accept_tcp_with_filters_single_port_range() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Tcp(FilterInner {
                port_range_start: 80,
                port_range_end: 80,
            })],
            None,
        );

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_accept_udp_with_filters_single_port_range() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Udp(FilterInner {
                port_range_start: 80,
                port_range_end: 80,
            })],
            None,
        );

        let packet = ip_packet::make::udp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_accept_tcp_with_filters_multi_port_range() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Tcp(FilterInner {
                port_range_start: 20,
                port_range_end: 100,
            })],
            None,
        );

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_accept_multiple_filters() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![
                Filter::Tcp(FilterInner {
                    port_range_start: 20,
                    port_range_end: 100,
                }),
                Filter::Icmp,
            ],
            None,
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

        let icmp_packet = ip_packet::make::icmp_request_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
        );

        assert!(peer.ensure_allowed(&tcp_packet).is_ok());
        assert!(peer.ensure_allowed(&icmp_packet).is_ok());
        assert!(matches!(
            peer.ensure_allowed(&udp_packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
    }

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

        peer.expire_resources(&now);

        assert!(peer.ensure_allowed(&tcp_packet).is_ok());
        assert!(peer.ensure_allowed(&udp_packet).is_ok());

        peer.expire_resources(&then);

        assert!(matches!(
            peer.ensure_allowed(&tcp_packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
        assert!(peer.ensure_allowed(&udp_packet).is_ok());

        peer.expire_resources(&after_then);

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

    #[test]
    fn gateway_accept_udp_with_filters_multi_port_range() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Udp(FilterInner {
                port_range_start: 20,
                port_range_end: 100,
            })],
            None,
        );

        let packet = ip_packet::make::udp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(peer.ensure_allowed(&packet).is_ok());
    }

    #[test]
    fn gateway_reject_tcp_with_filters_outside_range() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Tcp(FilterInner {
                port_range_start: 100,
                port_range_end: 200,
            })],
            None,
        );

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(matches!(
            peer.ensure_allowed(&packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
    }

    #[test]
    fn gateway_reject_udp_with_filters_outside_range() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Udp(FilterInner {
                port_range_start: 100,
                port_range_end: 200,
            })],
            None,
        );

        let packet = ip_packet::make::udp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(matches!(
            peer.ensure_allowed(&packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
    }

    #[test]
    fn gateway_reject_udp_with_tcp_filters() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Tcp(FilterInner {
                port_range_start: 1,
                port_range_end: 200,
            })],
            None,
        );

        let packet = ip_packet::make::udp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(matches!(
            peer.ensure_allowed(&packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
    }

    #[test]
    fn gateway_reject_tcp_with_icmp_filters() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Icmp],
            None,
        );

        let packet = ip_packet::make::tcp_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
            5401,
            80,
            vec![0; 100],
        );

        assert!(matches!(
            peer.ensure_allowed(&packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
    }

    #[test]
    fn gateway_reject_icmp_without_allowed_icmp_filter() {
        let mut peer = ClientOnGateway::new(client_id(), &[source_v4_addr().into()]);
        peer.add_resource(
            cidr_v4_resource().into(),
            resource_id(),
            vec![Filter::Udp(FilterInner {
                port_range_start: 0,
                port_range_end: u16::MAX,
            })],
            None,
        );

        let packet = ip_packet::make::icmp_request_packet(
            source_v4_addr(),
            cidr_v4_resource().hosts().next().unwrap().into(),
        );

        assert!(matches!(
            peer.ensure_allowed(&packet),
            Err(connlib_shared::Error::InvalidDst)
        ));
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
