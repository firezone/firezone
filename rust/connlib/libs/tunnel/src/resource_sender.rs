use std::{
    net::{IpAddr, ToSocketAddrs},
    sync::Arc,
};

use boringtun::noise::Tunn;
use libs_common::{messages::ResourceDescription, Callbacks, Error};

use crate::{ip_packet::MutableIpPacket, peer::Peer, ControlSignal, Tunnel};

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    fn get_matching_version_ip(addr: IpAddr, ip: IpAddr) -> Option<IpAddr> {
        if (addr.is_ipv4() && ip.is_ipv4()) || (addr.is_ipv6() && ip.is_ipv6()) {
            Some(ip)
        } else {
            None
        }
    }

    async fn update_and_send_packet(&self, packet: &mut [u8], dst_addr: IpAddr) {
        let Some(mut pkt) = MutableIpPacket::new(packet) else {return};
        pkt.set_dst(dst_addr);
        pkt.set_checksum();

        match dst_addr {
            IpAddr::V4(_) => {
                self.write4_device_infallible(packet).await;
            }
            IpAddr::V6(_) => {
                self.write6_device_infallible(packet).await;
            }
        }
    }

    pub(crate) async fn send_to_resource(&self, peer: &Arc<Peer>, addr: IpAddr, packet: &mut [u8]) {
        if peer.is_allowed(addr) {
            let Some(resource) = &peer.resource else {
                // If there's no associated resource it means that we are in a client, then the packet comes from a gateway
                // and we just trust gateways.
                // In gateways this should never happen.
                tracing::trace!("Writing to interface");
                match addr {
                    IpAddr::V4(_) => self.write4_device_infallible(packet).await,
                    IpAddr::V6(_) => self.write6_device_infallible(packet).await,
                }
                return;
            };

            let Some(dst) = Tunn::dst_address(packet) else {
                tracing::warn!("Detected packet without destination address");
                return;
            };

            let (dst_addr, _dst_port) = match resource {
                // Note: for now no translation is needed for the ip since we do a peer/connection per resource
                ResourceDescription::Dns(r) => {
                    if r.ipv4 == dst || r.ipv6 == dst {
                        let mut address = r.address.split(':');
                        let Some(dst_addr) = address.next() else {
                            tracing::error!("invalid DNS name for resource: {}", r.address);
                            self.callbacks().on_error(&Error::InvalidResource(r.address.clone()));
                            return;
                        };
                        let Ok(mut dst_addr) =  format!("{dst_addr}:0").to_socket_addrs() else {
                            tracing::warn!("Couldn't resolve name addr: {addr}");
                            return;
                        };
                        let Some(dst_addr) = dst_addr.find_map(|d| Self::get_matching_version_ip(addr, d.ip())) else {
                            tracing::warn!("Couldn't resolve name addr: {addr}");
                            return;
                        };
                        peer.update_translated_resource_address(dst_addr);
                        (
                            dst_addr,
                            address
                                .next()
                                .map(str::parse::<u16>)
                                .and_then(std::result::Result::ok),
                        )
                    } else {
                        tracing::warn!(
                            "client tried to hijack the tunnel for resource itsn't allowed."
                        );
                        return;
                    }
                }
                ResourceDescription::Cidr(r) => {
                    if r.address.contains(dst) {
                        let Some(dst_addr) = Self::get_matching_version_ip(addr, dst) else {return};
                        (dst_addr, None)
                    } else {
                        tracing::warn!(
                        "client tried to hijack the tunnel for range outside what it's allowed."
                    );
                        return;
                    }
                }
            };

            self.update_and_send_packet(packet, dst_addr).await;
        } else {
            tracing::warn!("Recieved packet from peer with an unallowed ip: {addr}");
        }
    }
}
