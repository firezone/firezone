use std::borrow::Cow;
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::Instant;

use arc_swap::ArcSwap;
use bimap::BiMap;
use boringtun::noise::Tunn;
use chrono::{DateTime, Utc};
use connlib_shared::messages::DnsServer;
use connlib_shared::IpProvider;
use connlib_shared::{Error, Result};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use parking_lot::{Mutex, RwLock};
use pnet_packet::Packet;

use crate::control_protocol::gateway::ResourceDescription;
use crate::{device_channel, ip_packet::MutableIpPacket};

type ExpiryingResource = (ResourceDescription, Option<DateTime<Utc>>);

// The max time a dns request can be configured to live in resolvconf
// is 30 seconds. See resolvconf(5) timeout.
const IDS_EXPIRE: std::time::Duration = std::time::Duration::from_secs(60);

pub struct Peer<TId, TTransform> {
    allowed_ips: RwLock<IpNetworkTable<()>>,
    pub conn_id: TId,
    pub transform: TTransform,
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct PeerStats<TId> {
    pub allowed_ips: Vec<IpNetwork>,
    pub conn_id: TId,
}

impl<TId, TTransform> Peer<TId, TTransform>
where
    TId: Copy,
    TTransform: PacketTransform,
{
    pub fn stats(&self) -> PeerStats<TId> {
        let allowed_ips = self.allowed_ips.read().iter().map(|(ip, _)| ip).collect();
        PeerStats {
            allowed_ips,
            conn_id: self.conn_id,
        }
    }

    pub(crate) fn new(
        ips: Vec<IpNetwork>,
        conn_id: TId,
        transform: TTransform,
    ) -> Peer<TId, TTransform> {
        let mut allowed_ips = IpNetworkTable::new();
        for ip in ips {
            allowed_ips.insert(ip, ());
        }
        let allowed_ips = RwLock::new(allowed_ips);

        Peer {
            allowed_ips,
            conn_id,
            transform,
        }
    }

    pub(crate) fn add_allowed_ip(&self, ip: IpNetwork) {
        self.allowed_ips.write().insert(ip, ());
    }

    fn is_allowed(&self, addr: IpAddr) -> bool {
        self.allowed_ips.read().longest_match(addr).is_some()
    }

    /// Sends the given packet to this peer by encapsulating it in a wireguard packet.
    pub(crate) fn transform<'a>(&self, packet: MutableIpPacket<'a>) -> Option<MutableIpPacket<'a>> {
        self.transform.packet_transform(packet)
    }

    pub(crate) fn untransform<'b>(
        &self,
        addr: IpAddr,
        packet: &'b mut [u8],
    ) -> Result<device_channel::Packet<'b>> {
        let (packet, addr) = self.transform.packet_untransform(&addr, packet)?;

        if !self.is_allowed(addr) {
            return Err(Error::UnallowedPacket);
        }

        Ok(packet)
    }
}

pub struct PacketTransformGateway {
    resources: RwLock<IpNetworkTable<ExpiryingResource>>,
}

impl Default for PacketTransformGateway {
    fn default() -> Self {
        Self {
            resources: RwLock::new(IpNetworkTable::new()),
        }
    }
}

#[derive(Default)]
pub struct PacketTransformClient {
    translations: RwLock<BiMap<IpAddr, IpAddr>>,
    dns_mapping: ArcSwap<BiMap<IpAddr, DnsServer>>,
    mangled_dns_ids: Mutex<HashMap<u16, std::time::Instant>>,
}

impl PacketTransformClient {
    pub fn get_or_assign_translation(
        &self,
        ip: &IpAddr,
        ip_provider: &mut IpProvider,
    ) -> Option<IpAddr> {
        let mut translations = self.translations.write();
        if let Some(proxy_ip) = translations.get_by_right(ip) {
            return Some(*proxy_ip);
        }

        let proxy_ip = ip_provider.get_proxy_ip_for(ip)?;

        translations.insert(proxy_ip, *ip);
        Some(proxy_ip)
    }

    pub fn expire_dns_track(&self) {
        self.mangled_dns_ids
            .lock()
            .retain(|_, exp| exp.elapsed() < IDS_EXPIRE);
    }

    pub fn set_dns(&self, mapping: BiMap<IpAddr, DnsServer>) {
        self.dns_mapping.store(Arc::new(mapping));
    }
}

impl PacketTransformGateway {
    pub(crate) fn is_emptied(&self) -> bool {
        self.resources.read().is_empty()
    }

    pub(crate) fn expire_resources(&self) {
        self.resources
            .write()
            .retain(|_, (_, e)| !e.is_some_and(|e| e <= Utc::now()));
    }

    pub(crate) fn add_resource(
        &self,
        ip: IpNetwork,
        resource: ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
    ) {
        self.resources.write().insert(ip, (resource, expires_at));
    }
}

pub trait PacketTransform {
    fn packet_untransform<'a>(
        &self,
        addr: &IpAddr,
        packet: &'a mut [u8],
    ) -> Result<(device_channel::Packet<'a>, IpAddr)>;

    fn packet_transform<'a>(&self, packet: MutableIpPacket<'a>) -> Option<MutableIpPacket<'a>>;
}

impl PacketTransform for PacketTransformGateway {
    fn packet_untransform<'a>(
        &self,
        addr: &IpAddr,
        packet: &'a mut [u8],
    ) -> Result<(device_channel::Packet<'a>, IpAddr)> {
        let Some(dst) = Tunn::dst_address(packet) else {
            return Err(Error::BadPacket);
        };

        if self.resources.read().longest_match(dst).is_some() {
            let packet = make_packet(packet, addr);
            Ok((packet, *addr))
        } else {
            tracing::warn!(%dst, "unallowed packet");
            Err(Error::InvalidDst)
        }
    }

    fn packet_transform<'a>(&self, packet: MutableIpPacket<'a>) -> Option<MutableIpPacket<'a>> {
        Some(packet)
    }
}

impl PacketTransform for PacketTransformClient {
    fn packet_untransform<'a>(
        &self,
        addr: &IpAddr,
        packet: &'a mut [u8],
    ) -> Result<(device_channel::Packet<'a>, IpAddr)> {
        let translations = self.translations.read();
        let mut src = *translations.get_by_right(addr).unwrap_or(addr);

        let Some(mut pkt) = MutableIpPacket::new(packet) else {
            return Err(Error::BadPacket);
        };

        let original_src = src;
        if let Some(dgm) = pkt.as_udp() {
            if let Some(sentinel) = self
                .dns_mapping
                .load()
                .as_ref()
                .get_by_right(&(src, dgm.get_source()).into())
            {
                if let Ok(message) = domain::base::Message::from_slice(dgm.payload()) {
                    if self
                        .mangled_dns_ids
                        .lock()
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
        let packet = make_packet(packet, addr);
        Ok((packet, original_src))
    }

    fn packet_transform<'a>(&self, mut packet: MutableIpPacket<'a>) -> Option<MutableIpPacket<'a>> {
        if let Some(translated_ip) = self.translations.read().get_by_left(&packet.destination()) {
            packet.set_dst(*translated_ip);
            packet.update_checksum();
        }

        if let Some(srv) = self
            .dns_mapping
            .load()
            .as_ref()
            .get_by_left(&packet.destination())
        {
            if let Some(dgm) = packet.as_udp() {
                if let Ok(message) = domain::base::Message::from_slice(dgm.payload()) {
                    self.mangled_dns_ids
                        .lock()
                        .insert(message.header().id(), Instant::now());
                    packet.set_dst(srv.ip());
                    packet.update_checksum();
                }
            }
        }

        Some(packet)
    }
}

#[inline(always)]
fn make_packet<'a>(packet: &'a mut [u8], dst_addr: &IpAddr) -> device_channel::Packet<'a> {
    match dst_addr {
        IpAddr::V4(_) => device_channel::Packet::Ipv4(Cow::Borrowed(packet)),
        IpAddr::V6(_) => device_channel::Packet::Ipv6(Cow::Borrowed(packet)),
    }
}
