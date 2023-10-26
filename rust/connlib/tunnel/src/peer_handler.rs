use std::sync::Arc;

use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{handshake::parse_handshake_anon, Packet, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use bytes::Bytes;
use connlib_shared::{Callbacks, Error, Result};
use futures_util::SinkExt;
use webrtc::data::data_channel::DataChannel;

use crate::peer::WriteTo;
use crate::{
    device_channel::DeviceIo, index::check_packet_index, peer::Peer, RoleState, Tunnel,
    MAX_UDP_SIZE,
};

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub(crate) async fn start_peer_handler(
        self: Arc<Self>,
        mut peer: Peer<TRoleState::Id>,
        channel: Arc<DataChannel>,
    ) {
        loop {
            let Some(device) = self.device.read().await.clone() else {
                let err = Error::NoIface;
                tracing::error!(?err);
                let _ = self.callbacks().on_disconnect(Some(&err));
                break;
            };
            let device_io = device.io;

            if let Err(err) = self
                .peer_handler(&mut peer, channel.clone(), device_io)
                .await
            {
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
        let _ = self.stop_peer_command_sender.clone().send(peer.index).await;
    }

    async fn peer_handler(
        self: &Arc<Self>,
        peer: &mut Peer<TRoleState::Id>,
        channel: Arc<DataChannel>,
        device_io: DeviceIo,
    ) -> std::io::Result<()> {
        let mut src_buf = [0u8; MAX_UDP_SIZE];
        let mut dst_buf = [0u8; MAX_UDP_SIZE];
        while let Ok(size) = channel.read(&mut src_buf[..]).await {
            tracing::trace!(target: "wire", action = "read", bytes = size, from = "peer");

            // TODO: Double check that this can only happen on closed channel
            // I think it's possible to transmit a 0-byte message through the channel
            // but we would never use that.
            // We should keep track of an open/closed channel ourselves if we wanted to do it properly then.
            if size == 0 {
                break;
            }

            match self
                .handle_peer_packet(peer, &channel, &device_io, &src_buf[..size], &mut dst_buf)
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
        peer: &mut Peer<TRoleState::Id>,
        channel: &DataChannel,
        device_writer: &DeviceIo,
        mut src: &[u8],
        dst: &mut [u8],
    ) -> Result<()> {
        if let Some(cookie) = verify_packet(
            &self.rate_limiter,
            &self.private_key,
            &self.public_key,
            peer.index,
            src,
        )? {
            if let Err(e) = channel.write(&cookie).await {
                tracing::error!("Couldn't send cookie to connected peer: {e}");
                let _ = self.callbacks.on_error(&e.into());
            }

            return Err(Error::UnderLoad);
        }

        loop {
            match peer.decapsulate(src, dst)? {
                Some(WriteTo::Network(bytes)) => {
                    if let Err(e) = channel.write(&bytes).await {
                        tracing::error!("Couldn't send packet to connected peer: {e}");
                        let _ = self.callbacks.on_error(&e.into());
                    }
                }
                Some(WriteTo::Resource(packet)) => {
                    device_writer.write(packet)?;
                }
                None => break,
            }

            // Boringtun requires us to call `decapsulate` again with an empty `src` array to ensure we full process all queued messages.
            // It would be nice to do this within `decapsulate` but the borrow-checker doesn't allow us to re-borrow `dst`.
            src = &[];
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
