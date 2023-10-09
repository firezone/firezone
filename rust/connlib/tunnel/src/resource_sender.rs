use std::{
    net::{IpAddr, ToSocketAddrs},
    sync::Arc,
};

use crate::{
    device_channel::DeviceIo, ip_packet::MutableIpPacket, peer::Peer, ControlSignal, Tunnel,
};

use connlib_shared::{messages::ResourceDescription, Callbacks, Error, Result};

impl<C, CB, TIceState> Tunnel<C, CB, TIceState>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    #[inline(always)]
    fn update_packet(&self, packet: &mut [u8], dst_addr: IpAddr) {
        let Some(mut pkt) = MutableIpPacket::new(packet) else {
            return;
        };
        pkt.set_dst(dst_addr);
        pkt.update_checksum();
    }

    #[inline(always)]
    fn send_packet(
        &self,
        device_io: &DeviceIo,
        packet: &mut [u8],
        dst_addr: IpAddr,
    ) -> std::io::Result<()> {
        match dst_addr {
            IpAddr::V4(_) => device_io.write4(packet)?,
            IpAddr::V6(_) => device_io.write6(packet)?,
        };
        Ok(())
    }

    #[inline(always)]
    pub(crate) fn packet_allowed(
        &self,
        device_io: &DeviceIo,
        peer: &Arc<Peer>,
        addr: IpAddr,
        packet: &mut [u8],
    ) -> Result<()> {
        let Some((dst, resource)) = peer.get_packet_resource(packet) else {
            // If there's no associated resource it means that we are in a client, then the packet comes from a gateway
            // and we just trust gateways.
            // In gateways this should never happen.
            tracing::trace!(target: "wire", action = "writing", to = "iface", %addr, bytes = %packet.len());
            self.send_packet(device_io, packet, addr)?;
            return Ok(());
        };

        let (dst_addr, _dst_port) = get_resource_addr_and_port(peer, &resource, &addr, &dst)?;
        self.update_packet(packet, dst_addr);
        self.send_packet(device_io, packet, addr)?;
        Ok(())
    }

    pub(crate) fn send_to_resource(
        &self,
        device_io: &DeviceIo,
        peer: &Arc<Peer>,
        addr: IpAddr,
        packet: &mut [u8],
    ) -> Result<()> {
        if peer.is_allowed(addr) {
            self.packet_allowed(device_io, peer, addr, packet)?;
            Ok(())
        } else {
            tracing::warn!(%addr, "Received packet from peer with an unallowed ip");
            Ok(())
        }
    }
}

fn get_matching_version_ip(addr: &IpAddr, ip: &IpAddr) -> Option<IpAddr> {
    ((addr.is_ipv4() && ip.is_ipv4()) || (addr.is_ipv6() && ip.is_ipv6())).then_some(*ip)
}

fn get_resource_addr_and_port(
    peer: &Arc<Peer>,
    resource: &ResourceDescription,
    addr: &IpAddr,
    dst: &IpAddr,
) -> Result<(IpAddr, Option<u16>)> {
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
