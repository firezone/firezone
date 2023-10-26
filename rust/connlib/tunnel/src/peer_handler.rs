use std::sync::Arc;

use connlib_shared::{Callbacks, Error, Result};
use futures_util::SinkExt;
use webrtc::data::data_channel::DataChannel;

use crate::peer::WriteTo;
use crate::{device_channel::DeviceIo, peer::Peer, RoleState, Tunnel, MAX_UDP_SIZE};

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub(crate) async fn start_peer_handler(
        self: Arc<Self>,
        id: TRoleState::Id,
        mut peer: Peer,
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
        let _ = self.stop_peer_command_sender.clone().send(id).await;
    }

    async fn peer_handler(
        self: &Arc<Self>,
        peer: &mut Peer,
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
        peer: &mut Peer,
        channel: &DataChannel,
        device_writer: &DeviceIo,
        mut src: &[u8],
        dst: &mut [u8],
    ) -> Result<()> {
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
