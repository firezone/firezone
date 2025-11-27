use std::collections::{BTreeMap, BTreeSet, VecDeque, btree_map};
use std::iter;
use std::net::IpAddr;
use std::time::Instant;

use anyhow::{Context, Result, bail};
use chrono::{DateTime, Utc};
use connlib_model::{ClientId, ResourceId};
use dns_types::DomainName;
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use ip_network_table::IpNetworkTable;
use ip_packet::{IpPacket, Protocol, UnsupportedProtocol};

use crate::client::{IPV4_RESOURCES, IPV6_RESOURCES};
use crate::gateway::filter_engine::FilterEngine;
use crate::gateway::flow_tracker;
use crate::gateway::nat_table::{NatTable, TranslateIncomingResult};
use crate::gateway::unroutable_packet::UnroutablePacket;
use crate::messages::gateway::Filters;
use crate::messages::gateway::ResourceDescription;
use crate::utils::network_contains_network;
use crate::{GatewayEvent, IpConfig, NotAllowedResource, NotClientIp};

/// The state of one client on a gateway.
pub struct ClientOnGateway {
    id: ClientId,

    client_tun: IpConfig,
    gateway_tun: IpConfig,

    flow_properties: flow_tracker::ClientProperties,

    resources: BTreeMap<ResourceId, ResourceOnGateway>,
    /// Caches the existence of internet resource
    internet_resource_enabled: Option<ResourceId>,
    filters: IpNetworkTable<(FilterEngine, ResourceId)>,
    permanent_translations: BTreeMap<IpAddr, TranslationState>,
    nat_table: NatTable,
    buffered_events: VecDeque<GatewayEvent>,
}

#[derive(Debug, PartialEq)]
pub enum TranslateOutboundResult {
    Send(IpPacket),
    DestinationUnreachable(IpPacket),
    Filtered(IpPacket),
}

impl ClientOnGateway {
    pub(crate) fn new(
        id: ClientId,
        client_tun: IpConfig,
        gateway_tun: IpConfig,
        flow_properties: flow_tracker::ClientProperties,
    ) -> ClientOnGateway {
        ClientOnGateway {
            id,
            client_tun,
            gateway_tun,
            flow_properties,
            resources: BTreeMap::new(),
            filters: IpNetworkTable::new(),
            permanent_translations: Default::default(),
            nat_table: Default::default(),
            buffered_events: Default::default(),
            internet_resource_enabled: None,
        }
    }

    /// A client is only allowed to send packets from their (portal-assigned) tunnel IPs.
    ///
    /// Failure to enforce this would allow one client to send traffic masquarading as a different client.
    fn allowed_ips(&self) -> [IpAddr; 2] {
        [
            IpAddr::from(self.client_tun.v4),
            IpAddr::from(self.client_tun.v6),
        ]
    }

    /// Setup the NAT for a domain of a DNS resource.
    #[tracing::instrument(level = "debug", skip_all, fields(cid = %self.id))]
    pub(crate) fn setup_nat(
        &mut self,
        name: DomainName,
        resource_id: ResourceId,
        resolved_ips: BTreeSet<IpAddr>,
        proxy_ips: BTreeSet<IpAddr>,
    ) -> Result<()> {
        if self.have_proxy_ips_been_reassigned(resource_id, &name, &proxy_ips) {
            tracing::info!("Client has re-assigned proxy IPs, resetting DNS resource NAT");

            self.nat_table = Default::default();
            self.permanent_translations = Default::default();
        }

        let resource = self
            .resources
            .get_mut(&resource_id)
            .context("Unknown resource")?;

        let ResourceOnGateway::Dns {
            address, domains, ..
        } = resource
        else {
            bail!("Cannot setup NAT for non-DNS resource")
        };

        anyhow::ensure!(crate::dns::is_subdomain(&name, address));

        if resolved_ips.is_empty() {
            tracing::debug!(domain = %name, %resource_id, "No A / AAAA records for domain")
        }

        let mut resolved_ipv4 = resolved_ips.iter().filter(|ip| ip.is_ipv4()).cycle();
        let mut resolved_ipv6 = resolved_ips.iter().filter(|ip| ip.is_ipv6()).cycle();

        tracing::debug!(domain = %name, ?resolved_ips, ?proxy_ips, "Setting up DNS resource NAT");

        for proxy_ip in proxy_ips {
            let maybe_real_ip = match proxy_ip {
                IpAddr::V4(_) => resolved_ipv4.next(),
                IpAddr::V6(_) => resolved_ipv6.next(),
            };

            tracing::debug!(%name, %proxy_ip, real_ip = ?maybe_real_ip);

            self.permanent_translations.insert(
                proxy_ip,
                TranslationState::new(resource_id, maybe_real_ip.copied(), name.clone()),
            );
        }

        domains.insert(name, resolved_ips);
        self.recalculate_filters();

        Ok(())
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.resources.is_empty()
    }

    pub(crate) fn expire_resources(&mut self, now: DateTime<Utc>) {
        let cid = self.id;
        let mut any_expired = false;

        for (rid, _) in self.resources.extract_if(.., |_, r| !r.is_allowed(&now)) {
            tracing::info!(%cid, %rid, "Access to resource expired");
            any_expired = true;
        }

        if any_expired {
            self.recalculate_filters();
        }
    }

    pub(crate) fn poll_event(&mut self) -> Option<GatewayEvent> {
        self.buffered_events.pop_front()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.nat_table.handle_timeout(now);
    }

    pub(crate) fn remove_resource(&mut self, resource: &ResourceId) {
        self.resources.remove(resource);
        self.recalculate_filters();
    }

    pub(crate) fn add_resource(
        &mut self,
        resource: crate::messages::gateway::ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
    ) {
        tracing::info!(cid = %self.id, rid = %resource.id(), expires = ?expires_at.map(|e| e.to_rfc3339()), "Allowing access to resource");

        match self.resources.entry(resource.id()) {
            btree_map::Entry::Vacant(v) => {
                v.insert(ResourceOnGateway::new(resource, expires_at));
            }
            btree_map::Entry::Occupied(mut o) => o.get_mut().update(&resource),
        }

        self.recalculate_filters();
    }

    // Note: we only allow updating filters and names
    // but names updates have no effect on the gateway
    pub(crate) fn update_resource(&mut self, new_description: &ResourceDescription) {
        let Some(resource) = self.resources.get_mut(&new_description.id()) else {
            return;
        };

        resource.update(new_description);

        self.recalculate_filters();
    }

    pub(crate) fn update_resource_expiry(&mut self, rid: ResourceId, new_expiry: DateTime<Utc>) {
        let Some(resource) = self.resources.get_mut(&rid) else {
            tracing::debug!(%rid, "Unknown resource");

            return;
        };

        let new_expiry_rfc3339 = new_expiry.to_rfc3339();

        let old_expiry = match resource {
            ResourceOnGateway::Cidr { expires_at, .. } => expires_at.replace(new_expiry),
            ResourceOnGateway::Dns { expires_at, .. } => expires_at.replace(new_expiry),
            ResourceOnGateway::Internet { expires_at } => expires_at.replace(new_expiry),
        };

        tracing::info!(old = ?old_expiry.map(|e| e.to_rfc3339()), new = %new_expiry_rfc3339, "Updated resource expiry");
    }

    pub(crate) fn retain_authorizations(&mut self, authorization: BTreeSet<ResourceId>) {
        for (rid, _) in self
            .resources
            .extract_if(.., |rid, _| !authorization.contains(rid))
        {
            tracing::info!(%rid, "Revoking resource authorization");
        }

        self.recalculate_filters();
    }

    /// Checks if the given proxy IPs assigned for a domain are consistent with what we have stored.
    ///
    /// When a Client signs out and back in again, it starts re-numbering DNS resources and thus may
    /// reuse a proxy IP previously assigned to a different domain.
    fn have_proxy_ips_been_reassigned(
        &self,
        resource_id: ResourceId,
        name: &DomainName,
        proxy_ips: &BTreeSet<IpAddr>,
    ) -> bool {
        for ip in proxy_ips {
            let Some(state) = self.permanent_translations.get(ip) else {
                continue;
            };

            if state.resource_id != resource_id || state.domain != name {
                return true;
            }
        }

        false
    }

    // Call this after any resources change
    //
    // This recalculate the ip-table rules, this allows us to remove and add resources and keep the allow-list correct
    // in case that 2 or more resources have overlapping rules.
    fn recalculate_filters(&mut self) {
        self.filters = IpNetworkTable::new();
        self.recalculate_cidr_filters();
        self.recalculate_dns_filters();

        self.internet_resource_enabled = self
            .resources
            .iter()
            .find_map(|(id, r)| r.is_internet_resource().then_some(*id));
    }

    fn recalculate_cidr_filters(&mut self) {
        for (id, resource) in self.resources.iter().filter(|(_, r)| r.is_cidr()) {
            for ip in &resource.ips() {
                let filters = self.resources.values().filter_map(|r| {
                    r.ips()
                        .iter()
                        .any(|r_ip| network_contains_network(*r_ip, *ip))
                        .then_some(r.filters())
                });

                insert_filters(&mut self.filters, *ip, *id, filters);
            }
        }
    }

    fn recalculate_dns_filters(&mut self) {
        for (addr, TranslationState { resource_id, .. }) in &self.permanent_translations {
            let Some(resource) = self.resources.get(resource_id) else {
                continue;
            };

            debug_assert!(resource.is_dns());

            insert_filters(
                &mut self.filters,
                IpNetwork::from(*addr),
                *resource_id,
                iter::once(resource.filters()),
            );
        }
    }

    pub fn translate_outbound(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> anyhow::Result<TranslateOutboundResult> {
        if packet.icmp_error().is_ok_and(|e| e.is_some()) {
            bail!(UnroutablePacket::outbound_icmp_error(&packet))
        }

        // Filtering a packet is not an error.
        if let Err(e) = self.ensure_allowed_outbound(&packet) {
            tracing::debug!(filtered_packet = ?packet, "{e:#}");
            return Ok(TranslateOutboundResult::Filtered(
                ip_packet::make::icmp_dest_unreachable_prohibited(&packet)?,
            ));
        }

        // Failing to transform is an error we want to know about further up.
        let result = self.transform_network_to_tun(packet, now)?;

        Ok(result)
    }

    pub fn translate_inbound(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> anyhow::Result<IpPacket> {
        // Traffic from our own IP is allowed.
        match packet.source() {
            IpAddr::V4(src) if src == self.gateway_tun.v4 => return Ok(packet),
            IpAddr::V6(src) if src == self.gateway_tun.v6 => return Ok(packet),
            IpAddr::V4(_) | IpAddr::V6(_) => {}
        }

        let packet = self.transform_tun_to_network(packet, now)?;

        self.ensure_client_ip(packet.destination())?;

        // Always allow ICMP errors to pass through, even in the presence of filters that don't allow ICMP.
        if packet.icmp_error().is_ok_and(|e| e.is_some()) {
            return Ok(packet);
        }

        let rid = self
            .classify_resource(packet.source(), packet.source_protocol())
            .with_context(|| UnroutablePacket::not_allowed(&packet))?;

        flow_tracker::inbound_tun::record_resource(rid);

        Ok(packet)
    }

    fn transform_network_to_tun(
        &mut self,
        mut packet: IpPacket,
        now: Instant,
    ) -> anyhow::Result<TranslateOutboundResult> {
        let dst = packet.destination();

        // Packets to the TUN interface don't get transformed.
        if self.gateway_tun.is_ip(dst) {
            return Ok(TranslateOutboundResult::Send(packet));
        }

        // Packets for CIDR resources / Internet resource are forwarded as is.
        if !is_dns_addr(dst) {
            return Ok(TranslateOutboundResult::Send(packet));
        }

        let Some(state) = self.permanent_translations.get_mut(&packet.destination()) else {
            tracing::debug!(%dst, "No translation entry");

            return Ok(TranslateOutboundResult::DestinationUnreachable(
                ip_packet::make::icmp_dest_unreachable_network(&packet)?,
            ));
        };

        let Some(resolved_ip) = state.resolved_ip else {
            return Ok(TranslateOutboundResult::DestinationUnreachable(
                ip_packet::make::icmp_dest_unreachable_network(&packet)?,
            ));
        };

        if resolved_ip.is_ipv4() != dst.is_ipv4() {
            tracing::debug!(
                %dst,
                resolved = %resolved_ip,
                "Cannot translate between IP versions"
            );

            return Ok(TranslateOutboundResult::DestinationUnreachable(
                ip_packet::make::icmp_dest_unreachable_network(&packet)?,
            ));
        }

        flow_tracker::inbound_wg::record_domain(state.domain.clone());

        let (source_protocol, real_ip) =
            self.nat_table
                .translate_outgoing(&packet, resolved_ip, now)?;

        packet
            .translate_destination(source_protocol, real_ip)
            .context("Failed to translate packet to new destination")?;
        packet.update_checksum();

        Ok(TranslateOutboundResult::Send(packet))
    }

    fn transform_tun_to_network(
        &mut self,
        mut packet: IpPacket,
        now: Instant,
    ) -> anyhow::Result<IpPacket> {
        let (proto, ip) = match self.nat_table.translate_incoming(&packet, now)? {
            TranslateIncomingResult::Ok { proto, src } => (proto, src),
            TranslateIncomingResult::IcmpError(prototype) => {
                tracing::debug!(error = ?prototype.error(), dst = %prototype.outside_dst(), proxy_ip = %prototype.inside_dst(), "ICMP Error");

                let icmp_error = prototype
                    .into_packet(self.client_tun.v4, self.client_tun.v6)
                    .context("Failed to create ICMP error")?;

                return Ok(icmp_error);
            }
            TranslateIncomingResult::ExpiredNatSession => {
                bail!(UnroutablePacket::expired_nat_session(&packet))
            }
            TranslateIncomingResult::NoNatSession => {
                // No NAT session means packet is likely for Internet Resource or a CIDR resource.

                return Ok(packet);
            }
        };

        packet
            .translate_source(proto, ip)
            .context("Failed to translate packet to new source")?;
        packet.update_checksum();

        Ok(packet)
    }

    pub(crate) fn is_allowed(&self, resource: ResourceId) -> bool {
        self.resources.contains_key(&resource)
    }

    fn ensure_allowed_outbound(&self, packet: &IpPacket) -> anyhow::Result<()> {
        self.ensure_client_ip(packet.source())?;

        // Traffic to our own IP is allowed.
        if self.gateway_tun.is_ip(packet.destination()) {
            return Ok(());
        }

        let rid = self.classify_resource(packet.destination(), packet.destination_protocol())?;

        let Some(resource) = self.resources.get(&rid) else {
            tracing::warn!(%rid, "Internal state mismatch: No resource for ID");
            return Ok(());
        };

        flow_tracker::inbound_wg::record_resource(
            rid,
            resource.name(),
            resource.address(packet.destination()),
        );

        Ok(())
    }

    fn ensure_client_ip(&self, ip: IpAddr) -> anyhow::Result<()> {
        if !self.allowed_ips().contains(&ip) {
            return Err(anyhow::Error::new(NotClientIp(ip)));
        }

        Ok(())
    }

    /// Classifies traffic to/from a resource IP.
    ///
    /// If traffic with this resource is allowed, the resource ID is returned.
    fn classify_resource(
        &self,
        resource_ip: IpAddr,
        protocol: Result<Protocol, UnsupportedProtocol>,
    ) -> anyhow::Result<ResourceId> {
        // Note a Gateway with Internet resource should never get packets for other resources
        if let Some(rid) = self.internet_resource_enabled
            && !is_dns_addr(resource_ip)
        {
            return Ok(rid);
        }

        let (_, (filter, rid)) = self
            .filters
            .longest_match(resource_ip)
            .context("No filter")
            .context(NotAllowedResource(resource_ip))?;

        filter
            .apply(protocol)
            .context(NotAllowedResource(resource_ip))?;

        Ok(*rid)
    }

    pub fn id(&self) -> ClientId {
        self.id
    }

    pub fn client_flow_properties(&self) -> flow_tracker::ClientProperties {
        self.flow_properties.clone()
    }
}

#[derive(Debug)]
enum ResourceOnGateway {
    Cidr {
        name: String,
        network: IpNetwork,
        filters: Filters,
        expires_at: Option<DateTime<Utc>>,
    },
    Dns {
        name: String,
        address: String,
        domains: BTreeMap<DomainName, BTreeSet<IpAddr>>,
        filters: Filters,
        expires_at: Option<DateTime<Utc>>,
    },
    Internet {
        expires_at: Option<DateTime<Utc>>,
    },
}

impl ResourceOnGateway {
    fn new(resource: ResourceDescription, expires_at: Option<DateTime<Utc>>) -> Self {
        match resource {
            ResourceDescription::Dns(r) => ResourceOnGateway::Dns {
                name: r.name,
                domains: BTreeMap::default(),
                filters: r.filters,
                address: r.address,
                expires_at,
            },
            ResourceDescription::Cidr(r) => ResourceOnGateway::Cidr {
                name: r.name,
                network: r.address,
                filters: r.filters,
                expires_at,
            },
            ResourceDescription::Internet(_) => ResourceOnGateway::Internet { expires_at },
        }
    }

    fn update(&mut self, resource: &ResourceDescription) {
        match (self, resource) {
            (ResourceOnGateway::Cidr { filters, .. }, ResourceDescription::Cidr(new)) => {
                *filters = new.filters.clone();
            }
            (ResourceOnGateway::Dns { filters, .. }, ResourceDescription::Dns(new)) => {
                *filters = new.filters.clone();
            }
            (ResourceOnGateway::Internet { .. }, ResourceDescription::Internet(_)) => {
                // No-op.
            }
            (current, new) => {
                tracing::error!(?current, ?new, "Resources cannot change type");
                // TODO: This could be enforced at compile-time if we had typed resource IDs.
            }
        }
    }

    fn ips(&self) -> Vec<IpNetwork> {
        match self {
            ResourceOnGateway::Cidr { network, .. } => vec![*network],
            ResourceOnGateway::Dns { domains, .. } => domains
                .values()
                .flatten()
                .copied()
                .map(IpNetwork::from)
                .collect(),
            ResourceOnGateway::Internet { .. } => vec![
                Ipv4Network::DEFAULT_ROUTE.into(),
                Ipv6Network::DEFAULT_ROUTE.into(),
            ],
        }
    }

    fn filters(&self) -> &Filters {
        const EMPTY: &Filters = &Filters::new();

        match self {
            ResourceOnGateway::Cidr { filters, .. } => filters,
            ResourceOnGateway::Dns { filters, .. } => filters,
            ResourceOnGateway::Internet { .. } => EMPTY,
        }
    }

    fn is_allowed(&self, now: &DateTime<Utc>) -> bool {
        let Some(expires_at) = self.expires_at() else {
            return true;
        };

        expires_at > now
    }

    fn expires_at(&self) -> Option<&DateTime<Utc>> {
        match self {
            ResourceOnGateway::Cidr { expires_at, .. } => expires_at.as_ref(),
            ResourceOnGateway::Dns { expires_at, .. } => expires_at.as_ref(),
            ResourceOnGateway::Internet { expires_at } => expires_at.as_ref(),
        }
    }

    fn is_cidr(&self) -> bool {
        matches!(self, ResourceOnGateway::Cidr { .. })
    }

    fn is_dns(&self) -> bool {
        matches!(self, ResourceOnGateway::Dns { .. })
    }

    fn is_internet_resource(&self) -> bool {
        matches!(self, ResourceOnGateway::Internet { .. })
    }

    fn name(&self) -> String {
        match self {
            ResourceOnGateway::Cidr { name, .. } => name.clone(),
            ResourceOnGateway::Dns { name, .. } => name.clone(),
            ResourceOnGateway::Internet { .. } => "Internet".to_owned(),
        }
    }

    fn address(&self, dst: IpAddr) -> String {
        match self {
            ResourceOnGateway::Cidr { network, .. } => network.to_string(),
            ResourceOnGateway::Dns { address, .. } => address.clone(),
            ResourceOnGateway::Internet { .. } => match dst {
                IpAddr::V4(_) => "0.0.0.0/0".to_owned(),
                IpAddr::V6(_) => "::/0".to_owned(),
            },
        }
    }
}

// Current state of a translation for a given proxy ip
#[derive(Debug)]
struct TranslationState {
    /// Which (DNS) resource we belong to.
    resource_id: ResourceId,
    /// The IP we have resolved for the domain.
    resolved_ip: Option<IpAddr>,
    /// The domain we have resolved.
    domain: DomainName,
}

impl TranslationState {
    fn new(resource_id: ResourceId, resolved_ip: Option<IpAddr>, domain: DomainName) -> Self {
        Self {
            resource_id,
            resolved_ip,
            domain,
        }
    }
}

fn is_dns_addr(addr: IpAddr) -> bool {
    IpNetwork::from(IPV4_RESOURCES).contains(addr) || IpNetwork::from(IPV6_RESOURCES).contains(addr)
}

fn insert_filters<'a>(
    filter_store: &mut IpNetworkTable<(FilterEngine, ResourceId)>,
    ip: IpNetwork,
    id: ResourceId,
    filters: impl Iterator<Item = &'a Filters> + Clone,
) {
    let filter_engine = FilterEngine::with_filters(filters);

    tracing::trace!(%ip, filters = ?filter_engine, "Installing new filters");
    filter_store.insert(ip, (filter_engine, id));
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::{
        net::{Ipv4Addr, Ipv6Addr},
        time::Duration,
    };

    use anyhow::ErrorExt;
    use ip_packet::make::TcpFlags;

    use crate::{
        gateway::{RoutingError, nat_table},
        messages::gateway::{Filter, PortRange, ResourceDescriptionCidr},
    };

    #[test]
    fn gateway_filters_expire_individually() {
        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        let now = Utc::now();
        let then = now + Duration::from_secs(10);
        let after_then = then + Duration::from_secs(10);
        peer.add_resource(
            ResourceDescription::Cidr(ResourceDescriptionCidr {
                id: foo_resource_id(),
                address: cidr_v4_resource().into(),
                name: "cidr1".to_owned(),
                filters: vec![Filter::Tcp(PortRange {
                    port_range_start: 20,
                    port_range_end: 100,
                })],
            }),
            Some(then),
        );
        peer.add_resource(
            ResourceDescription::Cidr(ResourceDescriptionCidr {
                id: bar_resource_id(),
                address: cidr_v4_resource().into(),
                name: "cidr2".to_owned(),
                filters: vec![Filter::Udp(PortRange {
                    port_range_start: 20,
                    port_range_end: 100,
                })],
            }),
            Some(after_then),
        );

        let tcp_packet = ip_packet::make::tcp_packet(
            client_tun_ipv4(),
            cidr_v4_resource().hosts().next().unwrap(),
            5401,
            80,
            TcpFlags::default(),
            vec![0; 100],
        )
        .unwrap();

        let udp_packet = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            cidr_v4_resource().hosts().next().unwrap(),
            5401,
            80,
            vec![0; 100],
        )
        .unwrap();

        peer.expire_resources(now);

        assert!(
            peer.classify_resource(tcp_packet.destination(), tcp_packet.destination_protocol())
                .is_ok()
        );
        assert!(
            peer.classify_resource(udp_packet.destination(), udp_packet.destination_protocol())
                .is_ok()
        );

        peer.expire_resources(then);

        assert!(
            peer.classify_resource(tcp_packet.destination(), tcp_packet.destination_protocol())
                .is_err()
        );
        assert!(
            peer.classify_resource(udp_packet.destination(), udp_packet.destination_protocol())
                .is_ok()
        );

        peer.expire_resources(after_then);

        assert!(
            peer.classify_resource(tcp_packet.destination(), tcp_packet.destination_protocol())
                .is_err()
        );
        assert!(
            peer.classify_resource(udp_packet.destination(), udp_packet.destination_protocol())
                .is_err()
        );
    }

    #[test]
    fn allows_packets_for_and_from_gateway_tun_ip() {
        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );

        let request = ip_packet::make::tcp_packet(
            client_tun_ipv4(),
            gateway_tun_ipv4(),
            5401,
            80,
            TcpFlags::default(),
            vec![0; 100],
        )
        .unwrap();

        let response = ip_packet::make::tcp_packet(
            gateway_tun_ipv4(),
            client_tun_ipv4(),
            80,
            5401,
            TcpFlags::default(),
            vec![0; 100],
        )
        .unwrap();

        assert!(matches!(
            peer.translate_outbound(request, Instant::now()).unwrap(),
            TranslateOutboundResult::Send(_)
        ));
        peer.translate_inbound(response, Instant::now()).unwrap();
    }

    #[test]
    fn dns_and_cidr_filters_dot_mix() {
        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        peer.add_resource(foo_dns_resource(), None);
        peer.add_resource(bar_cidr_resource(), None);
        peer.setup_nat(
            foo_name().parse().unwrap(),
            foo_resource_id(),
            BTreeSet::from([foo_real_ip1().into()]),
            BTreeSet::from([proxy_ip4_1()]),
        )
        .unwrap();

        assert_eq!(bar_contained_ip(), foo_real_ip1());

        let pkt = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            bar_contained_ip(),
            1,
            bar_allowed_port(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        assert!(peer.translate_outbound(pkt, Instant::now()).is_ok());

        let pkt = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            bar_contained_ip(),
            1,
            foo_allowed_port(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        assert!(matches!(
            peer.translate_outbound(pkt, Instant::now()).unwrap(),
            TranslateOutboundResult::Filtered(_)
        ));

        let pkt = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            proxy_ip4_1(),
            1,
            bar_allowed_port(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        assert!(matches!(
            peer.translate_outbound(pkt, Instant::now()).unwrap(),
            TranslateOutboundResult::Filtered(_)
        ));

        let pkt = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            proxy_ip4_1(),
            1,
            foo_allowed_port(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        assert!(peer.translate_outbound(pkt, Instant::now()).is_ok());
    }

    #[test]
    fn internet_resource_doesnt_allow_all_traffic_for_dns_resources() {
        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        peer.add_resource(foo_dns_resource(), None);
        peer.add_resource(internet_resource(), None);
        peer.setup_nat(
            foo_name().parse().unwrap(),
            foo_resource_id(),
            BTreeSet::from([foo_real_ip1().into()]),
            BTreeSet::from([proxy_ip4_1()]),
        )
        .unwrap();

        let pkt = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            proxy_ip4_1(),
            1,
            foo_allowed_port(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        assert!(peer.translate_outbound(pkt, Instant::now()).is_ok());

        let pkt = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            proxy_ip4_1(),
            1,
            600,
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        assert!(matches!(
            peer.translate_outbound(pkt, Instant::now()).unwrap(),
            TranslateOutboundResult::Filtered(_)
        ));

        let pkt = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            "1.1.1.1".parse::<Ipv4Addr>().unwrap(),
            1,
            600,
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        assert!(peer.translate_outbound(pkt, Instant::now()).is_ok());
    }

    #[test]
    fn dns_resource_packet_is_dropped_after_nat_session_expires() {
        let _guard = logging::test("trace");

        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        peer.add_resource(foo_dns_resource(), None);
        peer.setup_nat(
            foo_name().parse().unwrap(),
            foo_resource_id(),
            BTreeSet::from([foo_real_ip1().into()]),
            BTreeSet::from([proxy_ip4_1()]),
        )
        .unwrap();

        let request = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            proxy_ip4_1(),
            1,
            foo_allowed_port(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        let mut now = Instant::now();

        assert!(matches!(
            peer.translate_outbound(request, now),
            Ok(TranslateOutboundResult::Send(_))
        ));

        let response = ip_packet::make::udp_packet(
            foo_real_ip1(),
            client_tun_ipv4(),
            foo_allowed_port(),
            1,
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        now += Duration::from_secs(30);
        peer.handle_timeout(now);

        peer.translate_inbound(response, now).unwrap();

        let response = ip_packet::make::udp_packet(
            foo_real_ip1(),
            client_tun_ipv4(),
            foo_allowed_port(),
            1,
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        now += nat_table::UDP_TTL;
        peer.handle_timeout(now);

        #[expect(clippy::disallowed_methods, reason = "This is a test.")]
        let err = peer
            .translate_inbound(response, now)
            .unwrap_err()
            .downcast::<UnroutablePacket>()
            .unwrap();

        assert_eq!(err.reason(), RoutingError::ExpiredNatSession);
    }

    #[test]
    fn setting_up_dns_resource_nat_does_not_clear_existing_nat_session() {
        let _guard = logging::test("trace");

        let now = Instant::now();

        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        peer.add_resource(foo_dns_resource(), None);
        peer.setup_nat(
            foo_name().parse().unwrap(),
            foo_resource_id(),
            BTreeSet::from([foo_real_ip1().into()]),
            BTreeSet::from([proxy_ip4_1(), proxy_ip4_2()]),
        )
        .unwrap();

        {
            let request = ip_packet::make::udp_packet(
                client_tun_ipv4(),
                proxy_ip4_1(),
                1,
                foo_allowed_port(),
                vec![0, 0, 0, 0, 0, 0, 0, 0],
            )
            .unwrap();

            let result = peer.translate_outbound(request.clone(), now).unwrap();

            assert!(matches!(result, TranslateOutboundResult::Send(_)));

            peer.setup_nat(
                foo_name().parse().unwrap(),
                foo_resource_id(),
                BTreeSet::from([foo_real_ip2().into()]), // Setting up with a new IP!
                BTreeSet::from([proxy_ip4_1(), proxy_ip4_2()]),
            )
            .unwrap();

            let result = peer.translate_outbound(request, now).unwrap();

            assert!(matches!(result, TranslateOutboundResult::Send(_)));

            let response = ip_packet::make::udp_packet(
                foo_real_ip1(),
                client_tun_ipv4(),
                foo_allowed_port(),
                1,
                vec![0, 0, 0, 0, 0, 0, 0, 0],
            )
            .unwrap();

            peer.translate_inbound(response, now).unwrap();
        }

        {
            let request = ip_packet::make::udp_packet(
                client_tun_ipv4(),
                proxy_ip4_1(),
                2, // Using a new source port
                foo_allowed_port(),
                vec![0, 0, 0, 0, 0, 0, 0, 0],
            )
            .unwrap();

            let result = peer.translate_outbound(request, now).unwrap();

            let TranslateOutboundResult::Send(outside_packet) = result else {
                panic!("Wrong result");
            };

            assert_eq!(
                outside_packet.destination(),
                foo_real_ip2(),
                "Request with a new source port should use new IP"
            );

            let response = ip_packet::make::udp_packet(
                foo_real_ip2(),
                client_tun_ipv4(),
                foo_allowed_port(),
                2,
                vec![0, 0, 0, 0, 0, 0, 0, 0],
            )
            .unwrap();

            peer.translate_inbound(response, now).unwrap();
        }
    }

    #[test]
    fn setting_up_dns_resource_nat_with_new_proxy_ips_resets_state() {
        let _guard = logging::test("trace");

        let now = Instant::now();

        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        peer.add_resource(foo_dns_resource(), None);
        peer.add_resource(baz_dns_resource(), None);
        peer.setup_nat(
            foo_name().parse().unwrap(),
            foo_resource_id(),
            BTreeSet::from([foo_real_ip1().into()]),
            BTreeSet::from([proxy_ip4_1(), proxy_ip4_2()]),
        )
        .unwrap();

        let request = ip_packet::make::udp_packet(
            client_tun_ipv4(),
            proxy_ip4_1(),
            1,
            foo_allowed_port(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        let TranslateOutboundResult::Send(packet) =
            peer.translate_outbound(request.clone(), now).unwrap()
        else {
            panic!("Bad translation result")
        };

        assert_eq!(packet.destination(), foo_real_ip1());

        // Client resets state, setup baz resource first with proxy IP 1

        peer.setup_nat(
            baz_name().parse().unwrap(),
            baz_resource_id(),
            BTreeSet::from([baz_real_ip1().into()]),
            BTreeSet::from([proxy_ip4_1(), proxy_ip4_2()]),
        )
        .unwrap();

        let TranslateOutboundResult::Send(packet) = peer.translate_outbound(request, now).unwrap()
        else {
            panic!("Bad translation result")
        };

        assert_eq!(packet.destination(), baz_real_ip1());
    }

    #[test]
    fn setup_dns_resource_nat_ipv4_only_adds_ipv6_translation_state_entries() {
        let _guard = logging::test("trace");

        let now = Instant::now();

        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        peer.add_resource(foo_dns_resource(), None);
        peer.setup_nat(
            foo_name().parse().unwrap(),
            foo_resource_id(),
            BTreeSet::from([foo_real_ip1().into()]),
            BTreeSet::from([proxy_ip4_1(), proxy_ip4_2(), proxy_ip6_1(), proxy_ip6_2()]),
        )
        .unwrap();

        let request = ip_packet::make::udp_packet(
            client_tun_ipv6(),
            proxy_ip6_1(),
            1,
            foo_allowed_port(),
            vec![0, 0, 0, 0, 0, 0, 0, 0],
        )
        .unwrap();

        let TranslateOutboundResult::DestinationUnreachable(packet) =
            peer.translate_outbound(request, now).unwrap()
        else {
            panic!("Bad translation result")
        };

        assert_eq!(packet.destination(), client_tun_ipv6());

        assert!(peer.permanent_translations.contains_key(&proxy_ip4_1()));
        assert!(peer.permanent_translations.contains_key(&proxy_ip4_2()));
        assert!(peer.permanent_translations.contains_key(&proxy_ip6_1()));
        assert!(peer.permanent_translations.contains_key(&proxy_ip6_2()));
    }

    #[test]
    fn no_translate_outbound_icmp_error() {
        let _guard = logging::test("trace");

        let now = Instant::now();

        let mut peer = ClientOnGateway::new(
            client_id(),
            client_tun(),
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );

        let icmp_unreachable = ip_packet::make::icmp_dest_unreachable_network(
            &ip_packet::make::udp_packet(proxy_ip4_1(), client_tun_ipv4(), 443, 50000, vec![])
                .unwrap(),
        )
        .unwrap();

        let error = peer.translate_outbound(icmp_unreachable, now).unwrap_err();
        let error = error.any_downcast_ref::<UnroutablePacket>().unwrap();

        assert_eq!(error.to_string(), "Unroutable packet: OutboundIcmpError");
        assert_eq!(error.source().to_string(), "100.64.0.1");
        assert_eq!(error.destination().to_string(), "100.96.0.1");
        assert_eq!(error.proto().to_string(), "ICMP");
    }

    fn foo_dns_resource() -> crate::messages::gateway::ResourceDescription {
        crate::messages::gateway::ResourceDescription::Dns(
            crate::messages::gateway::ResourceDescriptionDns {
                id: foo_resource_id(),
                address: foo_name(),
                name: "foo".to_string(),
                filters: vec![Filter::Udp(PortRange {
                    port_range_end: foo_allowed_port(),
                    port_range_start: foo_allowed_port(),
                })],
            },
        )
    }

    fn baz_dns_resource() -> crate::messages::gateway::ResourceDescription {
        crate::messages::gateway::ResourceDescription::Dns(
            crate::messages::gateway::ResourceDescriptionDns {
                id: baz_resource_id(),
                address: baz_name(),
                name: "baz".to_string(),
                filters: vec![],
            },
        )
    }

    fn bar_cidr_resource() -> crate::messages::gateway::ResourceDescription {
        crate::messages::gateway::ResourceDescription::Cidr(
            crate::messages::gateway::ResourceDescriptionCidr {
                id: bar_resource_id(),
                address: bar_address(),
                name: "foo".to_string(),
                filters: vec![Filter::Udp(PortRange {
                    port_range_end: bar_allowed_port(),
                    port_range_start: bar_allowed_port(),
                })],
            },
        )
    }

    fn internet_resource() -> crate::messages::gateway::ResourceDescription {
        crate::messages::gateway::ResourceDescription::Internet(
            crate::messages::gateway::ResourceDescriptionInternet {
                id: "ed29c148-2acf-4ceb-8db5-d796c267163a".parse().unwrap(),
            },
        )
    }

    fn foo_allowed_port() -> u16 {
        80
    }

    fn bar_allowed_port() -> u16 {
        443
    }

    fn foo_real_ip1() -> Ipv4Addr {
        "10.0.0.1".parse().unwrap()
    }

    fn foo_real_ip2() -> Ipv4Addr {
        "10.0.0.2".parse().unwrap()
    }

    fn baz_real_ip1() -> Ipv4Addr {
        "192.168.0.1".parse().unwrap()
    }

    fn bar_contained_ip() -> Ipv4Addr {
        "10.0.0.1".parse().unwrap()
    }

    fn proxy_ip4_1() -> IpAddr {
        "100.96.0.1".parse().unwrap()
    }

    fn proxy_ip4_2() -> IpAddr {
        "100.96.0.2".parse().unwrap()
    }

    fn proxy_ip6_1() -> IpAddr {
        "fd00:2021:1111:8000::".parse().unwrap()
    }

    fn proxy_ip6_2() -> IpAddr {
        "fd00:2021:1111:8000::1".parse().unwrap()
    }

    fn foo_name() -> String {
        "foo.com".to_string()
    }

    fn baz_name() -> String {
        "baz.com".to_string()
    }

    fn bar_address() -> IpNetwork {
        "10.0.0.0/24".parse().unwrap()
    }

    fn client_tun() -> IpConfig {
        IpConfig {
            v4: client_tun_ipv4(),
            v6: client_tun_ipv6(),
        }
    }

    fn client_tun_ipv4() -> Ipv4Addr {
        "100.64.0.1".parse().unwrap()
    }

    fn client_tun_ipv6() -> Ipv6Addr {
        "fd00:2021:1111::1".parse().unwrap()
    }

    pub fn gateway_tun() -> IpConfig {
        IpConfig {
            v4: gateway_tun_ipv4(),
            v6: gateway_tun_ipv6(),
        }
    }

    pub fn gateway_tun_ipv4() -> Ipv4Addr {
        "100.64.0.2".parse().unwrap()
    }

    pub fn gateway_tun_ipv6() -> Ipv6Addr {
        "fd00:2021:1111::2".parse().unwrap()
    }

    fn cidr_v4_resource() -> Ipv4Network {
        "10.0.0.0/24".parse().unwrap()
    }

    fn foo_resource_id() -> ResourceId {
        "9d4b79f6-1db7-4cb3-a077-712102204d73".parse().unwrap()
    }

    fn bar_resource_id() -> ResourceId {
        "ed29c148-2acf-4ceb-8db5-d796c2671631".parse().unwrap()
    }

    fn baz_resource_id() -> ResourceId {
        "40b725b2-5904-46fd-b739-756f7d1cbb88".parse().unwrap()
    }

    fn client_id() -> ClientId {
        "9d4b79f6-1db7-4cb3-a077-712102204d73".parse().unwrap()
    }
}

#[cfg(all(test, feature = "proptest"))]
mod proptests {
    use super::tests::*;
    use super::*;
    use crate::messages::gateway::{
        Filter, PortRange, ResourceDescription, ResourceDescriptionCidr,
    };
    use crate::proptest::*;
    use ip_packet::make::{TcpFlags, icmp_request_packet, tcp_packet, udp_packet};
    use itertools::Itertools as _;
    use proptest::{
        arbitrary::any,
        collection, prop_oneof,
        sample::select,
        strategy::{Just, Strategy},
    };
    use rangemap::RangeInclusiveSet;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::{collections::BTreeSet, ops::RangeInclusive};
    use test_strategy::Arbitrary;

    #[test_strategy::proptest()]
    fn gateway_accepts_allowed_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(cidr_resources(filters_with_allowed_protocol(), 5))] resources: Vec<(
            ResourceDescription,
            Protocol,
            IpAddr,
        )>,
        #[strategy(any::<Ipv4Addr>())] client_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] client_v6: Ipv6Addr,
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        // This test could be extended to test multiple src
        let mut peer = ClientOnGateway::new(
            client_id,
            IpConfig {
                v4: client_v4,
                v6: client_v6,
            },
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        for (resource, _, _) in &resources {
            peer.add_resource(resource.clone(), None);
        }

        for (_, protocol, dest) in &resources {
            let src = if dest.is_ipv4() {
                client_v4.into()
            } else {
                client_v6.into()
            };

            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(
                    src,
                    *dest,
                    sport,
                    *dport,
                    TcpFlags::default(),
                    payload.clone(),
                ),
                Protocol::Udp { dport } => udp_packet(src, *dest, sport, *dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, *dest, 1, 0, &[]),
            }
            .unwrap();
            assert!(
                peer.classify_resource(packet.destination(), packet.destination_protocol())
                    .is_ok()
            );
        }
    }

    #[test_strategy::proptest()]
    fn gateway_accepts_different_resources_with_same_ip_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(collection::btree_set(resource_id(), 10))] resources_ids: BTreeSet<ResourceId>,
        #[strategy(any::<Ipv4Addr>())] client_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] client_v6: Ipv6Addr,
        #[strategy(cidr_with_host())] config: (IpNetwork, IpAddr),
        #[strategy(collection::vec(filters_with_allowed_protocol(), 1..=10))] protocol_config: Vec<
            (Filters, Protocol),
        >,
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (resource_addr, dest) = config;
        let src = if dest.is_ipv4() {
            client_v4.into()
        } else {
            client_v6.into()
        };
        let mut peer = ClientOnGateway::new(
            client_id,
            IpConfig {
                v4: client_v4,
                v6: client_v6,
            },
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );

        for ((filters, _), resource_id) in std::iter::zip(&protocol_config, resources_ids) {
            // This test could be extended to test multiple src
            peer.add_resource(
                ResourceDescription::Cidr(ResourceDescriptionCidr {
                    id: resource_id,
                    address: resource_addr,
                    name: String::new(),
                    filters: filters.clone(),
                }),
                None,
            );
        }

        for (_, protocol) in protocol_config {
            let packet = match protocol {
                Protocol::Tcp { dport } => tcp_packet(
                    src,
                    dest,
                    sport,
                    dport,
                    TcpFlags::default(),
                    payload.clone(),
                ),
                Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload.clone()),
                Protocol::Icmp => icmp_request_packet(src, dest, 1, 0, &[]),
            }
            .unwrap();

            assert!(
                peer.classify_resource(packet.destination(), packet.destination_protocol())
                    .is_ok()
            );
        }
    }

    #[test_strategy::proptest()]
    fn gateway_reject_unallowed_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(resource_id())] resource_id: ResourceId,
        #[strategy(any::<Ipv4Addr>())] client_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] client_v6: Ipv6Addr,
        #[strategy(cidr_with_host())] config: (IpNetwork, IpAddr),
        #[strategy(filters_with_rejected_protocol())] protocol_config: (Filters, Protocol),
        #[strategy(any::<u16>())] sport: u16,
        #[strategy(any::<Vec<u8>>())] payload: Vec<u8>,
    ) {
        let (resource_addr, dest) = config;
        let src = if dest.is_ipv4() {
            client_v4.into()
        } else {
            client_v6.into()
        };
        let (filters, protocol) = protocol_config;
        // This test could be extended to test multiple src
        let mut peer = ClientOnGateway::new(
            client_id,
            IpConfig {
                v4: client_v4,
                v6: client_v6,
            },
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );
        let packet = match protocol {
            Protocol::Tcp { dport } => {
                tcp_packet(src, dest, sport, dport, TcpFlags::default(), payload)
            }
            Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload),
            Protocol::Icmp => icmp_request_packet(src, dest, 1, 0, &[]),
        }
        .unwrap();

        peer.add_resource(
            ResourceDescription::Cidr(ResourceDescriptionCidr {
                id: resource_id,
                address: resource_addr,
                name: String::new(),
                filters,
            }),
            None,
        );

        assert!(
            peer.classify_resource(packet.destination(), packet.destination_protocol())
                .is_err()
        );
    }

    #[test_strategy::proptest()]
    fn gateway_reject_removed_filter_packet(
        #[strategy(client_id())] client_id: ClientId,
        #[strategy(resource_id())] resource_id_allowed: ResourceId,
        #[strategy(resource_id())] resource_id_removed: ResourceId,
        #[strategy(any::<Ipv4Addr>())] client_v4: Ipv4Addr,
        #[strategy(any::<Ipv6Addr>())] client_v6: Ipv6Addr,
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
            client_v4.into()
        } else {
            client_v6.into()
        };
        let ((filters_allowed, protocol_allowed), (filters_removed, protocol_removed)) =
            protocol_config;
        // This test could be extended to test multiple src
        let mut peer = ClientOnGateway::new(
            client_id,
            IpConfig {
                v4: client_v4,
                v6: client_v6,
            },
            gateway_tun(),
            flow_tracker::ClientProperties::default(),
        );

        let packet_allowed = match protocol_allowed {
            Protocol::Tcp { dport } => tcp_packet(
                src,
                dest,
                sport,
                dport,
                TcpFlags::default(),
                payload.clone(),
            ),
            Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload.clone()),
            Protocol::Icmp => icmp_request_packet(src, dest, 1, 0, &[]),
        }
        .unwrap();

        let packet_rejected = match protocol_removed {
            Protocol::Tcp { dport } => {
                tcp_packet(src, dest, sport, dport, TcpFlags::default(), payload)
            }
            Protocol::Udp { dport } => udp_packet(src, dest, sport, dport, payload),
            Protocol::Icmp => icmp_request_packet(src, dest, 1, 0, &[]),
        }
        .unwrap();

        peer.add_resource(
            ResourceDescription::Cidr(ResourceDescriptionCidr {
                id: resource_id_allowed,
                address: supernet(resource_addr).unwrap_or(resource_addr),
                name: String::new(),
                filters: filters_allowed,
            }),
            None,
        );

        peer.add_resource(
            ResourceDescription::Cidr(ResourceDescriptionCidr {
                id: resource_id_removed,
                address: resource_addr,
                name: String::new(),
                filters: filters_removed,
            }),
            None,
        );
        peer.remove_resource(&resource_id_removed);

        assert!(
            peer.classify_resource(
                packet_allowed.destination(),
                packet_allowed.destination_protocol()
            )
            .is_ok()
        );
        assert!(
            peer.classify_resource(
                packet_rejected.destination(),
                packet_rejected.destination_protocol()
            )
            .is_err()
        );
    }

    fn cidr_resources(
        filters: impl Strategy<Value = (Filters, Protocol)>,
        num: usize,
    ) -> impl Strategy<Value = Vec<(ResourceDescription, Protocol, IpAddr)>> {
        let ids = collection::btree_set(resource_id(), num);
        let networks = collection::vec(cidr_with_host(), num);
        let filters = collection::vec(filters, num);

        (ids, networks, filters).prop_map(|(ids, networks, filters)| {
            itertools::izip!(ids, networks, filters)
                .map(|(id, (address, host), (filters, protocol))| {
                    (
                        ResourceDescription::Cidr(ResourceDescriptionCidr {
                            id,
                            address,
                            name: String::new(),
                            filters,
                        }),
                        protocol,
                        host,
                    )
                })
                .collect()
        })
    }

    fn cidr_with_host() -> impl Strategy<Value = (IpNetwork, IpAddr)> {
        any_ip_network(8).prop_flat_map(|net| host(net).prop_map(move |host| (net, host)))
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

    fn non_overlapping_non_empty_filters_with_allowed_protocol()
    -> impl Strategy<Value = ((Filters, Protocol), (Filters, Protocol))> {
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
                any::<ProtocolKind>()
                    .prop_filter_map("If ICMP is contained there is no way to generate gaps", {
                        let f = f.clone();

                        move |p| {
                            (p != ProtocolKind::Icmp || !f.contains(&Filter::Icmp)).then_some(p)
                        }
                    })
                    .prop_filter("no gaps in port ranges", {
                        let f = f.clone();

                        move |p| !gaps(f.clone(), *p).is_empty()
                    })
                    .prop_flat_map(move |p| {
                        if p == ProtocolKind::Icmp {
                            Just((f.clone(), Protocol::Icmp)).boxed()
                        } else {
                            select(gaps(f.clone(), p))
                                .prop_flat_map({
                                    let f = f.clone();

                                    move |g| {
                                        g.prop_map({
                                            let f = f.clone();

                                            move |dport| (f.clone(), p.into_protocol(dport))
                                        })
                                    }
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
