use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use connlib_shared::Callbacks;
use futures_util::SinkExt;
use webrtc::mux::endpoint::Endpoint;
use webrtc::util::Conn;

use crate::device_channel::Device;
use crate::peer::WriteTo;
use crate::{peer::Peer, RoleState, Tunnel, MAX_UDP_SIZE};

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub(crate) fn start_peer_handler(
        &self,
        peer: Arc<Peer<TRoleState::Id>>,
        channel: Arc<Endpoint>,
    ) -> impl Future<Output = ()> + Send + 'static {
        let device = Arc::clone(&self.device);
        let callbacks = self.callbacks.clone();
        let mut sender = self.stop_peer_command_sender.clone();

        async move {
            loop {
                let Some(device) = device.load().clone() else {
                    tracing::debug!("Device temporarily not available");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                let result = peer_handler(&callbacks, &peer, channel.clone(), &device).await;

                if matches!(result, Err(ref err) if err.raw_os_error() == Some(9)) {
                    tracing::warn!("bad_file_descriptor");
                    continue;
                }

                if let Err(e) = result {
                    tracing::error!(err = ?e, "peer_handle_error");
                }

                break;
            }

            tracing::debug!(peer = ?peer.stats(), "peer_stopped");
            let _ = sender.send(peer.conn_id).await;
        }
    }
}

async fn peer_handler<TId>(
    callbacks: &impl Callbacks,
    peer: &Arc<Peer<TId>>,
    channel: Arc<Endpoint>,
    device: &Device,
) -> std::io::Result<()>
where
    TId: Copy,
{
    let mut src_buf = [0u8; MAX_UDP_SIZE];
    let mut dst_buf = [0u8; MAX_UDP_SIZE];
    while let Ok(size) = channel.recv(&mut src_buf[..]).await {
        tracing::trace!(target: "wire", action = "read", bytes = size, from = "peer");

        // TODO: Double check that this can only happen on closed channel
        // I think it's possible to transmit a 0-byte message through the channel
        // but we would never use that.
        // We should keep track of an open/closed channel ourselves if we wanted to do it properly then.
        if size == 0 {
            break;
        }

        let src = &src_buf[..size];

        match peer.decapsulate(src, &mut dst_buf) {
            Ok(Some(WriteTo::Network(bytes))) => {
                for packet in bytes {
                    if let Err(e) = channel.send(&packet).await {
                        tracing::error!("Couldn't send packet to connected peer: {e}");
                        // let _ = callbacks.on_error(&e.into());
                    }
                }
            }
            Ok(Some(WriteTo::Resource(packet))) => {
                device.write(packet)?;
            }
            Ok(None) => {}
            Err(other) => {
                tracing::error!(error = ?other, "failed to handle peer packet");
                let _ = callbacks.on_error(&other);
            }
        }
    }

    Ok(())
}
