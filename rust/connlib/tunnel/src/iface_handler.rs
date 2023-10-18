use std::{net::IpAddr, sync::Arc};

use boringtun::noise::{errors::WireGuardError, TunnResult};
use bytes::Bytes;
use connlib_shared::{Callbacks, Result};

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
        let encapsulated_packet = peer.encapsulate(&mut packet, buf)?;

        match encapsulated_packet.encapsulate_result {
            TunnResult::Done => Ok(()),
            TunnResult::Err(WireGuardError::ConnectionExpired)
            | TunnResult::Err(WireGuardError::NoCurrentSession) => {
                self.stop_peer(encapsulated_packet.index, encapsulated_packet.conn_id)
                    .await;
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
                if let Err(e) = encapsulated_packet
                    .channel
                    .write(&Bytes::copy_from_slice(packet))
                    .await
                {
                    tracing::error!(?e, "webrtc_write");
                    if matches!(
                        e,
                        webrtc::data::Error::ErrStreamClosed
                            | webrtc::data::Error::Sctp(webrtc::sctp::Error::ErrStreamClosed)
                    ) {
                        self.stop_peer(encapsulated_packet.index, encapsulated_packet.conn_id)
                            .await;
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
