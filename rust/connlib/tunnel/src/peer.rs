use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::time::Instant;

use bimap::BiMap;
use chrono::{DateTime, Utc};
use connlib_shared::messages::{DnsServer, ResourceId};
use connlib_shared::IpProvider;
use connlib_shared::{Error, Result};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use pnet_packet::Packet;

use crate::control_protocol::gateway::ResourceDescription;
use crate::ip_packet::MutableIpPacket;

type ExpiryingResource = (ResourceDescription, Option<DateTime<Utc>>);

// The max time a dns request can be configured to live in resolvconf
// is 30 seconds. See resolvconf(5) timeout.
const IDS_EXPIRE: std::time::Duration = std::time::Duration::from_secs(60);

pub struct Peer<TId, TTransform, TResource> {
    // TODO: we should refactor this
    // in the gateway-side this means that we are explicit about ()
    // maybe duping the Peer struct is the way to go
    pub allowed_ips: IpNetworkTable<TResource>,
    pub conn_id: TId,
    pub transform: TTransform,
}

impl<TId, TTransform> Peer<TId, TTransform, HashSet<ResourceId>>
where
    TId: Copy,
    TTransform: PacketTransform,
{
    pub(crate) fn insert_id(&mut self, ip: &IpNetwork, id: &ResourceId) {
        if let Some(resources) = self.allowed_ips.exact_match_mut(*ip) {
            resources.insert(*id);
        } else {
            let mut resources = HashSet::new();
            resources.insert(*id);
            self.allowed_ips.insert(*ip, resources);
        }
    }
}

impl<TId, TTransform, TResource> Peer<TId, TTransform, TResource>
where
    TId: Copy,
    TTransform: PacketTransform,
{
    pub(crate) fn new(conn_id: TId, transform: TTransform) -> Peer<TId, TTransform, TResource> {
        Peer {
            allowed_ips: IpNetworkTable::new(),
            conn_id,
            transform,
        }
    }

    fn is_allowed(&self, addr: IpAddr) -> bool {
        self.allowed_ips.longest_match(addr).is_some()
    }

    /// Sends the given packet to this peer by encapsulating it in a wireguard packet.
    pub(crate) fn transform<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
    ) -> Option<MutableIpPacket<'a>> {
        self.transform.packet_transform(packet)
    }

    pub(crate) fn untransform<'b>(
        &mut self,
        packet: MutableIpPacket<'b>,
    ) -> Result<MutableIpPacket<'b>> {
        let (packet, addr) = self.transform.packet_untransform(packet)?;

        if !self.is_allowed(addr) {
            return Err(Error::UnallowedPacket);
        }

        Ok(packet)
    }
}

pub struct PacketTransformGateway {
    resources: IpNetworkTable<ExpiryingResource>,
}

impl Default for PacketTransformGateway {
    fn default() -> Self {
        Self {
            resources: IpNetworkTable::new(),
        }
    }
}

#[derive(Default)]
pub struct PacketTransformClient {
    pub translations: BiMap<IpAddr, IpAddr>,
    dns_mapping: BiMap<IpAddr, DnsServer>,
    mangled_dns_ids: HashMap<u16, std::time::Instant>,
}

impl PacketTransformClient {
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
        self.dns_mapping = mapping;
    }
}

impl PacketTransformGateway {
    pub(crate) fn is_emptied(&self) -> bool {
        self.resources.is_empty()
    }

    pub(crate) fn expire_resources(&mut self) {
        self.resources
            .retain(|_, (_, e)| !e.is_some_and(|e| e <= Utc::now()));
    }

    pub(crate) fn remove_resource(&mut self, resource: &ResourceId) {
        self.resources.retain(|_, (r, _)| match r {
            connlib_shared::messages::ResourceDescription::Dns(r) => r.id != *resource,
            connlib_shared::messages::ResourceDescription::Cidr(r) => r.id != *resource,
        })
    }

    pub(crate) fn add_resource(
        &mut self,
        ip: IpNetwork,
        resource: ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
    ) {
        self.resources.insert(ip, (resource, expires_at));
    }
}

pub trait PacketTransform {
    fn packet_untransform<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
    ) -> Result<(MutableIpPacket<'a>, IpAddr)>;

    fn packet_transform<'a>(&mut self, packet: MutableIpPacket<'a>) -> Option<MutableIpPacket<'a>>;
}

impl PacketTransform for PacketTransformGateway {
    fn packet_untransform<'a>(
        &mut self,
        packet: MutableIpPacket<'a>,
    ) -> Result<(MutableIpPacket<'a>, IpAddr)> {
        let addr = packet.source();
        let dst = packet.destination();

        if self.resources.longest_match(dst).is_none() {
            tracing::warn!(%dst, "unallowed packet");
            return Err(Error::InvalidDst);
        }

        Ok((packet, addr))
    }

    fn packet_transform<'a>(&mut self, packet: MutableIpPacket<'a>) -> Option<MutableIpPacket<'a>> {
        Some(packet)
    }
}

impl PacketTransform for PacketTransformClient {
    fn packet_untransform<'a>(
        &mut self,
        mut pkt: MutableIpPacket<'a>,
    ) -> Result<(MutableIpPacket<'a>, IpAddr)> {
        let addr = pkt.source();
        let mut src = *self.translations.get_by_right(&addr).unwrap_or(&addr);

        let original_src = src;
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

        Ok((pkt, original_src))
    }

    fn packet_transform<'a>(
        &mut self,
        mut packet: MutableIpPacket<'a>,
    ) -> Option<MutableIpPacket<'a>> {
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

        Some(packet)
    }
}
