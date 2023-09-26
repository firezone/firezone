use std::sync::Arc;

use boringtun::noise::{handshake::parse_handshake_anon, Packet, TunnResult};
use bytes::Bytes;
use libs_common::{Callbacks, Error, Result};

use crate::{
    device_channel::DeviceIo, index::check_packet_index, peer::Peer, ControlSignal, Tunnel,
    MAX_UDP_SIZE,
};

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    #[inline(always)]
    fn is_wireguard_packet_ok(&self, parsed_packet: &Packet, peer: &Peer) -> bool {
        match &parsed_packet {
            Packet::HandshakeInit(p) => {
                parse_handshake_anon(&self.private_key, &self.public_key, p).is_ok()
            }
            Packet::HandshakeResponse(p) => check_packet_index(p.receiver_idx, peer.index),
            Packet::PacketCookieReply(p) => check_packet_index(p.receiver_idx, peer.index),
            Packet::PacketData(p) => check_packet_index(p.receiver_idx, peer.index),
        }
    }

    #[inline(always)]
    async fn verify_packet<'a>(
        self: &Arc<Self>,
        peer: &Arc<Peer>,
        src: &'a [u8],
        dst: &'a mut [u8],
    ) -> Result<Packet<'a>> {
        // The rate limiter initially checks mac1 and mac2, and optionally asks to send a cookie
        match self.rate_limiter.verify_packet(
            // TODO: Some(addr.ip()) webrtc doesn't expose easily the underlying data channel remote ip
            // so for now we don't use it. but we need it for rate limiter although we probably not need it since the data channel
            // will only be established to authenticated peers, so the portal could already prevent being ddos'd
            // but maybe in that cased we can drop this rate_limiter all together and just use decapsulate
            None, src, dst,
        ) {
            Ok(packet) => Ok(packet),
            Err(TunnResult::WriteToNetwork(cookie)) => {
                let bytes = Bytes::copy_from_slice(cookie);
                peer.send_infallible(bytes, &self.callbacks).await;
                Err(Error::UnderLoad)
            }
            Err(TunnResult::Err(e)) => {
                tracing::error!(error = ?e, "wireguard_error");
                let err = e.into();
                let _ = self.callbacks().on_error(&err);
                Err(err)
            }
            Err(_) => {
                tracing::error!(error = "unexpected", "wireguard_error");
                Err(Error::BadPacket)
            }
        }
    }

    #[inline(always)]
    async fn handle_decapsulated_packet<'a>(
        self: &Arc<Self>,
        peer: &Arc<Peer>,
        device_io: &DeviceIo,
        decapsulate_result: TunnResult<'a>,
    ) -> bool {
        match decapsulate_result {
            TunnResult::Done => false,
            TunnResult::Err(e) => {
                tracing::error!(error = ?e, "decapsulate_packet");
                let _ = self.callbacks().on_error(&e.into());
                false
            }
            TunnResult::WriteToNetwork(packet) => {
                let bytes = Bytes::copy_from_slice(packet);
                peer.send_infallible(bytes, &self.callbacks).await;
                true
            }
            TunnResult::WriteToTunnelV4(packet, addr) => {
                self.send_to_resource(device_io, peer, addr.into(), packet);
                false
            }
            TunnResult::WriteToTunnelV6(packet, addr) => {
                self.send_to_resource(device_io, peer, addr.into(), packet);
                false
            }
        }
    }

    #[inline(always)]
    pub(crate) async fn handle_peer_packet(
        self: &Arc<Self>,
        peer: &Arc<Peer>,
        device_writer: &DeviceIo,
        src: &[u8],
        dst: &mut [u8],
    ) -> Result<()> {
        let parsed_packet = self.verify_packet(peer, src, dst).await?;
        if !self.is_wireguard_packet_ok(&parsed_packet, peer) {
            tracing::error!("wireguard_verification");
            return Err(Error::BadPacket);
        }

        let decapsulate_result = peer.tunnel.lock().decapsulate(None, src, dst);

        if self
            .handle_decapsulated_packet(peer, device_writer, decapsulate_result)
            .await
        {
            // Flush pending queue
            while let TunnResult::WriteToNetwork(packet) = {
                let res = peer.tunnel.lock().decapsulate(None, &[], dst);
                res
            } {
                let bytes = Bytes::copy_from_slice(packet);
                let callbacks = self.callbacks.clone();
                let peer = peer.clone();
                tokio::spawn(async move { peer.send_infallible(bytes, &callbacks).await });
            }
        }

        Ok(())
    }

    pub(crate) async fn peer_handler(self: &Arc<Self>, peer: Arc<Peer>, device_io: DeviceIo) {
        let mut src_buf = [0u8; MAX_UDP_SIZE];
        let mut dst_buf = [0u8; MAX_UDP_SIZE];
        while let Ok(size) = peer.channel.read(&mut src_buf[..]).await {
            // TODO: Double check that this can only happen on closed channel
            // I think it's possible to transmit a 0-byte message through the channel
            // but we would never use that.
            // We should keep track of an open/closed channel ourselves if we wanted to do it properly then.
            if size == 0 {
                break;
            }

            tracing::trace!(target: "wire", action = "read", bytes = size, from = "peer");
            let _ = self
                .handle_peer_packet(&peer, &device_io, &src_buf[..size], &mut dst_buf)
                .await;
        }

        let peer_stats = peer.stats();
        tracing::debug!(peer = ?peer_stats, "peer_stopped");
        self.stop_peer(peer.index, peer.conn_id).await;
    }
}
