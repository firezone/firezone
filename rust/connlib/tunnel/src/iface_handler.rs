use std::net::IpAddr;

use boringtun::noise::TunnResult;
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
        peer: &Peer<TRoleState::Id>,
        dst_addr: &IpAddr,
        buf: &mut [u8],
    ) -> Result<()> {
        match peer.encapsulate(&mut packet, buf)? {
            TunnResult::Done => Ok(()),
            TunnResult::Err(e) => Err(e.into()),
            TunnResult::WriteToNetwork(packet) => {
                tracing::trace!(target: "wire", action = "writing", from = "iface", to = %dst_addr);
                peer.channel.write(&Bytes::copy_from_slice(packet)).await?;

                Ok(())
            }
            _ => panic!("Unexpected result from encapsulate"),
        }
    }
}
