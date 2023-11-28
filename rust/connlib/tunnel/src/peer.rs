use std::borrow::Cow;
use std::collections::VecDeque;
use std::net::ToSocketAddrs;
use std::sync::Arc;
use std::{collections::HashMap, net::IpAddr};

use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::StaticSecret;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{ResourceDescription, ResourceId},
    Error, Result,
};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use parking_lot::{Mutex, RwLock};
use pnet_packet::Packet;
use secrecy::ExposeSecret;

use crate::MAX_UDP_SIZE;
use crate::{device_channel, ip_packet::MutableIpPacket, PeerConfig};

type ExpiryingResource = (ResourceDescription, DateTime<Utc>);

pub(crate) struct Peer<TId> {
    tunnel: Mutex<Tunn>,
    allowed_ips: RwLock<IpNetworkTable<()>>,
    pub conn_id: TId,
    resources: RwLock<Option<IpNetworkTable<ExpiryingResource>>>,
    // Here we store the address that we obtained for the resource that the peer corresponds to.
    // This can have the following problem:
    // 1. Peer sends packet to address.com and it resolves to 1.1.1.1
    // 2. Now Peer sends another packet to address.com but it resolves to 2.2.2.2
    // 3. We receive an outstanding response(or push) from 1.1.1.1
    // This response(or push) is ignored, since we store only the last.
    // so, TODO: store multiple ips and expire them.
    // Note that this case is quite an unlikely edge case so I wouldn't prioritize this fix
    // TODO: Also check if there's any case where we want to talk to ipv4 and ipv6 from the same peer.
    translated_resource_addresses: RwLock<HashMap<IpAddr, ResourceId>>,
}

// TODO: For now we only use these fields with debug
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub(crate) struct PeerStats<TId> {
    pub allowed_ips: Vec<IpNetwork>,
    pub conn_id: TId,
    pub resources: HashMap<IpNetwork, ExpiryingResource>,
    pub translated_resource_addresses: HashMap<IpAddr, ResourceId>,
}

impl<TId> Peer<TId>
where
    TId: Copy,
{
    pub(crate) fn stats(&self) -> PeerStats<TId> {
        let resources = self.resources.read().as_ref().map_or_else(
            || HashMap::new(),
            |resources| {
                resources
                    .iter()
                    .map(|(i, r)| (i.clone(), r.clone()))
                    .collect()
            },
        );
        let allowed_ips = self.allowed_ips.read().iter().map(|(ip, _)| ip).collect();
        let translated_resource_addresses = self.translated_resource_addresses.read().clone();
        PeerStats {
            allowed_ips,
            conn_id: self.conn_id,
            resources,
            translated_resource_addresses,
        }
    }

    pub(crate) fn new(
        private_key: StaticSecret,
        index: u32,
        peer_config: PeerConfig,
        conn_id: TId,
        rate_limiter: Arc<RateLimiter>,
    ) -> Peer<TId> {
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
            resources: RwLock::new(None),
            translated_resource_addresses: Default::default(),
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

    pub(crate) fn is_emptied(&self) -> bool {
        self.resources.read().as_ref().is_some_and(|r| r.is_empty())
    }

    pub(crate) fn expire_resources(&self) {
        if let Some(ref mut resources) = *self.resources.write() {
            // TODO: We could move this to resource_table and make it way faster
            let expire_resources: Vec<_> = resources
                .iter()
                .filter(|(_, (_, e))| e <= &Utc::now())
                .map(|(i, r)| (i.clone(), r.clone()))
                .collect();
            {
                // Oh oh! 2 Mutexes
                let mut translated_resource_addresses = self.translated_resource_addresses.write();
                for (ip, (r, _)) in expire_resources {
                    resources.remove(ip);
                    translated_resource_addresses.retain(|_, &mut i| r.id() != i);
                }
            }
        }
    }

    pub(crate) fn add_resource(
        &self,
        ip: IpNetwork,
        resource: ResourceDescription,
        expires_at: DateTime<Utc>,
    ) {
        let mut resources = self.resources.write();
        if resources.is_none() {
            *resources = Some(IpNetworkTable::new());
        }
        // We just wrote it
        resources
            .as_mut()
            .unwrap()
            .insert(ip, (resource, expires_at));
    }

    pub(crate) fn is_allowed(&self, addr: IpAddr) -> bool {
        self.allowed_ips.read().longest_match(addr).is_some()
    }

    pub(crate) fn update_translated_resource_address(&self, id: ResourceId, addr: IpAddr) {
        self.translated_resource_addresses.write().insert(addr, id);
    }

    /// Sends the given packet to this peer by encapsulating it in a wireguard packet.
    pub(crate) fn encapsulate(
        &self,
        mut packet: MutableIpPacket,
        buf: &mut [u8],
    ) -> Result<Option<Bytes>> {
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
                let Some(packet) = make_packet_for_resource(self, addr.into(), packet)? else {
                    return Ok(None);
                };

                Ok(Some(WriteTo::Resource(packet)))
            }
            TunnResult::WriteToTunnelV6(packet, addr) => {
                let Some(packet) = make_packet_for_resource(self, addr.into(), packet)? else {
                    return Ok(None);
                };

                Ok(Some(WriteTo::Resource(packet)))
            }
        }
    }

    pub(crate) fn get_packet_resource(
        &self,
        packet: &mut [u8],
    ) -> Option<(IpAddr, ResourceDescription)> {
        let resources = self.resources.read();
        let resources = resources.as_ref()?;

        let dst = Tunn::dst_address(packet)?;

        let Some(resource) = resources.longest_match(dst).map(|(_, (r, _))| r.clone()) else {
            tracing::warn!("client tried to hijack the tunnel for resource itsn't allowed.");
            return None;
        };

        Some((dst, resource))
    }
}

pub enum WriteTo<'a> {
    Network(VecDeque<Bytes>),
    Resource(device_channel::Packet<'a>),
}

#[inline(always)]
pub(crate) fn make_packet_for_resource<'a, TId>(
    peer: &Peer<TId>,
    addr: IpAddr,
    packet: &'a mut [u8],
) -> Result<Option<device_channel::Packet<'a>>>
where
    TId: Copy,
{
    if !peer.is_allowed(addr) {
        tracing::warn!(%addr, "Received packet from peer with an unallowed ip");
        return Ok(None);
    }

    let Some((dst, resource)) = peer.get_packet_resource(packet) else {
        // If there's no associated resource it means that we are in a client, then the packet comes from a gateway
        // and we just trust gateways.
        // In gateways this should never happen.
        tracing::trace!(target: "wire", action = "writing", to = "iface", %addr, bytes = %packet.len());
        let packet = make_packet(packet, addr);
        return Ok(Some(packet));
    };

    let (dst_addr, _dst_port) = get_resource_addr_and_port(peer, &resource, &addr, &dst)?;
    update_packet(packet, dst_addr);
    let packet = make_packet(packet, addr);

    Ok(Some(packet))
}

#[inline(always)]
fn make_packet(packet: &mut [u8], dst_addr: IpAddr) -> device_channel::Packet<'_> {
    match dst_addr {
        IpAddr::V4(_) => device_channel::Packet::Ipv4(Cow::Borrowed(packet)),
        IpAddr::V6(_) => device_channel::Packet::Ipv6(Cow::Borrowed(packet)),
    }
}

#[inline(always)]
fn update_packet(packet: &mut [u8], dst_addr: IpAddr) {
    let Some(mut pkt) = MutableIpPacket::new(packet) else {
        return;
    };
    pkt.set_dst(dst_addr);
    pkt.update_checksum();
}

fn get_matching_version_ip(addr: &IpAddr, ip: &IpAddr) -> Option<IpAddr> {
    ((addr.is_ipv4() && ip.is_ipv4()) || (addr.is_ipv6() && ip.is_ipv6())).then_some(*ip)
}

fn get_resource_addr_and_port<TId>(
    peer: &Peer<TId>,
    resource: &ResourceDescription,
    addr: &IpAddr,
    dst: &IpAddr,
) -> Result<(IpAddr, Option<u16>)>
where
    TId: Copy,
{
    match resource {
        ResourceDescription::Dns(r) => {
            let mut address = r.address.split(':');
            let Some(dst_addr) = address.next() else {
                tracing::error!("invalid DNS name for resource: {}", r.address);
                return Err(Error::InvalidResource);
            };
            let Ok(mut dst_addr) = (dst_addr, 0).to_socket_addrs() else {
                tracing::warn!(%addr, "Couldn't resolve name");
                return Err(Error::InvalidResource);
            };
            let Some(dst_addr) = dst_addr.find_map(|d| get_matching_version_ip(addr, &d.ip()))
            else {
                tracing::warn!(%addr, "Couldn't resolve name addr");
                return Err(Error::InvalidResource);
            };
            peer.update_translated_resource_address(r.id, dst_addr);
            Ok((
                dst_addr,
                address
                    .next()
                    .map(str::parse::<u16>)
                    .and_then(std::result::Result::ok),
            ))
        }
        ResourceDescription::Cidr(r) => {
            if r.address.contains(*dst) {
                Ok((
                    get_matching_version_ip(addr, dst).ok_or(Error::InvalidResource)?,
                    None,
                ))
            } else {
                tracing::warn!(
                    "client tried to hijack the tunnel for range outside what it's allowed."
                );
                Err(Error::InvalidSource)
            }
        }
    }
}
