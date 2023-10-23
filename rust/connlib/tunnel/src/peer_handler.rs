use std::borrow::Cow;
use std::net::{IpAddr, ToSocketAddrs};
use std::sync::Arc;

use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{handshake::parse_handshake_anon, Packet, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use bytes::{Bytes, BytesMut};
use connlib_shared::messages::ResourceDescription;
use connlib_shared::{Callbacks, Error, Result};
use futures_util::SinkExt;

use crate::ip_packet::MutableIpPacket;
use crate::peer::WriteTo;
use crate::{
    device_channel, device_channel::DeviceIo, index::check_packet_index, peer::Peer, RoleState,
    Tunnel, MAX_UDP_SIZE,
};

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub(crate) async fn start_peer_handler(self: Arc<Self>, peer: Arc<Peer<TRoleState::Id>>) {
        loop {
            let Some(device) = self.device.read().await.clone() else {
                let err = Error::NoIface;
                tracing::error!(?err);
                let _ = self.callbacks().on_disconnect(Some(&err));
                break;
            };
            let device_io = device.io;

            if let Err(err) = self.peer_handler(&peer, device_io).await {
                if err.raw_os_error() != Some(9) {
                    tracing::error!(?err);
                    let _ = self.callbacks().on_error(&err.into());
                    break;
                } else {
                    tracing::warn!("bad_file_descriptor");
                }
            }
        }
        tracing::debug!(peer = ?peer.stats(), "peer_stopped");
        let _ = self
            .stop_peer_command_sender
            .clone()
            .send((peer.index, peer.conn_id))
            .await;
    }

    async fn peer_handler(
        self: &Arc<Self>,
        peer: &Arc<Peer<TRoleState::Id>>,
        device_io: DeviceIo,
    ) -> std::io::Result<()> {
        let mut src_buf = [0u8; MAX_UDP_SIZE];
        let mut dst_buf = [0u8; MAX_UDP_SIZE];
        while let Ok(size) = peer.channel.read(&mut src_buf[..]).await {
            tracing::trace!(target: "wire", action = "read", bytes = size, from = "peer");

            // TODO: Double check that this can only happen on closed channel
            // I think it's possible to transmit a 0-byte message through the channel
            // but we would never use that.
            // We should keep track of an open/closed channel ourselves if we wanted to do it properly then.
            if size == 0 {
                break;
            }

            match self
                .handle_peer_packet(peer, &device_io, &src_buf[..size], &mut dst_buf)
                .await
            {
                Err(Error::Io(e)) => return Err(e),
                Err(other) => {
                    tracing::error!(error = ?other, "failed to handle peer packet");
                    let _ = self.callbacks.on_error(&other);
                }
                _ => {}
            }
        }

        Ok(())
    }

    #[inline(always)]
    pub(crate) async fn handle_peer_packet(
        self: &Arc<Self>,
        peer: &Arc<Peer<TRoleState::Id>>,
        device_writer: &DeviceIo,
        src: &[u8],
        dst: &mut [u8],
    ) -> Result<()> {
        if let Some(cookie) = verify_packet(
            &self.rate_limiter,
            &self.private_key,
            &self.public_key,
            peer.index,
            src,
        )? {
            peer.send_infallible(cookie, &self.callbacks).await;

            return Err(Error::UnderLoad);
        }

        let write_to = match peer.tunnel.lock().decapsulate(None, src, dst) {
            TunnResult::Done => return Ok(()),
            TunnResult::Err(e) => return Err(e.into()),
            TunnResult::WriteToNetwork(packet) => {
                let mut bytes = BytesMut::new();
                bytes.extend_from_slice(packet);

                // Flush pending queue
                while let TunnResult::WriteToNetwork(packet) =
                    peer.tunnel.lock().decapsulate(None, &[], dst)
                {
                    bytes.extend_from_slice(packet);
                }

                WriteTo::Network(bytes.freeze())
            }
            TunnResult::WriteToTunnelV4(packet, addr) => {
                let Some(packet) = make_packet_for_resource(peer, addr.into(), packet)? else {
                    return Ok(());
                };

                WriteTo::Resource(packet)
            }
            TunnResult::WriteToTunnelV6(packet, addr) => {
                let Some(packet) = make_packet_for_resource(peer, addr.into(), packet)? else {
                    return Ok(());
                };

                WriteTo::Resource(packet)
            }
        };

        match write_to {
            WriteTo::Network(packet) => peer.send_infallible(packet, &self.callbacks).await,
            WriteTo::Resource(packet) => {
                device_writer.write(packet)?;
            }
        }

        Ok(())
    }
}

/// Consults the rate limiter for the provided buffer and checks that it parses into a valid wireguard packet.
#[inline(always)]
fn verify_packet(
    rate_limiter: &RateLimiter,
    private_key: &StaticSecret,
    public_key: &PublicKey,
    peer_index: u32,
    src: &[u8],
) -> Result<Option<Bytes>> {
    /// The rate-limiter emits at most a cookie packet which is only 64 bytes.
    const COOKIE_REPLY_SIZE: usize = 64;

    let mut dst = [0u8; COOKIE_REPLY_SIZE];

    // The rate limiter initially checks mac1 and mac2, and optionally asks to send a cookie
    let packet = match rate_limiter.verify_packet(
        // TODO: Some(addr.ip()) webrtc doesn't expose easily the underlying data channel remote ip
        // so for now we don't use it. but we need it for rate limiter although we probably not need it since the data channel
        // will only be established to authenticated peers, so the portal could already prevent being ddos'd
        // but maybe in that cased we can drop this rate_limiter all together and just use decapsulate
        None, src, &mut dst,
    ) {
        Ok(packet) => packet,
        Err(TunnResult::WriteToNetwork(cookie)) => {
            return Ok(Some(Bytes::copy_from_slice(cookie)));
        }
        Err(TunnResult::Err(e)) => return Err(e.into()),
        Err(_) => {
            tracing::error!(error = "unexpected", "wireguard_error");

            return Err(Error::BadPacket);
        }
    };

    if !is_wireguard_packet_ok(private_key, public_key, &packet, peer_index) {
        tracing::error!("wireguard_verification");
        return Err(Error::BadPacket);
    }

    Ok(None)
}

#[inline(always)]
fn is_wireguard_packet_ok(
    private_key: &StaticSecret,
    public_key: &PublicKey,
    parsed_packet: &Packet,
    peer_index: u32,
) -> bool {
    match parsed_packet {
        Packet::HandshakeInit(p) => parse_handshake_anon(private_key, public_key, p).is_ok(),
        Packet::HandshakeResponse(p) => check_packet_index(p.receiver_idx, peer_index),
        Packet::PacketCookieReply(p) => check_packet_index(p.receiver_idx, peer_index),
        Packet::PacketData(p) => check_packet_index(p.receiver_idx, peer_index),
    }
}

#[inline(always)]
pub(crate) fn make_packet_for_resource<'a, TId>(
    peer: &Arc<Peer<TId>>,
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
    peer: &Arc<Peer<TId>>,
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
