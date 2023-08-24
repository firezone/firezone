use std::{
    net::{IpAddr, ToSocketAddrs},
    sync::Arc,
};

use crate::{
    device_channel::DeviceChannel, ip_packet::MutableIpPacket, peer::Peer, ControlSignal, Tunnel,
};
use boringtun::noise::Tunn;
use libs_common::{messages::ResourceDescription, Callbacks, Error};

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    fn get_matching_version_ip(addr: IpAddr, ip: IpAddr) -> Option<IpAddr> {
        ((addr.is_ipv4() && ip.is_ipv4()) || (addr.is_ipv6() && ip.is_ipv6())).then_some(ip)
    }

    async fn update_and_send_packet(
        &self,
        device_channel: &DeviceChannel,
        packet: &mut [u8],
        dst_addr: IpAddr,
    ) {
        let Some(mut pkt) = MutableIpPacket::new(packet) else { return };
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

    pub(crate) async fn send_to_resource(
        &self,
        device_channel: &DeviceChannel,
        peer: &Arc<Peer>,
        addr: IpAddr,
        packet: &mut [u8],
    ) {
        if peer.is_allowed(addr) {
            let Some(resources) = &peer.resources else {
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

            let Some(dst) = Tunn::dst_address(packet) else {
                tracing::warn!("Detected packet without destination address");
                return;
            };

            let Some(resource) = resources.read().get_by_ip(dst).map(|r| r.0.clone()) else {
                tracing::warn!(
                    "client tried to hijack the tunnel for resource itsn't allowed."
                );
                return;
            };

            let (dst_addr, _dst_port) = match resource {
                // Note: for now no translation is needed for the ip since we do a peer/connection per resource
                ResourceDescription::Dns(r) => {
                    let mut address = r.address.split(':');
                    let Some(dst_addr) = address.next() else {
                            tracing::error!("invalid DNS name for resource: {}", r.address);
                            let _ = self.callbacks().on_error(&Error::InvalidResource(r.address.clone()));
                            return;
                        };
                    let Ok(mut dst_addr) = format!("{dst_addr}:0").to_socket_addrs() else {
                            tracing::warn!("Couldn't resolve name addr: {addr}");
                            return;
                        };
                    let Some(dst_addr) = dst_addr.find_map(|d| Self::get_matching_version_ip(addr, d.ip())) else {
                            tracing::warn!("Couldn't resolve name addr: {addr}");
                            return;
                        };
                    peer.update_translated_resource_address(r.id, dst_addr);
                    (
                        dst_addr,
                        address
                            .next()
                            .map(str::parse::<u16>)
                            .and_then(std::result::Result::ok),
                    )
                }
                ResourceDescription::Cidr(r) => {
                    if r.address.contains(dst) {
                        let Some(dst_addr) = Self::get_matching_version_ip(addr, dst) else { return };
                        (dst_addr, None)
                    } else {
                        tracing::warn!(
                            "client tried to hijack the tunnel for range outside what it's allowed."
                        );
                        return;
                    }
                }
            };

            self.update_and_send_packet(device_channel, packet, dst_addr)
                .await;
        } else {
            tracing::warn!("Received packet from peer with an unallowed ip: {addr}");
        }
    }
}
