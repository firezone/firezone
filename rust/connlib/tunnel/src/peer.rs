use std::borrow::Cow;
use std::collections::VecDeque;
use std::net::IpAddr;
use std::sync::Arc;

use bimap::BiMap;
use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::StaticSecret;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use connlib_shared::{messages::ResourceDescription, Error, Result};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use parking_lot::{Mutex, RwLock};
use pnet_packet::Packet;
use secrecy::ExposeSecret;

use crate::client::IpProvider;
use crate::MAX_UDP_SIZE;
use crate::{device_channel, ip_packet::MutableIpPacket, PeerConfig};

type ExpiryingResource = (ResourceDescription, DateTime<Utc>);

pub(crate) struct Peer<TId, TTransform> {
    tunnel: Mutex<Tunn>,
    allowed_ips: RwLock<IpNetworkTable<()>>,
    pub conn_id: TId,
    pub transform: TTransform,
}

// TODO: For now we only use these fields with debug
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub(crate) struct PeerStats<TId> {
    pub allowed_ips: Vec<IpNetwork>,
    pub conn_id: TId,
    // pub resources: HashMap<IpNetwork, ExpiryingResource>,
}

impl<TId, TTransform> Peer<TId, TTransform>
where
    TId: Copy,
    TTransform: PacketTransform,
{
    pub(crate) fn stats(&self) -> PeerStats<TId> {
        // let resources = self.resources.read().as_ref().map_or_else(
        //     || HashMap::new(),
        //     |resources| {
        //         resources
        //             .iter()
        //             .map(|(i, r)| (i.clone(), r.clone()))
        //             .collect()
        //     },
        // );
        let allowed_ips = self.allowed_ips.read().iter().map(|(ip, _)| ip).collect();
        PeerStats {
            allowed_ips,
            conn_id: self.conn_id,
            // resources,
        }
    }

    pub(crate) fn new(
        private_key: StaticSecret,
        index: u32,
        peer_config: PeerConfig,
        conn_id: TId,
        rate_limiter: Arc<RateLimiter>,
        transform: TTransform,
    ) -> Peer<TId, TTransform> {
        let tunnel = Tunn::new(
            private_key.clone(),
            peer_config.public_key,
            Some(peer_config.preshared_key.expose_secret().0),
            peer_config.persistent_keepalive,
            index,
            Some(rate_limiter),
        );

        let mut allowed_ips = IpNetworkTable::new();
        for ip in peer_config.ips {
            allowed_ips.insert(ip, ());
        }
        let allowed_ips = RwLock::new(allowed_ips);

        Peer {
            tunnel: Mutex::new(tunnel),
            allowed_ips,
            conn_id,
            transform,
        }
    }

    pub(crate) fn add_allowed_ip(&self, ip: IpNetwork) {
        self.allowed_ips.write().insert(ip, ());
    }

    pub(crate) fn update_timers(&self) -> Result<Option<Bytes>> {
        /// [`boringtun`] requires us to pass buffers in where it can construct its packets.
        ///
        /// When updating the timers, the largest packet that we may have to send is `148` bytes as per `HANDSHAKE_INIT_SZ` constant in [`boringtun`].
        const MAX_SCRATCH_SPACE: usize = 148;

        let mut buf = [0u8; MAX_SCRATCH_SPACE];

        let packet = match self.tunnel.lock().update_timers(&mut buf) {
            TunnResult::Done => return Ok(None),
            TunnResult::Err(e) => return Err(e.into()),
            TunnResult::WriteToNetwork(b) => b,
            _ => panic!("Unexpected result from update_timers"),
        };

        Ok(Some(Bytes::copy_from_slice(packet)))
    }

    fn is_allowed(&self, addr: IpAddr) -> bool {
        self.allowed_ips.read().longest_match(addr).is_some()
    }

    /// Sends the given packet to this peer by encapsulating it in a wireguard packet.
    pub(crate) fn encapsulate(
        &self,
        packet: MutableIpPacket,
        buf: &mut [u8],
    ) -> Result<Option<Bytes>> {
        let Some(packet) = self.transform.packet_transform(packet) else {
            return Ok(None);
        };

        tracing::trace!(
            "packet src: {}, packet dst {}",
            packet.as_immutable().source(),
            packet.as_immutable().destination()
        );

        let packet = match self.tunnel.lock().encapsulate(packet.packet(), buf) {
            TunnResult::Done => return Ok(None),
            TunnResult::Err(e) => return Err(e.into()),
            TunnResult::WriteToNetwork(b) => b,
            _ => panic!("Unexpected result from `encapsulate`"),
        };

        Ok(Some(Bytes::copy_from_slice(packet)))
    }

    pub(crate) fn decapsulate<'b>(
        &self,
        src: &[u8],
        dst: &'b mut [u8],
    ) -> Result<Option<WriteTo<'b>>> {
        let mut tunnel = self.tunnel.lock();

        match tunnel.decapsulate(None, src, dst) {
            TunnResult::Done => Ok(None),
            TunnResult::Err(e) => Err(e.into()),
            TunnResult::WriteToNetwork(packet) => {
                let mut packets = VecDeque::from([Bytes::copy_from_slice(packet)]);

                let mut buf = [0u8; MAX_UDP_SIZE];

                while let TunnResult::WriteToNetwork(packet) =
                    tunnel.decapsulate(None, &[], &mut buf)
                {
                    packets.push_back(Bytes::copy_from_slice(packet));
                }

                Ok(Some(WriteTo::Network(packets)))
            }
            TunnResult::WriteToTunnelV4(packet, addr) => {
                self.make_packet_for_resource(addr.into(), packet)
            }
            TunnResult::WriteToTunnelV6(packet, addr) => {
                self.make_packet_for_resource(addr.into(), packet)
            }
        }
    }

    fn make_packet_for_resource<'a>(
        &self,
        addr: IpAddr,
        packet: &'a mut [u8],
    ) -> Result<Option<WriteTo<'a>>> {
        let (packet, addr) = self.transform.packet_untransform(&addr, packet)?;

        if !self.is_allowed(addr) {
            tracing::warn!("packet not allowed: {addr}");
            return Ok(None);
        }

        Ok(Some(WriteTo::Resource(packet)))
    }
}

pub enum WriteTo<'a> {
    Network(VecDeque<Bytes>),
    Resource(device_channel::Packet<'a>),
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
    // TODO: we need to refresh the translations ips periodically, just add a timer to resend allow access
    translations: RwLock<BiMap<IpAddr, IpAddr>>,
}

impl PacketTransformClient {
    pub fn get_or_assign_translation(
        &self,
        external_ip: &IpAddr,
        ip_provider: &mut IpProvider,
    ) -> Option<IpAddr> {
        let mut translations = self.translations.write();
        if let Some(internal_ip) = translations.get_by_right(external_ip) {
            return Some(*internal_ip);
        }
        let internal_ip = match external_ip {
            IpAddr::V4(_) => ip_provider.next_ipv4()?.into(),
            IpAddr::V6(_) => ip_provider.next_ipv6()?.into(),
        };
        translations.insert(internal_ip, *external_ip);
        Some(internal_ip)
    }
}

impl PacketTransformGateway {
    pub(crate) fn is_emptied(&self) -> bool {
        self.resources.read().is_empty()
    }

    pub(crate) fn expire_resources(&self) {
        self.resources.write().retain(|_, (_, e)| *e > Utc::now());
    }

    pub(crate) fn add_resource(
        &self,
        ip: IpNetwork,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
    ) {
        self.resources.write().insert(ip, (resource, expires_at));
    }
}

pub(crate) trait PacketTransform {
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
        let src = translations.get_by_right(addr).unwrap_or(addr);

        let Some(mut pkt) = MutableIpPacket::new(packet) else {
            return Err(Error::BadPacket);
        };

        tracing::trace!("setting packet source from: {addr} to {src}");
        pkt.set_src(*src);
        pkt.update_checksum();
        let packet = make_packet(packet, addr);
        Ok((packet, *src))
    }

    fn packet_transform<'a>(&self, mut packet: MutableIpPacket<'a>) -> Option<MutableIpPacket<'a>> {
        if let Some(translated_ip) = self.translations.read().get_by_left(&packet.destination()) {
            packet.set_dst(*translated_ip);
            packet.update_checksum();
            tracing::trace!("translating to ip: {translated_ip}");
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
