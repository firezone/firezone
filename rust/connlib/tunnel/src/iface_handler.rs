use std::{net::IpAddr, sync::Arc};

use boringtun::noise::{errors::WireGuardError, TunnResult};
use bytes::Bytes;
use connlib_shared::{Callbacks, Result};
use futures_util::SinkExt;

use crate::{ip_packet::MutableIpPacket, peer::Peer, RoleState, Tunnel};

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    #[inline(always)]
    pub(crate) async fn encapsulate_and_send_to_peer<'a>(
        &self,
        mut packet: MutableIpPacket<'_>,
        peer: Arc<Peer<TRoleState::Id>>,
        dst_addr: &IpAddr,
        buf: &mut [u8],
    ) -> Result<()> {
        match peer.encapsulate(&mut packet, buf)? {
            TunnResult::Done => Ok(()),
            TunnResult::Err(
                WireGuardError::ConnectionExpired | WireGuardError::NoCurrentSession,
            ) => {
                let _ = self
                    .stop_peer_command_sender
                    .clone()
                    .send((peer.index, peer.conn_id))
                    .await;
                Ok(())
            }
            TunnResult::Err(e) => Err(e.into()),
            TunnResult::WriteToNetwork(packet) => {
                tracing::trace!(target: "wire", action = "writing", from = "iface", to = %dst_addr);
                if let Err(e) = peer.channel.write(&Bytes::copy_from_slice(packet)).await {
                    tracing::error!(?e, "webrtc_write");
                    if matches!(
                        e,
                        webrtc::data::Error::ErrStreamClosed
                            | webrtc::data::Error::Sctp(webrtc::sctp::Error::ErrStreamClosed)
                    ) {
                        let _ = self
                            .stop_peer_command_sender
                            .clone()
                            .send((peer.index, peer.conn_id))
                            .await;
                    }
                    return Err(e.into());
                }

                Ok(())
            }
            _ => panic!("Unexpected result from encapsulate"),
        }
    }
}
