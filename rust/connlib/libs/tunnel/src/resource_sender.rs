use std::{
    net::{IpAddr, ToSocketAddrs},
    sync::Arc,
};

use crate::{
    device_channel::DeviceChannel, ip_packet::MutableIpPacket, peer::Peer, ControlSignal, Tunnel,
};

use libs_common::{messages::ResourceDescription, Callbacks, Error, Result};

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    #[tracing::instrument(level = "trace", skip(self, device_channel, packet))]
    async fn update_and_send_packet(
        &self,
        device_channel: &DeviceChannel,
        packet: &mut [u8],
        dst_addr: IpAddr,
    ) {
        let Some(mut pkt) = MutableIpPacket::new(packet) else {
            return;
        };
        pkt.set_dst(dst_addr);
        pkt.update_checksum();

        match dst_addr {
            IpAddr::V4(addr) => {
                tracing::trace!("Sending packet to {addr}");
                self.write4_device_infallible(device_channel, packet).await;
            }
            IpAddr::V6(addr) => {
                tracing::trace!("Sending packet to {addr}");
                self.write6_device_infallible(device_channel, packet).await;
            }
        }
    }

    #[tracing::instrument(level = "trace", skip(self, device_channel, peer, packet))]
    pub(crate) async fn send_to_resource(
        &self,
        device_channel: &DeviceChannel,
        peer: &Arc<Peer>,
        addr: IpAddr,
        packet: &mut [u8],
    ) {
        if peer.is_allowed(addr) {
            let Some((dst, resource)) = peer.get_packet_resource(packet) else {
                // If there's no associated resource it means that we are in a client, then the packet comes from a gateway
                // and we just trust gateways.
                // In gateways this should never happen.
                tracing::trace!("Writing to interface with addr: {addr}");
                match addr {
                    IpAddr::V4(_) => self.write4_device_infallible(device_channel, packet).await,
                    IpAddr::V6(_) => self.write6_device_infallible(device_channel, packet).await,
                }
                return;
            };

            match get_resource_addr_and_port(peer, &resource, &addr, &dst) {
                Ok((dst_addr, _dst_port)) => {
                    self.update_and_send_packet(device_channel, packet, dst_addr)
                        .await
                }
                Err(e) => {
                    tracing::error!(err = ?e, "Couldn't parse resource");
                    let _ = self.callbacks().on_error(&e.into());
                }
            }
        } else {
            tracing::warn!(%addr, "Received packet from peer with an unallowed ip");
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
        // Note: for now no translation is needed for the ip since we do a peer/connection per resource
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
