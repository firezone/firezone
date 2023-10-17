use std::{net::IpAddr, sync::Arc};

use boringtun::noise::{errors::WireGuardError, TunnResult};
use bytes::Bytes;
use connlib_shared::{Callbacks, Result};

use crate::{ip_packet::MutableIpPacket, peer::Peer, stop_peer, RoleState, Tunnel};

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
            TunnResult::Err(WireGuardError::ConnectionExpired)
            | TunnResult::Err(WireGuardError::NoCurrentSession) => {
                stop_peer(
                    &mut self.peers_by_ip.write(),
                    &mut self.peer_connections.lock(),
                    &mut self.close_connection_tasks.lock(),
                    peer.index,
                    peer.conn_id,
                );
                Ok(())
            }

            TunnResult::Err(e) => {
                tracing::error!(resource_address = %dst_addr, error = ?e, "resource_connection");
                let err = e.into();
                let _ = self.callbacks.on_error(&err);
                Err(err)
            }
            TunnResult::WriteToNetwork(packet) => {
                tracing::trace!(target: "wire", action = "writing", from = "iface", to = %dst_addr);
                if let Err(e) = peer.channel.write(&Bytes::copy_from_slice(packet)).await {
                    tracing::error!(?e, "webrtc_write");
                    if matches!(
                        e,
                        webrtc::data::Error::ErrStreamClosed
                            | webrtc::data::Error::Sctp(webrtc::sctp::Error::ErrStreamClosed)
                    ) {
                        stop_peer(
                            &mut self.peers_by_ip.write(),
                            &mut self.peer_connections.lock(),
                            &mut self.close_connection_tasks.lock(),
                            peer.index,
                            peer.conn_id,
                        );
                    }
                    let err = e.into();
                    let _ = self.callbacks.on_error(&err);
                    Err(err)
                } else {
                    Ok(())
                }
            }
            _ => panic!("Unexpected result from encapsulate"),
        }
    }
}
