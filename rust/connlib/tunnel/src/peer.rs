use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::time::Instant;

use bimap::BiMap;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{ClientId, DnsServer, Filter, Filters, GatewayId, ResourceId};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::ip::IpNextHeaderProtocols;
use ip_packet::{IpPacket, MutableIpPacket, Packet};
use rangemap::RangeInclusiveSet;

use crate::client::IpProvider;

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
        for Filter {
            protocol,
            port_range_end,
            port_range_start,
        } in filters
        {
            let range = *port_range_start..=*port_range_end;
            match protocol {
                connlib_shared::messages::Protocol::Tcp => {
                    self.tcp.insert(range);
                }
                connlib_shared::messages::Protocol::Udp => {
                    self.udp.insert(range);
                }
                // Note: this wouldn't have the port_range
                connlib_shared::messages::Protocol::Icmp => todo!(),
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

    pub(crate) fn expire_resources(&mut self) {
        self.resources
            .retain(|_, r| !r.expires_at.is_some_and(|e| e <= Utc::now()));
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
        // TODO: resource updates
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
                // Here we are using that ip_a/a contains ip_b/b <=> ip_a/a contains ip_b
                // Also we use that that ip_a/a contains ip_a
                .filter_map(|r| {
                    r.ip.contains(resource.ip.network_address())
                        .then_some(&r.filters)
                });

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
